import Foundation
import Testing

@testable import DevPanelKit

/// Requests wait until the test answers them; each log stream is a controllable `FakeStream`.
final class GatedTransport: HTTPTransport, @unchecked Sendable {
    struct Pending {
        let request: URLRequest
        let continuation: CheckedContinuation<(Int, Data), any Error>
    }

    let pending = Locked<[Pending]>([])
    let streams = Locked<[(request: URLRequest, stream: FakeStream)]>([])

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (status, data) = try await withCheckedThrowingContinuation { c in
            pending.withLock { $0.append(Pending(request: request, continuation: c)) }
        }
        return (data, FakeTransport.response(request, status))
    }

    func stream(_ request: URLRequest, receive: (StreamPart) async throws -> Void) async throws {
        let s = FakeStream()
        streams.withLock { $0.append((request, s)) }
        try await receive(.response(FakeTransport.response(request, 200)))
        for try await chunk in s.chunks {
            try await receive(.data(chunk))
        }
    }

    var pendingPaths: [String] { pending.current.map { Self.describe($0.request) } }
    var streamPaths: [String] { streams.current.map { Self.describe($0.request) } }

    static func describe(_ r: URLRequest) -> String {
        let url = r.url!
        return url.path.replacingOccurrences(of: "/api/v1", with: "") + (url.query.map { "?" + $0 } ?? "")
    }

    /// Answers the first pending request whose path+query contains `match`.
    func respond(_ match: String, status: Int = 200, _ body: some Encodable) throws {
        let data = try ContractCoding.encoder().encode(body)
        let p = pending.withLock { list -> Pending? in
            guard let i = list.firstIndex(where: { Self.describe($0.request).contains(match) }) else { return nil }
            return list.remove(at: i)
        }
        let found = try #require(p, "no pending request matching \(match); pending: \(pendingPaths)")
        found.continuation.resume(returning: (status, data))
    }

    func failAll() {
        let all = pending.withLock { l -> [Pending] in defer { l.removeAll() }; return l }
        for p in all { p.continuation.resume(throwing: URLError(.cancelled)) }
    }

    func stream(_ index: Int) -> FakeStream { streams.current[index].stream }
}

extension FakeStream {
    func send(event: LogStreamEvent) throws {
        let data = try ContractCoding.encoder().encode(event)
        send("event: \(event.type)\ndata: \(String(decoding: data, as: UTF8.self))\n\n")
    }
}

func page(_ runId: RunID, _ seqs: ClosedRange<Int>?, hasMoreBefore: Bool = false, ended: Bool = false, truncated: Bool = false) -> LogPage {
    let lines = seqs.map { $0.map { logLine($0, "\(runId) #\($0)") } } ?? []
    return LogPage(
        runId: runId, lines: lines, firstSeq: lines.first?.seq, lastSeq: lines.last?.seq, truncated: truncated,
        hasMoreBefore: hasMoreBefore, hasMoreAfter: false, runEnded: ended)
}

@MainActor
@Suite("LogSession", .serialized)
struct LogSessionTests {
    let transport = GatedTransport()
    let sleeps = Locked<[Duration]>([])

    func makeSession(cap: Int = LogBuffer.defaultCap) -> LogSession {
        let sleeps = self.sleeps
        let session = LogSession(cap: cap, environment: LogSession.Environment(
            sleep: { d in
                sleeps.withLock { $0.append(d) }
                try await Task.sleep(for: .milliseconds(2))
            }))
        let client = DaemonClient(discovery: testDiscovery, transport: transport)
        session.clientProvider = { client }
        return session
    }

    let a = LogTarget(projectId: "p", serviceId: "s", runId: "r_A")
    let b = LogTarget(projectId: "p", serviceId: "s", runId: "r_B")

    @Test func loadsTailThenStreamsFromLastSeq() async throws {
        let session = makeSession()
        session.open(a)
        #expect(session.status.loading)
        await eventually { transport.pendingPaths.count == 1 }
        #expect(transport.pendingPaths == ["/runs/r_A/logs?limit=1000"])
        try transport.respond("/runs/r_A/logs", page("r_A", 1...20, hasMoreBefore: true))
        await eventually { transport.streams.current.count == 1 }
        #expect(transport.streamPaths == ["/runs/r_A/logs/stream?afterSeq=20"])
        #expect(session.buffer.count == 20)
        #expect(!session.status.loading)
        #expect(session.status.streaming)

        try transport.stream(0).send(event: .lines(runId: "r_A", lines: (21...25).map { logLine($0) }))
        await eventually { session.buffer.lastSeq == 25 }
        #expect(session.unseen == 5)
        session.markSeen()
        #expect(session.unseen == 0)
        session.close()
        transport.failAll()
    }

    @Test func lateResponseForThePreviousRunIsDropped() async throws {
        let session = makeSession()
        session.open(a)
        await eventually { transport.pendingPaths.count == 1 }
        session.open(b)
        await eventually { transport.pendingPaths.count == 2 }
        // B answers first, then the stale A response arrives.
        try transport.respond("/runs/r_B/logs", page("r_B", 1...3))
        await eventually { session.buffer.count == 3 }
        try transport.respond("/runs/r_A/logs", page("r_A", 1...50))
        try await Task.sleep(for: .milliseconds(50))
        #expect(session.target == b)
        #expect(session.buffer.count == 3)
        #expect(session.buffer.entries.allSatisfy { $0.line.text.hasPrefix("r_B") })
        session.close()
        transport.failAll()
    }

    @Test func pageForAnotherRunIdIsIgnored() async throws {
        let session = makeSession()
        session.open(a)
        await eventually { transport.pendingPaths.count == 1 }
        try transport.respond("/runs/r_A/logs", page("r_OTHER", 1...9))
        try await Task.sleep(for: .milliseconds(50))
        #expect(session.buffer.isEmpty)
        #expect(session.status.loading)
        #expect(transport.streams.current.isEmpty)
        session.close()
        transport.failAll()
    }

    @Test func switchingRunClosesTheOldStream() async throws {
        let session = makeSession()
        session.open(a)
        await eventually { transport.pendingPaths.count == 1 }
        try transport.respond("/runs/r_A/logs", page("r_A", 1...5))
        await eventually { transport.streams.current.count == 1 }
        session.open(b)
        await eventually { transport.pendingPaths.count == 1 }
        try transport.respond("/runs/r_B/logs", page("r_B", 1...2))
        await eventually { transport.streams.current.count == 2 }
        // The old connection keeps talking: nothing of it may reach the buffer.
        try? transport.stream(0).send(event: .lines(runId: "r_A", lines: (6...9).map { logLine($0) }))
        try transport.stream(1).send(event: .lines(runId: "r_A", lines: (3...4).map { logLine($0) }))  // wrong run on B's stream
        try transport.stream(1).send(event: .lines(runId: "r_B", lines: [logLine(3, "r_B #3")]))
        await eventually { session.buffer.lastSeq == 3 }
        try await Task.sleep(for: .milliseconds(30))
        #expect(session.buffer.entries.map(\.seq) == [1, 2, 3])
        #expect(session.buffer.entries.allSatisfy { $0.line.text.hasPrefix("r_B") })
        session.close()
        transport.failAll()
    }

    @Test func droppedStreamResumesFromLastSeq() async throws {
        let session = makeSession()
        session.open(a)
        await eventually { transport.pendingPaths.count == 1 }
        try transport.respond("/runs/r_A/logs", page("r_A", 1...10))
        await eventually { transport.streams.current.count == 1 }
        try transport.stream(0).send(event: .lines(runId: "r_A", lines: (11...12).map { logLine($0) }))
        await eventually { session.buffer.lastSeq == 12 }
        transport.stream(0).finish(throwing: URLError(.networkConnectionLost))
        await eventually { transport.streams.current.count == 2 }
        #expect(transport.streamPaths[1] == "/runs/r_A/logs/stream?afterSeq=12")
        #expect(sleeps.current.first == .seconds(1))
        // Replayed lines are deduplicated.
        try transport.stream(1).send(event: .lines(runId: "r_A", lines: (11...14).map { logLine($0) }))
        await eventually { session.buffer.lastSeq == 14 }
        #expect(session.buffer.count == 14)
        session.close()
        transport.failAll()
    }

    @Test func truncatedGapAndEnd() async throws {
        let session = makeSession()
        session.open(a)
        await eventually { transport.pendingPaths.count == 1 }
        try transport.respond("/runs/r_A/logs", page("r_A", 1...10))
        await eventually { transport.streams.current.count == 1 }
        try transport.stream(0).send(event: .truncated(runId: "r_A", firstSeq: 5))
        await eventually { session.status.truncated }
        try transport.stream(0).send(event: .gap(runId: "r_A", afterSeq: 40, reason: "客户端读取过慢，已丢弃 30 行待发送日志"))
        // A gap reopens the stream from the last seq we hold, so the dropped lines are replayed.
        await eventually { transport.streams.current.count == 2 }
        #expect(transport.streamPaths[1] == "/runs/r_A/logs/stream?afterSeq=10")
        #expect(session.status.gap == "客户端读取过慢，已丢弃 30 行待发送日志")
        let run = RunSummary(id: "r_A", projectId: "p", serviceId: "s", configRevision: 1, startedAt: "x", endedAt: "y", pid: 1, state: .stopped, exit: nil)
        try transport.stream(1).send(event: .lines(runId: "r_A", lines: (11...40).map { logLine($0) }))
        try transport.stream(1).send(event: .end(runId: "r_A", run: .service(run)))
        await eventually { session.status.ended }
        #expect(session.buffer.lastSeq == 40)
        #expect(session.status.endedRun?.id == "r_A")
        #expect(!session.status.streaming)
        transport.stream(1).finish()
        try await Task.sleep(for: .milliseconds(50))
        #expect(transport.streams.current.count == 2)  // no reconnect after end
        session.close()
        transport.failAll()
    }

    @Test func endedRunDoesNotStream() async throws {
        let session = makeSession()
        session.open(a)
        await eventually { transport.pendingPaths.count == 1 }
        try transport.respond("/runs/r_A/logs", page("r_A", 1...3, ended: true))
        await eventually { session.status.ended }
        try await Task.sleep(for: .milliseconds(30))
        #expect(transport.streams.current.isEmpty)
        session.close()
    }

    @Test func loadOlderPrependsWithBefore() async throws {
        let session = makeSession()
        session.open(a)
        await eventually { transport.pendingPaths.count == 1 }
        try transport.respond("/runs/r_A/logs", page("r_A", 1001...2000, hasMoreBefore: true))
        await eventually { transport.streams.current.count == 1 }
        let older = Task { await session.loadOlder() }
        await eventually { transport.pendingPaths.count == 1 }
        #expect(transport.pendingPaths == ["/runs/r_A/logs?before=1001&limit=1000"])
        try transport.respond("before=1001", page("r_A", 1...1000, hasMoreBefore: false))
        await older.value
        #expect(session.buffer.count == 2000)
        #expect(session.buffer.firstSeq == 1)
        #expect(!session.buffer.hasMoreBefore)
        session.close()
        transport.failAll()
    }

    @Test func olderPageForAPreviousTargetIsDropped() async throws {
        let session = makeSession()
        session.open(a)
        await eventually { transport.pendingPaths.count == 1 }
        try transport.respond("/runs/r_A/logs", page("r_A", 101...200, hasMoreBefore: true))
        await eventually { session.buffer.count == 100 }
        let older = Task { await session.loadOlder() }
        await eventually { transport.pendingPaths.count == 1 }
        session.open(b)
        await eventually { transport.pendingPaths.count == 2 }
        try transport.respond("before=101", page("r_A", 1...100))
        await older.value
        #expect(session.buffer.isEmpty)
        #expect(session.target == b)
        session.close()
        transport.failAll()
    }

    @Test func capKeepsTheNewestLines() async throws {
        let session = makeSession(cap: 100)
        session.open(a)
        await eventually { transport.pendingPaths.count == 1 }
        try transport.respond("/runs/r_A/logs", page("r_A", 1...80))
        await eventually { transport.streams.current.count == 1 }
        try transport.stream(0).send(event: .lines(runId: "r_A", lines: (81...250).map { logLine($0) }))
        await eventually { session.buffer.lastSeq == 250 }
        #expect(session.buffer.count == 100)
        #expect(session.buffer.firstSeq == 151)
        #expect(session.buffer.localTrimmed)
        #expect(session.buffer.hasMoreBefore)
        session.close()
        transport.failAll()
    }

    @Test func missingRunShowsRetentionMessage() async throws {
        let session = makeSession()
        session.open(a)
        await eventually { transport.pendingPaths.count == 1 }
        try transport.respond(
            "/runs/r_A/logs", status: 404, ErrorBody(error: ApiError(code: .runNotFound, message: "run not found")))
        await eventually { session.status.error != nil }
        #expect(session.status.error == "该运行的日志已按保留策略删除")
        #expect(LogEmptyState.make(hasRun: true, status: session.status, lineCount: 0, live: false) == .error("该运行的日志已按保留策略删除"))
        session.close()
    }

    @Test func noClientWaitsAndConnectionRestoredRetries() async throws {
        let session = makeSession()
        let client = DaemonClient(discovery: testDiscovery, transport: transport)
        let connected = Locked(false)
        session.clientProvider = { connected.current ? client : nil }
        session.open(a)
        try await Task.sleep(for: .milliseconds(30))
        #expect(transport.pendingPaths.isEmpty)
        connected.withLock { $0 = true }
        session.connectionRestored()
        await eventually { transport.pendingPaths.count == 1 }
        try transport.respond("/runs/r_A/logs", page("r_A", 1...4))
        await eventually { transport.streams.current.count == 1 }
        session.close()
        transport.failAll()
    }
}

@MainActor
@Suite("AppModel inspector", .serialized)
struct AppModelInspectorTests {
    func model() throws -> AppModel {
        let m = AppModel(environment: AppModel.Environment(
            discover: { nil }, makeClient: { DaemonClient(discovery: $0, transport: FakeTransport()) }))
        m.apply(try Fixture.decode(DaemonEvent.self, "recorded/event-snapshot.json"))
        return m
    }

    @Test func viewedRunFollowsTheNewestUnlessAnOlderOneIsChosen() throws {
        let m = try model()
        let ref = ServiceRef("p_ordersvc2a", "backend")
        let current = try #require(m.project("p_ordersvc2a")?.service("backend")?.currentRun)
        var older = current
        older.id = "r_older"
        older.startedAt = "2026-10-19T00:00:00.000Z"
        older.endedAt = "2026-10-19T01:00:00.000Z"
        older.state = .stopped
        m.inspector.fetchedRuns[ref] = [older]
        #expect(m.runs(for: ref).map(\.id) == [current.id, "r_older"])
        #expect(m.viewedRunId(for: ref) == current.id)
        #expect(!m.isViewingHistory(ref))

        m.chooseRun("r_older", for: ref)
        #expect(m.viewedRunId(for: ref) == "r_older")
        #expect(m.isViewingHistory(ref))
        // A run that is no longer kept falls back to the newest.
        m.inspector.runChoice[ref] = "r_gone"
        #expect(m.viewedRunId(for: ref) == current.id)
        m.chooseRun(current.id, for: ref)
        #expect(m.inspector.runChoice[ref] == nil)
    }

    @Test func openLogsSelectsAndSwitchesTab() throws {
        let m = try model()
        m.inspector.tab = .runs
        m.openLogs(ServiceRef("p_ordersvc2a", "frontend"))
        #expect(m.selection == ServiceRef("p_ordersvc2a", "frontend"))
        #expect(m.inspector.tab == .logs)
        // Unknown service: nothing changes.
        m.inspector.tab = .command
        m.openLogs(ServiceRef("p_ordersvc2a", "nope"))
        #expect(m.inspector.tab == .command)
    }

    @Test func syncLogSessionTargetsTheSelection() throws {
        let m = try model()
        m.select(ServiceRef("p_mlapi22222", "api"))  // never ran
        m.syncLogSession()
        #expect(m.inspector.logs.target == nil)
        m.select(ServiceRef("p_docssite22", "docs"))
        m.syncLogSession()
        #expect(m.inspector.logs.target?.runId == m.project("p_docssite22")?.service("docs")?.lastRun?.id)
        m.select(nil)
        m.syncLogSession()
        #expect(m.inspector.logs.target == nil)
    }

    @Test func displayNowWhileConnectedIsTheWallClock() throws {
        let m = try model()
        let wall = Date()
        #expect(m.displayNow(wall) == wall)
        #expect(!m.isStale)
    }
}
