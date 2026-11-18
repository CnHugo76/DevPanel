import Foundation
import Observation

public struct ActionRunField: Identifiable, Sendable {
    public var definition: ActionParamConfig
    public var input: ActionParameterInput
    public var id: String { definition.key }
}
@Observable @MainActor public final class ActionRunSession: Identifiable {
    public let id = UUID()
    public let projectId: ProjectID
    public let actionId: String
    public var revision: Int
    public var actionName: String
    public var runLabel: String
    public var description: String?
    public var fields: [ActionRunField]
    public var runningCount: Int
    public var needsServiceWarning: Bool
    public var errors: [String: String] = [:]
    public var message: String?
    public var isSubmitting = false
    public var stale = false
    public var uncertain = false
    public init(project: ProjectView, action: ActionView) {
        projectId = project.id; actionId = action.id; revision = project.revision; actionName = action.name
        runLabel = action.runLabel ?? "开始运行"; description = action.description
        fields = (action.params ?? []).map { ActionRunField(definition: $0, input: ActionParameterInput($0)) }
        runningCount = project.runningCount; needsServiceWarning = action.confirmWhenServicesRunning
    }
    public func request() -> ActionRunRequest? {
        errors = [:]
        var params: [String: ActionParamValue] = [:]
        for field in fields {
            do {
                if let value = try field.input.value(for: field.definition) { params[field.id] = value }
                else if !field.input.useStoredDefault, let error = ActionParameterRules.issue(nil, definition: field.definition) { errors[field.id] = error }
            } catch { errors[field.id] = error.localizedDescription }
        }
        return errors.isEmpty ? ActionRunRequest(params: params, ifRevision: revision) : nil
    }
    public func rebase(project: Project, action: ActionConfig) {
        let previous = Dictionary(fields.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        revision = project.revision; actionName = action.name; description = action.description; runLabel = action.runLabel ?? "开始运行"
        fields = (action.params ?? []).map { p in
            var input = previous[p.key]?.definition.type == p.type ? previous[p.key]!.input : ActionParameterInput(p)
            if input.useStoredDefault && p.defaultValue != .secret { input = ActionParameterInput(p) }
            return ActionRunField(definition: p, input: input)
        }
        needsServiceWarning = action.confirmWhenServicesRunning == true
        errors = [:]; stale = false; message = "已载入最新定义，请复核后再运行。"
    }
}

extension AppModel {
    public func submitActionParameters(_ form: ActionRunSession) async {
        guard isConnected, let client, !form.isSubmitting, !form.stale, !form.uncertain, let request = form.request() else { return }
        guard let project = project(form.projectId), let action = project.actions.first(where: { $0.id == form.actionId }) else { form.message = "操作已删除，请关闭表单。"; form.stale = true; return }
        if form.needsServiceWarning && project.runningCount != form.runningCount {
            form.runningCount = project.runningCount; form.message = "服务运行状态已变化，请复核后再次提交。"; return
        }
        if action.currentRun != nil { form.message = "此操作已在运行，请返回查看运行记录。"; form.uncertain = true; return }
        form.isSubmitting = true; form.message = nil
        defer { form.isSubmitting = false }
        let ref = TaskRef(form.projectId, .action(form.actionId))
        projectInspector.pending.insert(ref); defer { projectInspector.pending.remove(ref) }
        do {
            let response = try await client.startAction(form.projectId, actionId: form.actionId, request: request)
            projectInspector.runs[ref, default: []].insert(response.run, at: 0)
            chooseRun(response.run.id, for: ref)
            projectInspector.parameterForm = nil
            if let view = try? await client.projectView(form.projectId) { apply(.projectUpsert(view)) }
        } catch {
            let api = error as? ApiError
            form.message = error.localizedDescription
            for issue in api?.issues ?? [] where issue.path.hasPrefix("params.") { form.errors[String(issue.path.dropFirst(7))] = issue.message }
            if api?.code == .revisionMismatch { form.stale = true }
            if api?.code == .daemonUnreachable || api?.code == .internal || api?.code.rawValue == "TASK_RUNNING" {
                form.uncertain = true; form.message = "执行结果需核对，请先查看运行记录；不会自动重新提交。"
                await refreshRuns(ref)
            }
        }
    }
    public func reloadActionParameters(_ form: ActionRunSession) async {
        guard !form.isSubmitting, !form.uncertain else { return }
        do {
            let p = try await fetchProject(form.projectId)
            guard let a = p.config.actions?.first(where: { $0.id == form.actionId }) else { form.message = "操作已删除，请关闭表单。"; return }
            form.rebase(project: p, action: a)
        } catch { form.message = error.localizedDescription }
    }
}
