import Foundation
import Observation

public struct MavenOptions: Codable, Hashable, Sendable {
    public var skipTests = false
    public var offline = false
    public var alsoMake = false
    public init() {}
}
public enum MavenProfileState: Int, Codable, Sendable {
    case `default`, enabled, disabled
    public var next: Self { Self(rawValue: (rawValue + 1) % 3)! }
    public var symbol: String { switch self { case .default: "square"; case .enabled: "checkmark.square.fill"; case .disabled: "minus.square.fill" } }
    public var title: String { switch self { case .default: "默认"; case .enabled: "启用"; case .disabled: "禁用" } }
}
public struct MavenSelection: Hashable, Sendable {
    public static let phases = ["clean", "validate", "compile", "test", "package", "verify", "install", "site", "deploy"]
    public var moduleId = "."
    public var phases: Set<String> = []
    public init() {}
    public mutating func select(module: String, phase: String, additive: Bool) {
        guard Self.phases.contains(phase) else { return }
        if module != moduleId || !additive { phases = [] }
        moduleId = module
        if additive && phases.contains(phase) { phases.remove(phase) } else { phases.insert(phase) }
    }
    public var goals: [String] { Self.phases.filter { phases.contains($0) } }
}
public struct MavenConfirmation: Identifiable, Sendable {
    public var projectId: ProjectID
    public var request: MavenRunRequest
    public var message: String
    public var id: String { projectId }
}
@Observable @MainActor public final class MavenState {
    public var targetSelections: [ProjectID: String] = [:]
    public func key(_ id: ProjectID) -> String { targetSelections[id].map { id + "#" + $0 } ?? id }
    public var models: [ProjectID: MavenModel] = [:]
    public var selections: [ProjectID: MavenSelection] = [:]
    public var profileStates: [ProjectID: [String: MavenProfileState]] = [:]
    public var options: [ProjectID: MavenOptions] = [:]
    public var loading: Set<ProjectID> = []
    public var errors: [ProjectID: String] = [:]
    public var confirmation: MavenConfirmation?
    @ObservationIgnored private let defaults: UserDefaults?
    public init(defaults: UserDefaults? = nil) { self.defaults = defaults }
    public func loadOptions(_ projectId: ProjectID) {
        let id = key(projectId)
        guard options[id] == nil else { return }
        options[id] = defaults?.data(forKey: "maven.options.\(id)").flatMap { try? JSONDecoder().decode(MavenOptions.self, from: $0) } ?? MavenOptions()
    }
    public func setOptions(_ value: MavenOptions, for projectId: ProjectID) {
        let id = key(projectId)
        options[id] = value
        defaults?.set(try? JSONEncoder().encode(value), forKey: "maven.options.\(id)")
    }
    public func cycleProfile(_ profile: String, projectId: ProjectID) {
        profileStates[key(projectId), default: [:]][profile] = profileStates[key(projectId)]?[profile, default: .default].next ?? .enabled
    }
    public func request(_ projectId: ProjectID, goals: [String]? = nil, skipTests: Bool? = nil) -> MavenRunRequest {
        let id = key(projectId)
        let selection = selections[id, default: MavenSelection()]
        let options = options[id, default: MavenOptions()]
        let profiles = (models[id]?.profiles ?? []).compactMap { profile -> String? in
            switch profileStates[id]?[profile] ?? .default { case .default: nil; case .enabled: profile; case .disabled: "!" + profile }
        }
        return MavenRunRequest(moduleId: selection.moduleId, goals: goals ?? selection.goals, profiles: profiles, skipTests: skipTests ?? options.skipTests, offline: options.offline, alsoMake: options.alsoMake, mavenProjectId: targetSelections[projectId])
    }
}

extension AppModel {
    public func loadMaven(_ id: ProjectID, reload: Bool = false) async {
        if maven.targetSelections[id] == nil, let first = project(id)?.mavenProjects?.first { maven.targetSelections[id] = first.id }
        let targetId = maven.targetSelections[id], key = maven.key(id)
        guard isConnected, let client, !maven.loading.contains(key) else { return }
        maven.loadOptions(id)
        maven.loading.insert(key)
        defer { maven.loading.remove(key) }
        do {
            let result = try await client.maven(id, reload: reload, mavenProjectId: targetId)
            maven.models[key] = result
            if !result.modules.contains(where: { $0.id == maven.selections[key, default: MavenSelection()].moduleId }) { maven.selections[key] = MavenSelection() }
            maven.errors[key] = nil
        } catch { maven.errors[key] = error.localizedDescription }
    }
    public func requestMaven(_ id: ProjectID, request: MavenRunRequest) {
        let key = maven.key(id)
        guard isConnected, let project = project(id) else { return }
        if let error = request.localError { maven.errors[key] = error; return }
        if let current = project.maven?.currentRun {
            maven.errors[key] = "\(project.name) 已有 Maven 运行（\(current.label) · \(Format.duration(current.duration(now: Date()) ?? 0))），先等待或取消。"
            return
        }
        if request.goals.contains("clean") && project.runningCount > 0 {
            let command = CommandText.join(request.previewCommand(executable: maven.models[key]?.executable ?? .mvn))
            maven.confirmation = MavenConfirmation(projectId: id, request: request, message: "\(project.name) 有 \(project.runningCount) 个服务正在运行，clean 会删除 target/，正在运行的服务可能出错。\n\n\(command)")
        } else { Task { await startMaven(id, request: request) } }
    }
    public func startMaven(_ id: ProjectID, request: MavenRunRequest) async {
        let key = request.mavenProjectId.map { id + "#" + $0 } ?? id
        let ref = TaskRef(id, .maven)
        guard isConnected, let client, !projectInspector.pending.contains(ref) else { return }
        projectInspector.pending.insert(ref)
        defer { projectInspector.pending.remove(ref) }
        do {
            let result = try await client.startMaven(id, request: request)
            projectInspector.runs[ref, default: []].insert(result.run, at: 0)
            chooseRun(nil, for: ref)
            apply(.projectUpsert(try await client.projectView(id)))
            maven.errors[key] = nil
        } catch { maven.errors[key] = error.localizedDescription }
    }
    public func saveMavenAction(_ id: ProjectID, request: MavenRunRequest, name: String, actionId: String, description: String) async throws {
        let key = request.mavenProjectId.map { id + "#" + $0 } ?? id
        guard let executable = maven.models[key]?.executable else { throw ApiError.unreachable("请先加载 Maven 模型") }
        if let error = request.localError { throw ApiError(code: .badRequest, message: error) }
        let project = try await fetchProject(id)
        var config = project.config
        guard !(config.actions ?? []).contains(where: { $0.id == actionId }) else { throw ApiError(code: .badRequest, message: "快捷操作 ID 已存在") }
        let cwd: String
        if let targetId = request.mavenProjectId {
            guard let target = config.mavenProjects?.first(where: { $0.id == targetId }) else { throw ApiError(code: .badRequest, message: "Maven 工程已移除，请重新选择") }
            cwd = target.path
        } else { cwd = "." }
        let action = ActionConfig(id: actionId, name: name, description: description.isEmpty ? nil : description, cwd: cwd, command: request.previewCommand(executable: executable), confirmWhenServicesRunning: request.goals.contains("clean"))
        config.actions = (config.actions ?? []) + [action]
        _ = try await updateProject(id, ifRevision: project.revision, config: config)
    }
}
