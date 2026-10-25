import Foundation
import Observation

/// State of one add / edit project sheet (ui-design §6, v2 §6). The view binds to `draft` and
/// calls the methods; all requests go through `AppModel`.
@Observable
@MainActor
public final class ProjectEditor {
    public enum Mode: Equatable, Sendable {
        case create
        case edit(ProjectID)

        public var projectId: ProjectID? {
            if case .edit(let id) = self { return id }
            return nil
        }
    }

    public enum LoadState: Equatable, Sendable {
        case loading
        case loaded
        case failed(String)
    }

    public nonisolated let mode: Mode
    public var draft: ProjectDraft
    /// The saved project being edited (nil when creating).
    public private(set) var original: Project?
    public private(set) var loadState: LoadState
    public private(set) var validation: EditorValidation?
    public var notice: EditorNotice?
    /// Local problems found on the last save attempt (see `ProjectDraft.BuildResult.errors`).
    public private(set) var localErrors: [String: String] = [:]
    public private(set) var isSaving = false

    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private var baseline: ProjectConfig
    @ObservationIgnored private var validateSeq = 0
    @ObservationIgnored private var lastValidated: ProjectConfig?

    public init(model: AppModel, mode: Mode) {
        self.model = model
        self.mode = mode
        let empty = ProjectDraft.empty()
        draft = empty
        baseline = empty.build(.validate).config
        loadState = mode == .create ? .loaded : .loading
    }

    // MARK: Loading

    /// Edit mode: uses the cached config when it is at the project's current revision, else
    /// fetches it. No-op when creating.
    public func load() async {
        guard let id = mode.projectId else { return }
        if let cached = model.configs[id], let view = model.project(id), cached.revision >= view.revision {
            apply(cached)
            return
        }
        await fetchLatest(id)
    }

    /// "载入最新配置": discards local changes (the view confirms first).
    public func reloadLatest() async {
        guard let id = mode.projectId else { return }
        await fetchLatest(id)
    }

    private func fetchLatest(_ id: ProjectID) async {
        do {
            apply(try await model.fetchProject(id))
        } catch {
            let message = (error as? ApiError)?.message ?? error.localizedDescription
            if original == nil {
                loadState = .failed(message)
            } else {
                notice = .loadFailed(message: message)
            }
        }
    }

    private func apply(_ project: Project) {
        original = project
        draft = ProjectDraft(config: project.config)
        baseline = draft.build(.validate).config
        validation = nil
        lastValidated = nil
        localErrors = [:]
        notice = nil
        loadState = .loaded
    }

    // MARK: Derived

    public var title: String {
        switch mode {
        case .create: "添加项目"
        case .edit(let id): "编辑项目 · \(model.project(id)?.name ?? original?.config.name ?? id)"
        }
    }

    /// Unsaved changes (closing asks first).
    public var isDirty: Bool {
        loadState == .loaded && (draft.build(.validate).config != baseline || draft.hasTypedSecrets)
    }

    /// Some service is starting / running / stopping / unknown: saving only affects the next start.
    public var isRunning: Bool {
        guard let id = mode.projectId, let p = model.project(id) else { return false }
        return p.services.contains { $0.state.blocksRemoval }
    }

    /// Current option values (read-only here; edited in the options panel). The cache follows
    /// the daemon, so a value changed meanwhile shows up in the preview.
    public var params: [ParamConfig] {
        if let id = mode.projectId, let cached = model.configs[id] { return cached.config.params ?? [] }
        return draft.params ?? []
    }

    /// Runtime state of the saved service a card edits.
    public func serviceView(_ row: ServiceDraft) -> ServiceView? {
        guard let id = mode.projectId, let orig = row.origId else { return nil }
        return model.project(id)?.service(orig)
    }

    /// Why a card cannot be deleted, nil if it can.
    public func deleteBlockedReason(_ row: ServiceDraft) -> String? {
        if draft.services.count <= 1 { return "至少需要一个服务" }
        if let v = serviceView(row), v.state.blocksRemoval {
            return v.state == .unknown ? "该服务状态未知，不能删除" : "运行中的服务不能删除，请先停止"
        }
        return nil
    }

    /// Renaming the ID of a saved service with run records needs a confirmation: the runs and
    /// logs stay with the old ID.
    public func idChangeNeedsConfirm(_ row: ServiceDraft) -> Bool {
        guard let orig = row.origId, row.serviceId != orig, let v = serviceView(row) else { return false }
        return v.lastRun != nil || v.currentRun != nil
    }

    /// A stored secret value is kept when the row's value is left empty.
    public func keepsStoredSecret(_ row: EnvRow, in service: ServiceDraft?) -> Bool {
        guard row.secret, row.value.isEmpty, let stored = row.storedName else { return false }
        if let service, let orig = service.origId, orig != service.serviceId { return false }
        return stored == row.name.trimmingCharacters(in: .whitespaces)
    }

    public func actionIsRunning(_ id: String) -> Bool {
        guard let projectId = mode.projectId else { return false }
        return model.project(projectId)?.actions.first { $0.id == id }?.currentRun != nil
    }

    public func localError(_ path: String) -> String? { localErrors[path] }

    // MARK: Editing helpers

    public func index(of row: UUID) -> Int? { draft.services.firstIndex { $0.id == row } }

    public func addService() {
        draft.services.append(.empty(taken: draft.serviceIds))
    }

    public func moveService(_ row: UUID, by delta: Int) {
        guard let i = index(of: row) else { return }
        let j = i + delta
        guard draft.services.indices.contains(j) else { return }
        draft.services.swapAt(i, j)
    }

    public func removeService(_ row: UUID) {
        guard let i = index(of: row), deleteBlockedReason(draft.services[i]) == nil else { return }
        draft.services.remove(at: i)
    }

    public func revertServiceId(_ row: UUID) {
        guard let i = index(of: row), let orig = draft.services[i].origId else { return }
        draft.services[i].serviceId = orig
    }

    // MARK: Validation

    /// Called when a field loses focus (and after toggles): validates in the background.
    public func fieldDidBlur() {
        Task { await validate() }
    }

    /// `POST /config/validate` with the current form. Skipped while the root is empty or when
    /// nothing changed since the last validation; out-of-order responses are dropped.
    public func validate() async {
        guard loadState == .loaded, !draft.root.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let built = draft.build(.validate).config
        guard built != lastValidated else { return }
        lastValidated = built
        validateSeq += 1
        let seq = validateSeq
        let rows = draft.services.map(\.id)
        do {
            let result = try await model.validateConfig(built)
            guard seq == validateSeq else { return }
            validation = EditorValidation(result: result, sentRows: rows, sentServiceIds: built.services.map(\.id))
        } catch {
            if seq == validateSeq { lastValidated = nil }
        }
    }

    // MARK: Save

    /// Saves (never starts anything). Returns the outcome on success; on failure sets `notice`
    /// (and field issues for CONFIG_INVALID) and returns nil.
    public func save() async -> EditorSaveOutcome? {
        guard !isSaving, loadState == .loaded else { return nil }
        let built = draft.build(.save)
        localErrors = built.errors
        guard built.errors.isEmpty else {
            notice = .fixFields
            return nil
        }
        isSaving = true
        defer { isSaving = false }
        notice = nil
        let rows = draft.services.map(\.id)
        do {
            switch mode {
            case .create:
                let r = try await model.registerProject(built.config)
                return r.created ? .created(r.project) : .alreadyRegistered(r.project)
            case .edit(let id):
                let r = try await model.updateProject(id, ifRevision: original?.revision ?? 0, config: built.config)
                original = r.project
                baseline = draft.build(.validate).config
                return .updated(r.project, keptUserValues: r.keptUserValues ?? [])
            }
        } catch let error as ApiError {
            notice = .from(error)
            if error.code == .configInvalid, let issues = error.issues {
                let result = ValidateResult(ok: false, issues: issues, services: validation?.result.services ?? [])
                validation = EditorValidation(
                    result: result, sentRows: rows, sentServiceIds: built.config.services.map(\.id))
                lastValidated = nil
            }
            return nil
        } catch {
            notice = .failed(code: ErrorCode.internal.rawValue, message: error.localizedDescription)
            return nil
        }
    }

    /// Labels of the kept option keys, for "以下选项保留了你之前设置的值：…".
    public func keptValuesText(_ keys: [String], project: Project) -> String {
        let params = project.config.params ?? []
        return keys.map { key in
            if let p = params.first(where: { $0.key == key }), !p.label.isEmpty { return "\(p.label)（\(key)）" }
            return key
        }.joined(separator: "、")
    }
}
