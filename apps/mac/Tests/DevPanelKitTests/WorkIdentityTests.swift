import Foundation
import Testing
@testable import DevPanelKit

@Suite("工作来源与实例")
struct WorkIdentityTests {
    @Test func labelsAndOldActorsRemainCompatible() throws {
        let old = try ContractCoding.decoder().decode(Actor.self, from: Data(#"{"client":"cli","agent":"codex"}"#.utf8))
        #expect(old.sourceLabel == "Codex")
        #expect(old.taskId == nil && old.workSummary == nil)
        let actor = Actor(client: .cli, agent: "codex", taskId: "checkout-42", taskLabel: "修复结账")
        #expect(actor.sourceLabel == "Codex · 工作 修复结账（checkout-42）")
        #expect(actor.filterableTaskId == "checkout-42")
        #expect(Actor(client: .cli, taskId: "[REDACTED]", taskLabel: "[REDACTED]").filterableTaskId == nil)
        #expect(Actor(client: .cli, taskId: "[REDACTED]").workSummary?.contains("已隐藏") == true)
        for invalid in ["", "a\n", "-a", "a/b", "工作", String(repeating: "a", count: 65)] {
            #expect(!Actor.isValidTaskId(invalid), "\(invalid.debugDescription)")
        }
        #expect(Actor.isValidTaskId("Task_42.v2-beta"))
        var operation = try Fixture.decode(Operation.self, "recorded/operation-finished.json")
        operation.actor = actor
        #expect(operation.summary(nameOf: { $0 }).sourceNote?.contains("checkout-42") == true)
    }

    @Test func taskQueryRetainsCursorWithoutAttributionHeaders() async throws {
        let transport = FakeTransport { request in
            if request.url?.path.hasSuffix("/activity") == true { return (200, Data(#"{"entries":[],"hasMore":false}"#.utf8)) }
            return (202, try Fixture.data("recorded/operation-created.json"))
        }
        let client = testClient(transport)
        _ = try await client.activity("p_one", before: "a_cursor", task: "work-42")
        _ = try await client.createOperation(ActionRequest(projectId: "p_one", action: .start))
        let request = try #require(transport.requests.current.first)
        let query = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.contains(URLQueryItem(name: "task", value: "work-42")))
        #expect(query.contains(URLQueryItem(name: "before", value: "a_cursor")))
        for request in transport.requests.current {
            #expect(request.value(forHTTPHeaderField: "X-DevPanel-Task") == nil)
            #expect(request.value(forHTTPHeaderField: "X-DevPanel-Task-Label") == nil)
        }
        #expect(transport.requests.current.last?.value(forHTTPHeaderField: "X-DevPanel-Client") == "ui")
    }

    @Test func editorPreservesAndClearsInstances() throws {
        var config = try Fixture.decode(Project.self, "recorded/project-order-service.json").config
        config.params = config.params?.map(\.forRequest)
        config.instance = ProjectInstance(group: "订单 服务", name: "修复结账 🚀")
        var draft = ProjectDraft(config: config)
        #expect(draft.build().errors.isEmpty)
        #expect(draft.build().config == config)
        #expect(draft.build(.validate).config == config)
        draft.name = "new project name"
        #expect(draft.build().config.instance == config.instance)
        draft.instanceGroup = ""
        #expect(draft.build().errors["instance.group"] != nil)
        draft.instanceName = ""
        #expect(draft.build().errors.isEmpty)
        #expect(draft.build().config.instance == nil)
    }

    @Test func instanceLimitsMatchUnicodeScalarContract() throws {
        #expect(ProjectInstance.isValidLabel(String(repeating: "🚀", count: 80)))
        #expect(!ProjectInstance.isValidLabel(String(repeating: "🚀", count: 81)))
        for invalid in ["", "   ", "a\n", "a\u{2028}b", "a\u{2029}b", "a\0b", "a\tb"] {
            #expect(!ProjectInstance.isValidLabel(invalid))
        }
        var draft = ProjectDraft(config: try Fixture.decode(Project.self, "recorded/project-order-service.json").config)
        draft.instanceGroup = "orders"
        draft.instanceName = "a\n"
        #expect(draft.build().errors["instance.name"] != nil)
    }

    @MainActor @Test func groupFilteringKeepsDistinctProjectsAndRuntime() throws {
        let snapshot = try AppModelTests.snapshot()
        var first = snapshot.projects[0]
        var second = snapshot.projects[1]
        first.instance = ProjectInstance(group: "订单 服务", name: "checkout")
        second.instance = ProjectInstance(group: "订单 服务", name: "payments")
        let projects = [first, second] + Array(snapshot.projects.dropFirst(2))
        let grouped = OverviewFilter.apply(projects, query: "group:订单 服务")
        #expect(grouped.map(\.id) == [first.id, second.id])
        #expect(grouped.map(\.project.root) == [first.root, second.root])
        #expect(grouped.map(\.services) == [first.services, second.services])
        #expect(OverviewFilter.apply(projects, query: "instance:CHECKOUT").map(\.id) == [first.id])
        #expect(OverviewFilter.apply(projects, query: first.id).map(\.id).contains(first.id))
        #expect(OverviewFilter.apply(projects, query: first.root).map(\.id).contains(first.id))
        #expect(OverviewFilter.apply(projects, query: "group:订单").isEmpty)
        first.instance = ProjectInstance(group: " orders ", name: " checkout ")
        #expect(OverviewFilter.apply([first], query: "group: orders ").map(\.id) == [first.id])
        #expect(ProjectDraft(config: ProjectConfig(name: "name", root: "/tmp", services: [], instance: first.instance)).build().config.instance == first.instance)
    }
}

/// Suspends activity requests until a test explicitly releases that exact request.
private final class DeferredActivityTransport: HTTPTransport, @unchecked Sendable {
    struct Pending {
        var request: URLRequest
        var continuation: CheckedContinuation<(Data, HTTPURLResponse), any Error>
    }
    let base: FakeTransport
    let requests = Locked<[URLRequest]>([])
    let pending = Locked<[Int: Pending]>([:])
    init(_ base: FakeTransport) { self.base = base }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard request.url?.path.hasSuffix("/activity") == true else { return try await base.send(request) }
        return try await withCheckedThrowingContinuation { continuation in
            let index = requests.withLock { requests in requests.append(request); return requests.count - 1 }
            pending.withLock { $0[index] = Pending(request: request, continuation: continuation) }
        }
    }
    func stream(_ request: URLRequest, receive: (StreamPart) async throws -> Void) async throws {
        try await base.stream(request, receive: receive)
    }
    func finish(_ index: Int, page: ActivityPage) throws {
        let response = try ContractCoding.encoder().encode(page)
        if let value = pending.withLock({ $0.removeValue(forKey: index) }) {
            value.continuation.resume(returning: (response, FakeTransport.response(value.request, 200)))
        } else { Issue.record("missing deferred request \(index)") }
    }
    func fail(_ index: Int) {
        pending.withLock { $0.removeValue(forKey: index) }?.continuation.resume(throwing: URLError(.timedOut))
    }
}

@MainActor @Suite("工作动态筛选与迟到请求")
struct WorkActivityTests {
    private func setup() async throws -> (AppModel, DeferredActivityTransport) {
        let daemon = FakeDaemon()
        daemon.enqueue(.stream(try daemon.connectedStream()))
        let transport = DeferredActivityTransport(daemon.transport)
        let model = AppModel(environment: .init(discover: { testDiscovery }, makeClient: { DaemonClient(discovery: $0, transport: transport) }))
        model.start()
        await eventually { model.isConnected }
        return (model, transport)
    }
    private func page(_ project: String, task: String, id: String, more: Bool = false) -> ActivityPage {
        ActivityPage(entries: [ActivityEntry(id: id, projectId: project, at: "2026-10-25T08:00:00Z",
                                           actor: Actor(client: .cli, agent: "codex", taskId: task), detail: .object(["kind": .string("config")]))], hasMore: more)
    }
    private func query(_ request: URLRequest, _ key: String) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == key }?.value
    }

    @Test func manualTaskOutsideLoadedPageAndPaging() async throws {
        let (model, transport) = try await setup()
        defer { model.stop() }
        let id = try #require(model.projects.first?.id)
        model.activityVisible = id
        let first = Task { await model.setActivityTaskFilter("older-work", for: id) }
        await eventually { transport.pending.current[0] != nil }
        #expect(query(transport.requests.current[0], "task") == "older-work")
        #expect(query(transport.requests.current[0], "before") == nil)
        try transport.finish(0, page: page(id, task: "older-work", id: "a_new", more: true))
        await first.value
        let next = Task { await model.refreshActivity(id, more: true) }
        await eventually { transport.pending.current[1] != nil }
        #expect(query(transport.requests.current[1], "task") == "older-work")
        #expect(query(transport.requests.current[1], "before") == "a_new")
        try transport.finish(1, page: page(id, task: "older-work", id: "a_old"))
        await next.value
        #expect(model.activityEntries[id]?.map(\.id) == ["a_new", "a_old"])
        #expect(model.activityHasMore[id] == false)
        await model.setActivityTaskFilter("[REDACTED]", for: id)
        #expect(transport.requests.current.count == 2)
        #expect(model.activityTaskFilters[id] == "older-work")
        #expect(model.activityEntries[id]?.map(\.id) == ["a_new", "a_old"])
        #expect(model.activityError != nil)
        let retry = Task { await model.setActivityTaskFilter("older-work", for: id) }
        await eventually { transport.pending.current[2] != nil }
        #expect(model.activityError == nil)
        #expect(query(transport.requests.current[2], "before") == nil)
        try transport.finish(2, page: page(id, task: "older-work", id: "a_retry"))
        await retry.value
        #expect(model.activityEntries[id]?.map(\.id) == ["a_retry"])
    }

    @Test func changingTaskResetsCursorAndDiscardsLateSuccess() async throws {
        let (model, transport) = try await setup()
        defer { model.stop() }
        let id = try #require(model.projects.first?.id)
        model.activityVisible = id
        let old = Task { await model.setActivityTaskFilter("old-work", for: id) }
        await eventually { transport.pending.current[0] != nil }
        let fresh = Task { await model.setActivityTaskFilter("new-work", for: id) }
        await eventually { transport.pending.current[1] != nil }
        #expect(model.activityEntries[id]?.isEmpty == true)
        #expect(query(transport.requests.current[1], "before") == nil)
        try transport.finish(0, page: page(id, task: "old-work", id: "a_old", more: true))
        await old.value
        #expect(model.activityEntries[id]?.isEmpty == true)
        #expect(model.activityLoading.contains(id))
        try transport.finish(1, page: page(id, task: "new-work", id: "a_new"))
        await fresh.value
        #expect(model.activityEntries[id]?.map(\.id) == ["a_new"])
        #expect(!model.activityLoading.contains(id))
        #expect(model.activityError == nil)
    }

    @Test func clearingTaskDiscardsLateFailure() async throws {
        let (model, transport) = try await setup()
        defer { model.stop() }
        let id = try #require(model.projects.first?.id)
        model.activityVisible = id
        let old = Task { await model.setActivityTaskFilter("old-work", for: id) }
        await eventually { transport.pending.current[0] != nil }
        let clear = Task { await model.setActivityTaskFilter(nil, for: id) }
        await eventually { transport.pending.current[1] != nil }
        #expect(query(transport.requests.current[1], "task") == nil)
        #expect(query(transport.requests.current[1], "before") == nil)
        try transport.finish(1, page: page(id, task: "any-work", id: "a_any"))
        await clear.value
        transport.fail(0)
        await old.value
        #expect(model.activityTaskFilters[id] == nil)
        #expect(model.activityEntries[id]?.map(\.id) == ["a_any"])
        #expect(model.activityError == nil)
    }

    @Test func navigatingAwayAndBackInvalidatesEarlierRequest() async throws {
        let (model, transport) = try await setup()
        defer { model.stop() }
        let id = try #require(model.projects.first?.id)
        let other = try #require(model.projects.dropFirst().first?.id)
        model.activityVisible = id
        let old = Task { await model.refreshActivity(id) }
        await eventually { transport.pending.current[0] != nil }
        model.activityVisible = other
        model.activityVisible = id
        let fresh = Task { await model.refreshActivity(id) }
        await eventually { transport.pending.current[1] != nil }
        try transport.finish(1, page: page(id, task: "new-work", id: "a_fresh"))
        await fresh.value
        try transport.finish(0, page: page(id, task: "old-work", id: "a_old", more: true))
        await old.value
        #expect(model.activityEntries[id]?.map(\.id) == ["a_fresh"])
        #expect(model.activityHasMore[id] == false)
    }

    @Test func responseForDifferentTaskIsRejected() async throws {
        let (model, transport) = try await setup()
        defer { model.stop() }
        let id = try #require(model.projects.first?.id)
        model.activityVisible = id
        let request = Task { await model.setActivityTaskFilter("requested", for: id) }
        await eventually { transport.pending.current[0] != nil }
        try transport.finish(0, page: page(id, task: "different", id: "a_wrong"))
        await request.value
        #expect(model.activityEntries[id]?.isEmpty == true)
        #expect(model.activityError != nil)
    }

    @Test func redactedActorMatchesServerFilteredWorkWithoutBecomingFilterable() async throws {
        let (model, transport) = try await setup()
        defer { model.stop() }
        let id = try #require(model.projects.first?.id)
        model.activityVisible = id
        let request = Task { await model.setActivityTaskFilter("work-token", for: id) }
        await eventually { transport.pending.current[0] != nil }
        try transport.finish(0, page: page(id, task: "work-[REDACTED]", id: "a_masked"))
        await request.value
        #expect(model.activityError == nil)
        #expect(model.activityEntries[id]?.first?.id == "a_masked")
        #expect(model.activityEntries[id]?.first?.actor.filterableTaskId == nil)
    }
}
