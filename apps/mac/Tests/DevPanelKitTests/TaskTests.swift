import Foundation
import Testing
@testable import DevPanelKit

@Suite("Quick actions and project inspector") struct TaskTests {
    @Test @MainActor func projectDetailsAvoidEmptyActionsAndRespectExplicitEntries() {
        let model = AppModel(environment: .init(discover: { nil }, makeClient: { DaemonClient(discovery: $0) }))
        var p = project(task())
        p.actions = []
        model.apply(.projectUpsert(p))
        model.selectProject(p.id)
        #expect(model.projectInspector.tabs[p.id] == .activity)
        model.projectInspector.tabs[p.id] = .actions // Old saved preference.
        model.selectProject(p.id)
        #expect(model.projectInspector.tabs[p.id] == .activity)
        p.maven = MavenView(currentRun: nil, lastRun: nil)
        model.apply(.projectUpsert(p))
        model.projectInspector.tabs[p.id] = .actions
        model.selectProject(p.id)
        #expect(model.projectInspector.tabs[p.id] == .activity)
        model.selectProject(p.id, tab: .git)
        #expect(model.projectInspector.tabs[p.id] == .git)
        model.selectProject(p.id, tab: .options)
        model.selectProject(p.id)
        #expect(model.projectInspector.tabs[p.id] == .options)
        p.maven = nil
        model.apply(.projectUpsert(p))
        model.projectInspector.tabs[p.id] = .maven
        model.selectProject(p.id)
        #expect(model.projectInspector.tabs[p.id] == .activity)
        p.actions = project(task()).actions
        model.apply(.projectUpsert(p))
        model.selectProject(p.id, tab: .actions)
        #expect(model.selectedTaskRef == TaskRef(p.id, .action("build")))
    }

    func task(_ state: TaskRunState = .succeeded, id: String = "r_task") -> TaskRunSummary {
        TaskRunSummary(id: id, projectId: "p_tasks", kind: .action, actionId: "build", maven: nil, label: "Build", configRevision: 1, source: .ui, startedAt: "2026-10-21T00:00:00Z", endedAt: state.isActive ? nil : "2026-10-21T00:01:12Z", pid: nil, state: state, exit: nil, cancelTimedOut: false)
    }
    func project(_ run: TaskRunSummary) -> ProjectView {
        ProjectView(id: "p_tasks", name: "Tasks", root: "/tmp/tasks", revision: 1, aggregate: .idle, runningCount: 0, serviceCount: 1, services: [ServiceView(id: "web", name: "Web", state: .idle)], actions: [ActionView(id: "build", name: "Build", description: nil, confirmWhenServicesRunning: false, currentRun: run.state.isActive ? run : nil, lastRun: run)])
    }
    @Test func actionEditorRoundtripAndSecretRetention() {
        let action = ActionConfig(id: "build", name: "Build", description: "Produce files", cwd: "backend", command: ["pnpm", "build", "${mode}"], env: ["TOKEN": .secret(value: nil)], stopTimeoutSec: 30, timeoutSec: 120, confirmWhenServicesRunning: true)
        let config = ProjectConfig(name: "Tasks", root: "/tmp/tasks", services: [ServiceConfig(id: "web", name: "Web", cwd: ".", command: ["node", "app.js"])], actions: [action], maven: MavenConfig(executable: "wrapper"))
        var draft = ProjectDraft(config: config)
        #expect(draft.build().errors.isEmpty)
        #expect(draft.build().config == config)
        draft.actions[0].service.serviceId = "renamed"
        #expect(draft.build().errors["actions[0].env.TOKEN"] != nil)
    }
    @Test func actionValidationCoversTimeoutAndDuplicateNamespace() {
        var draft = ProjectDraft(name: "Tasks", root: "/tmp/tasks", services: [ServiceDraft(serviceId: "build", idAuto: false, name: "Build", commandText: "echo hi")])
        draft.actions = [ActionDraft(service: draft.services[0], timeoutText: "86401")]
        #expect(draft.build().errors["actions[0].id"] == nil)
        #expect(draft.build().errors["actions[0].timeoutSec"] != nil)
        draft.actions.append(draft.actions[0])
        #expect(draft.build().errors["actions[1].id"] != nil)
    }
    @Test @MainActor func selectionAndHistoryAreIndependentOfService() {
        let model = AppModel(environment: .init(discover: { nil }, makeClient: { DaemonClient(discovery: $0) }))
        var p = project(task(.running))
        model.apply(.projectUpsert(p)); model.select(ServiceRef(p.id, "web"))
        #expect(model.selection?.serviceId == "web")
        model.selectProject(p.id)
        #expect(model.selection == nil)
        #expect(model.inspectorSelection == .project(p.id))
        let ref = TaskRef(p.id, .action("build"))
        #expect(model.selectedTaskRef == ref)
        #expect(model.viewedRunId(for: ref) == "r_task")
        model.projectInspector.runs[ref] = (0..<8).map { i in var r = task(id: "r_old\(i)"); r.startedAt = "2026-10-20T00:00:0\(i)Z"; return r }
        #expect(model.runs(for: ref).count == 5)
        model.chooseRun("r_old7", for: ref)
        #expect(model.isViewingHistory(ref))
        p.actions[0].currentRun = nil; p.actions[0].lastRun = task()
        model.apply(.projectUpsert(p))
        #expect(model.taskRuns(ref).first?.state == .succeeded)
        model.selectProject(p.id, tab: .options)
        #expect(model.selectedTaskRef == nil)
        #expect(model.inspector.logs.target == nil)
        model.apply(.projectRemove(projectId: p.id))
        #expect(!model.hasInspectorSelection)
    }
    @Test func completionNotificationsRespectBaselineForegroundAndCancellation() throws {
        var tracker = TaskNotificationTracker()
        guard case .snapshot(var snapshot) = try Fixture.decode(DaemonEvent.self, "recorded/event-snapshot.json") else { return }
        snapshot.projects = [project(task())]
        #expect(tracker.consume(.snapshot(snapshot), foreground: false).isEmpty)
        #expect(tracker.consume(.projectUpsert(project(task(id: "r_2"))), foreground: true).isEmpty)
        #expect(tracker.consume(.projectUpsert(project(task(id: "r_2"))), foreground: false).isEmpty)
        #expect(tracker.consume(.projectUpsert(project(task(.cancelled, id: "r_3"))), foreground: false).isEmpty)
        #expect(tracker.consume(.projectUpsert(project(task(.failed, id: "r_4"))), foreground: false).count == 1)
        #expect(tracker.consume(.projectUpsert(project(task(.timedOut, id: "r_5"))), foreground: false).count == 1)
    }
    @Test func taskClientRoutesAndUICancellation() async throws {
        let run = task(.running)
        let transport = FakeTransport { request in
            if request.httpMethod == "GET" { return (200, try ContractCoding.encoder().encode([run])) }
            if request.url?.path.hasSuffix("/cancel") == true { return (202, try ContractCoding.encoder().encode(run)) }
            return (202, try ContractCoding.encoder().encode(StartTaskRunResponse(created: true, run: run)))
        }
        let client = testClient(transport)
        #expect(try await client.actionRuns("p_tasks", actionId: "build").first?.id == run.id)
        #expect(try await client.startAction("p_tasks", actionId: "build").created)
        _ = try await client.cancelTask(run.id, force: true)
        let requests = transport.requests.current
        #expect(requests.map { $0.url!.path } == ["/api/v1/projects/p_tasks/actions/build/runs", "/api/v1/projects/p_tasks/actions/build/runs", "/api/v1/task-runs/r_task/cancel"])
        #expect(requests[1].value(forHTTPHeaderField: "X-DevPanel-Client") == "ui")
        #expect(requests[2].value(forHTTPHeaderField: "X-DevPanel-Client") == "ui")
        #expect(String(decoding: requests[2].httpBody!, as: UTF8.self) == #"{"force":true}"#)
    }
    @Test func actionOptionReferencesRemainVisibleAndMasked() {
        let p = ParamConfig(key: "mode", label: "Mode", type: .string, value: .string("release"), usedBy: [ParamReference(serviceId: "action:build", where: .command, index: 1)])
        let config = ProjectConfig(name: "Tasks", root: "/tmp/tasks", services: [], params: [p], actions: [ActionConfig(id: "build", name: "Build", command: ["echo", "${mode}"])])
        let references = OptionRules.references(p, config: config, inline: false)
        #expect(references.first?.location == "Build 命令")
        #expect(references.first?.text == "release")
    }
    @Test func unknownOwnedTaskStillBlocksRemoval() {
        var p = project(task(.running))
        p.actions[0].currentRun?.state = .unknown
        #expect(!RemovalCheck(p).allowed)
        #expect(RemovalCheck(p).blockedReason?.contains("任务") == true)
    }
    @Test func taskStatesRemainIntactForSharedLogProtocol() throws {
        #expect(task().state == .succeeded)
        #expect(task(.cancelled).state == .cancelled)
        #expect(task(.timedOut).state == .timedOut)
        #expect(task().statusText(now: Date()).contains("1m12s"))
        let encoded = try ContractCoding.encoder().encode(project(task()))
        #expect(try ContractCoding.decoder().decode(ProjectView.self, from: encoded).actions.count == 1)
    }
    @Test func logEndRetainsTaskKindAndState() throws {
        let event = LogStreamEvent.end(runId: "r_task", run: .task(task(.timedOut)))
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(LogStreamEvent.self, from: data)
        guard case .end(_, .task(let run)) = decoded else { Issue.record("Expected task end payload"); return }
        #expect(run.kind == .action && run.state == .timedOut)
        #expect(!String(decoding: data, as: UTF8.self).contains("serviceId"))
    }

    @Test func newWireEnumsPreserveUnknownValues() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(TaskRunKind.self, from: Data(#""future-task""#.utf8)) == .other("future-task"))
        #expect(try decoder.decode(MavenExecutable.self, from: Data(#""future-mvn""#.utf8)) == .other("future-mvn"))
        #expect(try decoder.decode(GitDiffLineKind.self, from: Data(#""future-line""#.utf8)) == .other("future-line"))
    }

}
