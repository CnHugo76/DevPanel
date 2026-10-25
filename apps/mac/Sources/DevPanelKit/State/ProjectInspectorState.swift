import Foundation
import Observation

public enum InspectorSelection: Hashable, Sendable {
    case service(ServiceRef)
    case project(ProjectID)
    public var projectId: ProjectID {
        switch self { case .service(let ref): ref.projectId; case .project(let id): id }
    }
}
public enum ProjectInspectorTab: String, CaseIterable, Sendable, Identifiable {
    case maven, actions, git, options, activity
    public var id: String { rawValue }
    public var title: String { switch self { case .maven: "Maven"; case .actions: "快捷操作"; case .git: "Git"; case .options: "选项"; case .activity: "动态" } }
}
@Observable @MainActor public final class ProjectInspectorState {
    public var tabs: [ProjectID: ProjectInspectorTab] = [:] {
        didSet { defaults?.set(tabs.mapValues(\.rawValue), forKey: "inspector.projectTabs") }
    }
    public var actionChoice: [ProjectID: String] = [:]
    public var runs: [TaskRef: [TaskRunSummary]] = [:]
    public var runChoice: [TaskRef: RunID] = [:]
    @ObservationIgnored var runLoads: Set<TaskRef> = []
    public var error: String?
    public var confirmation: QuickActionConfirmation?
    public var pending: Set<TaskRef> = []
    @ObservationIgnored private let defaults: UserDefaults?
    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        tabs = (defaults?.dictionary(forKey: "inspector.projectTabs") as? [String: String] ?? [:]).compactMapValues(ProjectInspectorTab.init(rawValue:))
    }
}
public struct QuickActionConfirmation: Identifiable, Sendable {
    public var projectId: ProjectID
    public var actionId: String
    public var title: String
    public var message: String
    public var id: String { projectId + "/" + actionId }
}
extension AppModel {
    public var selectedProjectId: ProjectID? { inspectorSelection?.projectId }
    public var hasInspectorSelection: Bool { inspectorSelection != nil }
    public var selectedTaskRef: TaskRef? {
        if let ref = selection, inspector.tab == .maven, serviceTabs(ref).contains(.maven) { return TaskRef(ref.projectId, .maven) }
        guard case .project(let id) = inspectorSelection else { return nil }
        if projectInspector.tabs[id] == .maven { return project(id)?.maven == nil ? nil : TaskRef(id, .maven) }
        guard projectInspector.tabs[id, default: .actions] == .actions,
              let p = project(id), let action = p.actions.first(where: { $0.id == projectInspector.actionChoice[id] }) ?? p.actions.first else { return nil }
        return TaskRef(id, .action(action.id))
    }
    public func taskRuns(_ ref: TaskRef) -> [TaskRunSummary] {
        guard let project = project(ref.projectId) else { return [] }
        let latest: [TaskRunSummary?]
        switch ref.target {
        case .maven:
            if let targetId = maven.targetSelections[ref.projectId] ?? project.mavenProjects?.first?.id {
                let target = project.mavenProjects?.first { $0.id == targetId }
                latest = [target?.lastRun, target?.currentRun]
            } else { latest = [project.maven?.lastRun, project.maven?.currentRun] }
        case .action(let id):
            let action = project.actions.first { $0.id == id }
            latest = [action?.lastRun, action?.currentRun]
        }
        var byID = Dictionary((projectInspector.runs[ref] ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        for run in latest.compactMap({ $0 }) { byID[run.id] = run }
        let values = byID.values.filter { run in
            guard case .maven = ref.target else { return true }
            return run.maven?.mavenProjectId == (maven.targetSelections[ref.projectId] ?? project.mavenProjects?.first?.id)
        }
        return Array(values.sorted { $0.startedAt > $1.startedAt }.prefix(daemon?.limits.taskRunsKept ?? 5))
    }
    public func requestQuickAction(_ projectId: ProjectID, actionId: String) {
        guard isConnected, let project = project(projectId), let action = project.actions.first(where: { $0.id == actionId }) else { return }
        selectProject(projectId, tab: .actions)
        projectInspector.actionChoice[projectId] = actionId
        if action.currentRun != nil { return }
        if action.confirmWhenServicesRunning && project.runningCount > 0 {
            let command = configs[projectId]?.config.actions?.first { $0.id == actionId }.map { CommandText.join($0.command) } ?? ""
            projectInspector.confirmation = QuickActionConfirmation(projectId: projectId, actionId: actionId, title: "运行 \(action.name)？", message: "\(project.name) 有 \(project.runningCount) 个服务正在运行。\n\(action.description ?? "此操作可能影响正在运行的服务。")\n\n\(command)")
        } else { Task { await startQuickAction(projectId, actionId: actionId) } }
    }
    public func startQuickAction(_ projectId: ProjectID, actionId: String) async {
        let ref = TaskRef(projectId, .action(actionId))
        guard isConnected, let client, !projectInspector.pending.contains(ref) else { return }
        projectInspector.pending.insert(ref)
        defer { projectInspector.pending.remove(ref) }
        do {
            let response = try await client.startAction(projectId, actionId: actionId)
            projectInspector.runs[ref, default: []].insert(response.run, at: 0)
            chooseRun(nil, for: ref)
            apply(.projectUpsert(try await client.projectView(projectId)))
        } catch { projectInspector.error = error.localizedDescription }
    }
    public func cancelTask(_ run: TaskRunSummary, force: Bool = false) async {
        guard isConnected, let client else { return }
        do {
            _ = try await client.cancelTask(run.id, force: force)
            apply(.projectUpsert(try await client.projectView(run.projectId)))
        } catch { projectInspector.error = error.localizedDescription }
    }
    public func deleteQuickAction(_ projectId: ProjectID, actionId: String) async {
        guard let project = configs[projectId], self.project(projectId)?.actions.first(where: { $0.id == actionId })?.currentRun == nil else { return }
        var config = project.config
        config.actions?.removeAll { $0.id == actionId }
        do { _ = try await updateProject(projectId, ifRevision: project.revision, config: config) }
        catch { projectInspector.error = error.localizedDescription }
    }
}
