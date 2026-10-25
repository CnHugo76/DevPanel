import Foundation
import Observation

/// An edit owns the revision it was based on. Conflicts never silently retry or discard input.
@Observable @MainActor
public final class OptionEditor {
    public let model: AppModel
    public let projectId: ProjectID
    public private(set) var param: ParamConfig
    public private(set) var revision: Int
    public var text: String
    public var label: String
    public var explanation: String
    public private(set) var error: String?
    public private(set) var conflict = false
    public private(set) var deleted = false
    public private(set) var busy = false
    @ObservationIgnored private var debounce: Task<Void, Never>?

    public init(model: AppModel, project: Project, param: ParamConfig) {
        self.model = model; projectId = project.id; revision = project.revision; self.param = param
        text = param.isSecret ? "" : param.value?.description ?? ""
        label = param.label; explanation = param.description ?? ""
    }

    public var isDirty: Bool {
        text != (param.isSecret ? "" : param.value?.description ?? "") || label != param.label || explanation != (param.description ?? "")
    }

    public func synchronize(_ project: Project) {
        guard !busy, !conflict, !isDirty else { return }
        guard let p = project.config.params?.first(where: { $0.key == param.key }) else { deleted = true; return }
        param = p; revision = project.revision
        text = p.isSecret ? "" : p.value?.description ?? ""
        label = p.label; explanation = p.description ?? ""
    }

    public func changed() {
        debounce?.cancel()
        guard !conflict, !deleted else { return }
        debounce = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            await self?.save()
        }
    }

    @discardableResult public func save() async -> Bool {
        guard !busy, !deleted else { return false }
        let value: ParamValue?
        do { value = try OptionRules.value(text, for: param) }
        catch { self.error = error.localizedDescription; return false }
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = "请输入选项名称"; return false
        }
        let v = value == param.value ? nil : value
        let l = label == param.label ? nil : label
        let d = explanation == (param.description ?? "") ? nil : explanation
        guard v != nil || l != nil || d != nil else { error = nil; conflict = false; return true }
        let sentText = text
        busy = true
        defer { busy = false }
        do {
            let p = try await model.patchOption(projectId, key: param.key, request: PatchParamRequest(ifRevision: revision, value: v, label: l, description: d))
            revision = p.revision
            if let updated = p.config.params?.first(where: { $0.key == param.key }) { param = updated }
            if param.isSecret && text == sentText { text = "" }
            error = nil; conflict = false
            return true
        } catch {
            await handle(error)
            return false
        }
    }

    public func handle(_ error: any Error) async {
        let e = error as? ApiError ?? .unreachable(error.localizedDescription)
        self.error = OptionRules.errorText(e)
        if e.code == .revisionMismatch || e.code == .paramUnknown {
            conflict = e.code == .revisionMismatch
            deleted = e.code == .paramUnknown
            if let p = try? await model.fetchProject(projectId) {
                revision = p.revision
                if let latest = p.config.params?.first(where: { $0.key == param.key }) {
                    if label == param.label { label = latest.label }
                    if explanation == (param.description ?? "") { explanation = latest.description ?? "" }
                    if !param.isSecret && text == (param.value?.description ?? "") { text = latest.value?.description ?? "" }
                    param = latest
                }
                else { deleted = true }
            }
        }
    }
}
