import Foundation
import Testing

@testable import DevPanelKit

/// F2 additions to `AppModel`: config cache, selection, tracked actions, force-stop counts.
@MainActor
@Suite("AppModel overview", .serialized)
struct OverviewModelTests {
    let daemon = FakeDaemon()

    func makeModel() -> AppModel {
        let transport = daemon.transport
        let env = AppModel.Environment(
            discover: { testDiscovery },
            makeClient: { DaemonClient(discovery: $0, transport: transport) },
            sleep: { _ in try await Task.sleep(for: .milliseconds(2)) })
        return AppModel(environment: env)
    }

    func snapshot() throws -> SnapshotEvent {
        guard case .snapshot(let s) = try Fixture.decode(DaemonEvent.self, "recorded/event-snapshot.json") else {
            throw ApiError(code: .internal, message: "not a snapshot")
        }
        return s
    }

    /// Routes GET /projects/:id (order-service only), POST /operations and GET …/wait.
    func route(
        created: Data? = nil, finished: Data? = nil, postStatus: Int = 202, posts: Locked<Int> = Locked(0),
        configGets: Locked<Int> = Locked(0)
    ) throws {
        let order = try Fixture.data("recorded/project-order-service.json")
        daemon.transport.setHandler { r in
            let path = r.url?.path ?? ""
            switch (r.httpMethod ?? "GET", path) {
            case ("GET", "/api/v1/projects/p_ordersvc2a"):
                configGets.withLock { $0 += 1 }
                return (200, order)
            case ("POST", "/api/v1/operations"):
                posts.withLock { $0 += 1 }
                return (postStatus, created ?? Data())
            case ("GET", let p) where p.hasSuffix("/wait"):
                if let finished { return (200, finished) }
                throw URLError(.timedOut)
            default:
                return (404, Data(#"{"error":{"code":"PROJECT_NOT_FOUND","message":"no"}}"#.utf8))
            }
        }
    }

    @Test("configs load after the snapshot, failures are not retried for the same revision")
    func configCache() async throws {
        let gets = Locked(0)
        try route(configGets: gets)
        daemon.enqueue(.stream(try daemon.connectedStream()))
        let model = makeModel()
        model.start()
        await eventually { model.isConnected && model.configsLoaded }
        #expect(model.configs["p_ordersvc2a"]?.revision == 3)
        #expect(model.params("p_ordersvc2a").map(\.key) == ["profile", "apiPort", "host"])
        #expect(model.serviceConfig("p_ordersvc2a", "backend")?.command.first == "./mvnw")
        #expect(model.params("p_mlapi22222").isEmpty, "404 → no config, but counted as loaded")
        #expect(gets.current == 1)

        // A newer revision of the same project triggers a refetch; an older stored config is ignored.
        var upsert = try snapshot().projects[0]
        upsert.revision = 4
        model.apply(.projectUpsert(upsert))
        #expect(!model.configsLoaded)
        var older = try #require(model.configs["p_ordersvc2a"])
        older.revision = 2
        model.storeConfig(older)
        #expect(model.configs["p_ordersvc2a"]?.revision == 3)
        model.apply(.projectRemove(projectId: "p_ordersvc2a"))
        #expect(model.configs["p_ordersvc2a"] == nil)
        model.stop()
    }

    @Test("runAction records a result; a duplicate click sends nothing; the wait poll finishes it")
    func runActionTracksResult() async throws {
        let posts = Locked(0)
        try route(
            created: try Fixture.data("recorded/operation-created.json"),
            finished: try Fixture.data("recorded/operation-finished.json"), posts: posts)
        daemon.enqueue(.stream(try daemon.connectedStream()))
        let model = makeModel()
        model.start()
        await eventually { model.isConnected }

        let request = ActionRequest(projectId: "p_mlapi22222", action: .start)
        await model.runAction(request)
        #expect(posts.current == 1)
        #expect(model.actionResults["p_mlapi22222"]?.operationId == "op_01M5CCS8XWX71DCXTAAG5RAXGV")
        #expect(model.actionResults["p_mlapi22222"]?.action == .start)
        await eventually { model.finishedOperation(for: "p_mlapi22222") != nil }
        #expect(!model.isPending(request))
        #expect(!model.hasPendingAction(projectId: "p_mlapi22222"))
        #expect(model.finishedOperation(for: "p_mlapi22222")?.summary { $0 }.title == "已启动")

        model.dismissResult("p_mlapi22222")
        #expect(model.actionResults["p_mlapi22222"] == nil)
        model.stop()
    }

    @Test("a second runAction while the first is unfinished is ignored")
    func doubleClickGuard() async throws {
        let posts = Locked(0)
        try route(created: try Fixture.data("recorded/operation-created.json"), finished: nil, posts: posts)
        daemon.enqueue(.stream(try daemon.connectedStream()))
        let model = makeModel()
        model.start()
        await eventually { model.isConnected }
        let request = ActionRequest(projectId: "p_mlapi22222", serviceIds: ["api"], action: .start)
        await model.runAction(request)
        #expect(model.isPending(request))
        #expect(model.hasPendingAction(projectId: "p_mlapi22222", serviceId: "api"))
        #expect(!model.hasPendingAction(projectId: "p_mlapi22222", serviceId: "other"))
        await model.runAction(request)
        #expect(posts.current == 1)
        // The finished operation arrives on the event stream.
        model.apply(.operation(try Fixture.decode(Operation.self, "recorded/operation-finished.json")))
        #expect(!model.isPending(request))
        model.stop()
    }

    @Test("a rejected request becomes a result with the error")
    func rejected() async throws {
        let model = makeModel()
        await model.runAction(ActionRequest(projectId: "p_x", action: .stop))
        #expect(model.actionResults["p_x"]?.error?.code == .daemonUnreachable)
        #expect(!model.isPending(ActionRequest(projectId: "p_x", action: .stop)))
    }

    @Test("a snapshot keeps the operation behind a visible result bar")
    func snapshotKeepsTrackedOperation() async throws {
        try route(
            created: try Fixture.data("recorded/operation-created.json"),
            finished: try Fixture.data("recorded/operation-finished.json"))
        daemon.enqueue(.stream(try daemon.connectedStream()))
        let model = makeModel()
        model.start()
        await eventually { model.isConnected }
        await model.runAction(ActionRequest(projectId: "p_mlapi22222", action: .start))
        await eventually { model.finishedOperation(for: "p_mlapi22222") != nil }
        model.stop()
        var snap = try snapshot()
        snap.operations = []
        model.apply(.snapshot(snap))
        #expect(model.finishedOperation(for: "p_mlapi22222") != nil)
        snap.projects.removeAll { $0.id == "p_mlapi22222" }
        model.apply(.snapshot(snap))
        #expect(model.actionResults["p_mlapi22222"] == nil)
    }

    @Test("selection only accepts existing services and is cleared when they disappear")
    func selection() throws {
        let model = makeModel()
        model.apply(.snapshot(try snapshot()))
        model.select(ServiceRef("p_ordersvc2a", "nope"))
        #expect(model.selection == nil)
        model.select(ServiceRef("p_ordersvc2a", "frontend"))
        #expect(model.selection == ServiceRef("p_ordersvc2a", "frontend"))
        var changed = try #require(model.project("p_ordersvc2a"))
        changed.services.removeAll { $0.id == "frontend" }
        model.apply(.projectUpsert(changed))
        #expect(model.selection == nil)
        model.select(ServiceRef("p_ordersvc2a", "backend"))
        model.apply(.projectRemove(projectId: "p_ordersvc2a"))
        #expect(model.selection == nil)
        model.select(ServiceRef("p_webadmin22", "web"))
        model.select(nil)
        #expect(model.selection == nil)
    }

    @Test("force-stop count: STOP_TIMEOUT remaining first, then current-run stats, else unknown")
    func forceStopCount() throws {
        let model = makeModel()
        var snap = try snapshot()
        model.apply(.snapshot(snap))
        // From stats (backend 4 + frontend 2 in the recorded snapshot).
        #expect(model.forceStopProcessCount("p_ordersvc2a", serviceIds: ["backend"]) == 4)
        #expect(model.forceStopProcessCount("p_ordersvc2a", serviceIds: nil) == 6)
        #expect(model.forceStopProcessCount("p_mlapi22222", serviceIds: nil) == nil, "nothing running")
        // From the timeout error.
        var stuck = try Fixture.decode(ServiceView.self, "handwritten/service-view-stopping-timeout.json")
        stuck.id = "backend"
        snap.projects[0].services[0] = stuck
        model.apply(.snapshot(snap))
        #expect(model.forceStopProcessCount("p_ordersvc2a", serviceIds: ["backend"]) == 3)
        // Stats of another run → unknown.
        model.apply(.stats(StatsSnapshot(sampledAt: "", intervalMs: 2000, projects: [:])))
        #expect(model.forceStopProcessCount("p_ordersvc2a", serviceIds: ["frontend"]) == nil)
        #expect(model.lastStatsAt != nil)
    }
}
