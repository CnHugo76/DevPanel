import Foundation
import Testing

@testable import DevPanelKit

/// Scripts what each `GET /events` connection attempt does.
final class FakeDaemon: Sendable {
    enum Behavior: Sendable {
        case stream(FakeStream)
        /// Nothing listening on the port (URLError.cannotConnectToHost).
        case refuse
        case fail(URLError.Code)
        case status(Int, Data)
    }

    let transport: FakeTransport
    private let queue = Locked<[Behavior]>([])
    let attempts = Locked(0)

    init() {
        let transport = FakeTransport()
        self.transport = transport
        transport.setStream { [queue, attempts] _ in
            attempts.withLock { $0 += 1 }
            let next = queue.withLock { $0.isEmpty ? Behavior.fail(.networkConnectionLost) : $0.removeFirst() }
            switch next {
            case .stream(let s): return s
            case .refuse: throw URLError(.cannotConnectToHost)
            case .fail(let code): throw URLError(code)
            case .status(let code, let body):
                let s = FakeStream(status: code)
                s.send(body)
                s.finish()
                return s
            }
        }
    }

    func enqueue(_ behaviors: Behavior...) { queue.withLock { $0.append(contentsOf: behaviors) } }

    /// A stream that has already delivered the recorded snapshot.
    func connectedStream() throws -> FakeStream {
        let s = FakeStream()
        try s.sendEvent(fixture: "recorded/event-snapshot.json")
        return s
    }
}

@MainActor
@Suite("AppModel", .serialized)
struct AppModelTests {
    let daemon = FakeDaemon()
    let discovery = Locked<DaemonDiscovery?>(testDiscovery)
    let sleeps = Locked<[Duration]>([])
    let launches = Locked(0)

    /// Recording sleep: logs the requested delay, then yields briefly instead of waiting.
    func makeModel(
        timing: AppModel.Timing = AppModel.Timing(), realSleep: Bool = false,
        launch: @escaping @Sendable () async throws -> String = { "ok" }
    ) -> AppModel {
        let transport = daemon.transport
        let discovery = self.discovery
        let sleeps = self.sleeps
        let env = AppModel.Environment(
            discover: { discovery.current },
            makeClient: { DaemonClient(discovery: $0, transport: transport) },
            sleep: { d in
                sleeps.withLock { $0.append(d) }
                try await Task.sleep(for: realSleep ? d : .milliseconds(2))
            },
            launchDaemon: launch)
        return AppModel(environment: env, timing: timing)
    }

    static func snapshot() throws -> SnapshotEvent {
        guard case .snapshot(let s) = try Fixture.decode(DaemonEvent.self, "recorded/event-snapshot.json") else {
            throw ApiError(code: .internal, message: "fixture is not a snapshot")
        }
        return s
    }

    // MARK: apply()

    @Test("snapshot replaces all state")
    func snapshotReplaces() throws {
        let model = makeModel()
        let snap = try Self.snapshot()
        model.apply(.snapshot(snap))
        #expect(model.projects.count == 6)
        #expect(model.daemon == snap.daemon)
        #expect(model.stats == snap.stats)
        model.apply(.operation(try Fixture.decode(Operation.self, "recorded/operation-created.json")))
        #expect(model.operations.count == 1)

        var smaller = snap
        smaller.projects = [snap.projects[2]]
        smaller.stats = nil
        smaller.operations = []
        model.apply(.snapshot(smaller))
        #expect(model.projects.map(\.id) == [snap.projects[2].id])
        #expect(model.stats == nil)
        #expect(model.operations.isEmpty)
    }

    @Test("project.upsert replaces in place or appends; project.remove drops project and its stats")
    func upsertAndRemove() throws {
        let model = makeModel()
        let snap = try Self.snapshot()
        model.apply(.snapshot(snap))
        let ids = model.projects.map(\.id)

        var changed = snap.projects[1]
        changed.name = "renamed"
        changed.aggregate = .stopped
        model.apply(.projectUpsert(changed))
        #expect(model.projects.map(\.id) == ids, "order must not change")
        #expect(model.projects[1].name == "renamed")

        var added = snap.projects[0]
        added.id = "p_newproject"
        model.apply(.projectUpsert(added))
        #expect(model.projects.last?.id == "p_newproject")
        #expect(model.projects.count == 7)

        let running = try #require(snap.stats?.projects.keys.first)
        model.apply(.projectRemove(projectId: running))
        #expect(model.project(running) == nil)
        #expect(model.projectStats(running) == nil)
        #expect(model.projects.count == 6)
    }

    @Test("operations upsert; a finished operation never regresses")
    func operations() throws {
        let model = makeModel()
        let created = try Fixture.decode(Operation.self, "recorded/operation-created.json")
        let finished = try Fixture.decode(Operation.self, "recorded/operation-finished.json")
        model.apply(.operation(created))
        #expect(model.operations[created.id]?.state == .running)
        model.apply(.operation(finished))
        #expect(model.operations[created.id]?.state == .succeeded)
        model.apply(.operation(created))
        #expect(model.operations[created.id]?.state == .succeeded)
    }

    @Test("stats replace; derived counts")
    func statsAndCounts() throws {
        let model = makeModel()
        model.apply(.snapshot(try Self.snapshot()))
        #expect(model.serviceCount == model.projects.reduce(0) { $0 + $1.serviceCount })
        #expect(model.runningServiceCount == model.projects.reduce(0) { $0 + $1.runningCount })
        guard case .stats(let s) = try Fixture.decode(DaemonEvent.self, "recorded/event-stats.json") else { return }
        model.apply(.stats(s))
        #expect(model.stats == s)
        let pid = try #require(s.projects.keys.first)
        let sid = try #require(s.projects[pid]?.services.keys.first)
        #expect(model.serviceStats(pid, sid) != nil)
    }

    // MARK: connection loop

    @Test("connects via the event stream and applies live events")
    func connectsAndStreams() async throws {
        let stream = try daemon.connectedStream()
        daemon.enqueue(.stream(stream))
        let model = makeModel()
        #expect(model.connection.status == .connecting)
        model.start()
        await eventually { model.connection.status == .connected }
        #expect(model.projects.count == 6)
        #expect(model.client != nil)
        #expect(model.connection.lastEventAt != nil)
        #expect(model.connection.syncedAt != nil)
        #expect(model.connection.retryAt == nil)

        try stream.sendEvent(fixture: "recorded/event-project.upsert.json")
        try stream.sendEvent(fixture: "recorded/event-operation.json")
        let lastEvent = model.connection.lastEventAt
        try stream.sendEvent(fixture: "recorded/event-ping.json")
        await eventually { !model.operations.isEmpty && model.connection.lastEventAt != lastEvent }
        model.stop()
    }

    @Test("disconnect: keeps last state, backs off 1→2→5→10→10 s")
    func backoff() async throws {
        let stream = try daemon.connectedStream()
        daemon.enqueue(.stream(stream))
        let model = makeModel()
        model.start()
        await eventually { model.connection.status == .connected }
        let synced = model.connection.syncedAt

        stream.finish(throwing: URLError(.networkConnectionLost))
        await eventually { sleeps.current.count >= 5 }
        model.stop()

        #expect(Array(sleeps.current.prefix(5)) == [.seconds(1), .seconds(2), .seconds(5), .seconds(10), .seconds(10)])
        #expect(model.connection.status == .disconnected)
        #expect(model.connection.lastError?.code == .daemonUnreachable)
        #expect(model.connection.syncedAt == synced)
        #expect(model.connection.failures >= 5)
        #expect(model.projects.count == 6, "last known state stays visible while disconnected")
        #expect(model.client == nil)
    }

    @Test("a successful snapshot resets the backoff")
    func backoffResets() async throws {
        let stream = try daemon.connectedStream()
        daemon.enqueue(.fail(.timedOut), .fail(.networkConnectionLost), .stream(stream))
        let model = makeModel()
        model.start()
        await eventually { model.connection.status == .connected }
        #expect(sleeps.current == [.seconds(1), .seconds(2)])
        stream.finish()  // server closed the stream
        await eventually { sleeps.current.count >= 3 }
        model.stop()
        #expect(sleeps.current[2] == .seconds(1))
    }

    @Test("retryAt is set while waiting and retryNow() skips the wait")
    func retryNow() async throws {
        var timing = AppModel.Timing()
        timing.backoff = [.seconds(60)]
        daemon.enqueue(.fail(.networkConnectionLost), .stream(try daemon.connectedStream()))
        let model = makeModel(timing: timing, realSleep: true)
        model.start()
        await eventually { model.connection.status == .disconnected && model.connection.retryAt != nil }
        let wait = try #require(model.connection.retryAt).timeIntervalSinceNow
        #expect(wait > 55 && wait <= 60)
        #expect(model.connection.secondsUntilRetry(now: Date()) == 60)
        model.retryNow()
        await eventually { model.connection.status == .connected }
        model.stop()
    }

    @Test("no daemon.json → notRunning, polls, then connects when it appears")
    func notRunning() async throws {
        discovery.withLock { $0 = nil }
        let model = makeModel()
        model.start()
        await eventually { model.connection.status == .notRunning }
        #expect(!model.connection.staleDiscovery)
        #expect(model.connection.failures == 0)
        await eventually { sleeps.current.count >= 2 }
        #expect(sleeps.current.allSatisfy { $0 == .seconds(2) })
        #expect(daemon.attempts.current == 0, "no network attempt without a discovery file")

        daemon.enqueue(.stream(try daemon.connectedStream()))
        discovery.withLock { $0 = testDiscovery }
        await eventually { model.connection.status == .connected }
        model.stop()
    }

    @Test("daemon.json present but connection refused → notRunning (stale)")
    func staleDiscovery() async throws {
        daemon.enqueue(.refuse)
        let model = makeModel(realSleep: true)  // keep the transient state observable
        model.start()
        await eventually { model.connection.status == .notRunning }
        #expect(model.connection.staleDiscovery)
        model.stop()
    }

    @Test("401 → unauthorized with backoff")
    func unauthorized() async throws {
        daemon.enqueue(.status(401, try Fixture.data("recorded/error-unauthorized.json")))
        let model = makeModel(realSleep: true)  // keep the transient state observable
        model.start()
        await eventually { model.connection.status == .unauthorized }
        #expect(model.connection.lastError?.code == .unauthorized)
        #expect(sleeps.current.first == .seconds(1))
        model.stop()
    }

    @Test("silence longer than staleAfter → disconnected; pings keep it alive")
    func watchdog() async throws {
        var timing = AppModel.Timing()
        timing.staleAfter = .milliseconds(300)
        timing.watchdogInterval = .milliseconds(10)
        let stream = try daemon.connectedStream()
        daemon.enqueue(.stream(stream))
        // Real 1 s backoff so the next attempt does not overwrite lastError before we look.
        let model = makeModel(timing: timing, realSleep: true)
        model.start()
        await eventually { model.connection.status == .connected }

        // Pings every 50 ms for ~600 ms: must stay connected.
        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(50))
            try stream.sendEvent(fixture: "recorded/event-ping.json")
            #expect(model.connection.status == .connected)
        }
        // Then silence.
        await eventually { model.connection.status == .disconnected }
        #expect(model.connection.lastError?.message.contains("没有收到") == true)
        model.stop()
    }

    @Test("no snapshot within staleAfter after connecting → disconnected")
    func watchdogBeforeSnapshot() async throws {
        var timing = AppModel.Timing()
        timing.staleAfter = .milliseconds(100)
        timing.watchdogInterval = .milliseconds(10)
        daemon.enqueue(.stream(FakeStream()))
        let model = makeModel(timing: timing)
        model.start()
        await eventually { model.connection.status == .disconnected }
        #expect(model.connection.syncedAt == nil)
        model.stop()
    }

    // MARK: actions

    @Test("perform() posts the action with the ui client header and tracks the operation")
    func perform() async throws {
        let created = try Fixture.data("recorded/operation-created.json")
        daemon.transport.setHandler { r in
            // Since F2 the model also fetches each project's config after the snapshot.
            if r.httpMethod == "GET" { return (404, Data(#"{"error":{"code":"PROJECT_NOT_FOUND","message":"x"}}"#.utf8)) }
            #expect(r.url?.path == "/api/v1/operations")
            #expect(r.value(forHTTPHeaderField: "X-DevPanel-Client") == "ui")
            let body = try JSONSerialization.jsonObject(with: r.httpBody ?? Data()) as? [String: Any]
            #expect(body?["action"] as? String == "start")
            #expect(body?["projectId"] as? String == "p_mlapi22222")
            return (202, created)
        }
        let model = makeModel()
        await #expect { try await model.perform(ActionRequest(projectId: "p_mlapi22222", action: .start)) } throws: {
            ($0 as? ApiError)?.code == .daemonUnreachable
        }
        daemon.enqueue(.stream(try daemon.connectedStream()))
        model.start()
        await eventually { model.connection.status == .connected }
        let op = try await model.perform(ActionRequest(projectId: "p_mlapi22222", action: .start))
        #expect(model.operations[op.id] != nil)
        model.stop()
    }

    @Test("startDaemon() runs the launcher and reconnects immediately")
    func startDaemon() async throws {
        discovery.withLock { $0 = nil }
        var timing = AppModel.Timing()
        timing.notRunningPoll = .seconds(60)
        let discovery = self.discovery
        let launches = self.launches
        let daemon = self.daemon
        let stream = try daemon.connectedStream()
        let model = makeModel(timing: timing, realSleep: true, launch: {
            launches.withLock { $0 += 1 }
            daemon.enqueue(.stream(stream))
            discovery.withLock { $0 = testDiscovery }
            return "started"
        })
        model.start()
        await eventually { model.connection.status == .notRunning }
        await model.startDaemon()
        #expect(launches.current == 1)
        #expect(model.daemonLaunch == .idle)
        await eventually { model.connection.status == .connected }
        model.stop()
    }

    @Test("startDaemon() failure is reported, e.g. CLI not installed")
    func startDaemonFails() async throws {
        let model = makeModel(launch: { throw DaemonLauncher.Failure.cliNotFound(path: "/nowhere/devpanel") })
        await model.startDaemon()
        guard case .failed(let message) = model.daemonLaunch else {
            Issue.record("expected failure"); return
        }
        #expect(message.contains("接入第一个项目"))
    }
}

@Suite("Wording")
struct WordingTests {
    @Test func toolbarSummary() {
        var c = ConnectionState()
        let now = Date()
        #expect(c.summary(running: 0, total: 0, projectCount: 0, now: now) == "正在连接管理服务…")
        c.status = .connected
        #expect(c.summary(running: 4, total: 7, projectCount: 3, now: now) == "已连接 · 4/7 服务运行中")
        #expect(c.summary(running: 0, total: 0, projectCount: 0, now: now) == "已连接 · 还没有项目")
        c.status = .disconnected
        c.retryAt = now.addingTimeInterval(4.2)
        #expect(c.summary(running: 4, total: 7, projectCount: 3, now: now) == "管理服务连接中断 · 5 秒后重连")
        c.retryAt = nil
        #expect(c.summary(running: 4, total: 7, projectCount: 3, now: now) == "管理服务连接中断 · 正在重连")
        c.status = .notRunning
        #expect(c.summary(running: 0, total: 0, projectCount: 0, now: now) == "管理服务未运行")
        #expect(c.tone == .neutral)
    }

    @Test func aggregateLabels() {
        #expect(ProjectAggregate.running.label(running: 2, total: 2) == "2/2 运行中")
        #expect(ProjectAggregate.partial.label(running: 1, total: 2) == "部分运行 1/2")
        #expect(ProjectAggregate.failed.label(running: 0, total: 2) == "异常")
        #expect(ProjectAggregate.other("x").label(running: 0, total: 1) == "x")
    }
}
