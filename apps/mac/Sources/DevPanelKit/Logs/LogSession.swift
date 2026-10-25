import Foundation
import Observation

/// The run whose log is on screen.
public struct LogTarget: Hashable, Sendable {
    public var owner: LogOwner
    public var runId: RunID
    public init(projectId: ProjectID, serviceId: ServiceID, runId: RunID) {
        owner = .service(ServiceRef(projectId, serviceId)); self.runId = runId
    }
    public init(task: TaskRef, runId: RunID) { owner = .task(task); self.runId = runId }
    public var ref: ServiceRef? { owner.service }

}

public struct LogStatus: Equatable, Sendable {
    /// First page requested, not arrived yet.
    public var loading = false
    /// Why the first page could not be loaded (retried unless the run is gone).
    public var error: String?
    /// Live stream open.
    public var streaming = false
    /// Stream dropped (or no connection); retrying from the last seq.
    public var reconnecting = false
    /// The run ended and every line was delivered (`end`, or a page with `runEnded`).
    public var ended = false
    public var endedRun: LogRun?
    /// The daemon dropped older content of this run (per-run byte limit).
    public var truncated = false
    /// Reason of the last `gap` event ("采集中断：…").
    public var gap: String?
    public var loadingOlder = false
    public var loadingNewer = false
    /// Collection time of the newest loaded line.
    public var lastLineAt: Date?

    public init() {}
}

/// The single log subscription of the window: the run currently on screen (ported from
/// apps/ui/src/logs/session.ts, ui-design v1 §5.4 / §8).
///
/// - `open` loads the newest page (`GET /runs/:id/logs`), then follows
///   `/runs/:id/logs/stream?afterSeq=<last seq>`; `loadOlder` pages back with `before=`.
/// - Every response and stream event is checked against the target's `runId` and a generation
///   counter (bumped by every `open` / `close`); each stream connection has its own counter too,
///   so nothing from a previously viewed run — or a superseded connection — reaches the buffer.
/// - A dropped stream reconnects with backoff (1 s → 2 s → 5 s → 10 s) from the last seq it
///   holds; `connectionRestored()` retries immediately. A `gap` reopens the stream from the last
///   seq at most every 5 s so the lines that connection dropped are replayed.
/// - At most `LogBuffer.cap` lines stay in memory; the oldest are dropped (`localTrimmed`).
@Observable
@MainActor
public final class LogSession {
    public struct Environment: Sendable {
        public var sleep: @Sendable (Duration) async throws -> Void
        public var now: @Sendable () -> Date

        public init(
            sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
            now: @escaping @Sendable () -> Date = { Date() }
        ) {
            self.sleep = sleep
            self.now = now
        }
    }

    public static let pageSize = 1000
    public static let backoff: [Duration] = [.seconds(1), .seconds(2), .seconds(5), .seconds(10)]
    public static let tailRetry: Duration = .seconds(3)
    public static let gapReopenInterval: TimeInterval = 5

    public private(set) var target: LogTarget?
    public private(set) var buffer: LogBuffer
    public private(set) var status = LogStatus()
    /// Bumps when the content is replaced (open, close, reload): the view rebuilds.
    public private(set) var epoch = 0
    /// Bumps on every change of `buffer`: the view applies the difference.
    public private(set) var revision = 0
    /// Lines appended live since `markSeen()` ("↓ N 条新日志").
    public private(set) var unseen = 0

    /// The connected client, nil while disconnected (set by `AppModel`).
    @ObservationIgnored public var clientProvider: @MainActor () -> DaemonClient? = { nil }
    /// Called after every buffer change (search refresh).
    @ObservationIgnored public var onLinesChanged: (@MainActor () -> Void)?

    @ObservationIgnored private let env: Environment
    @ObservationIgnored private let cap: Int
    @ObservationIgnored private var gen = 0
    @ObservationIgnored private var streamGen = 0
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var lastGapReopen: Date?
    @ObservationIgnored private var tailInFlight = false
    /// Stream connections opened so far (tests, diagnostics).
    @ObservationIgnored public private(set) var streamsOpened = 0

    public init(cap: Int = LogBuffer.defaultCap, environment: Environment = Environment()) {
        self.cap = cap
        self.env = environment
        self.buffer = LogBuffer(cap: cap)
    }

    // MARK: Target

    /// Shows `target` (nil closes). Re-opening the same target does nothing.
    public func open(_ target: LogTarget?) {
        if target == self.target { return }
        close()
        guard let target else { return }
        self.target = target
        status.loading = true
        let g = gen
        Task { await self.loadTail(g) }
    }

    /// Closes the stream and forgets everything.
    public func close() {
        gen &+= 1
        streamGen &+= 1
        streamTask?.cancel()
        streamTask = nil
        retryTask?.cancel()
        retryTask = nil
        attempt = 0
        lastGapReopen = nil
        tailInFlight = false
        target = nil
        buffer = LogBuffer(cap: cap)
        status = LogStatus()
        unseen = 0
        epoch &+= 1
        revision &+= 1
        onLinesChanged?()
    }

    /// Loads the newest page again and resumes streaming ("跳到最新" while detached).
    public func reloadTail() {
        guard let target else { return }
        close()
        self.target = target
        status.loading = true
        let g = gen
        Task { await self.loadTail(g) }
    }

    /// The new-lines counter is reset (the user is at the bottom again).
    public func markSeen() {
        if unseen != 0 { unseen = 0 }
    }

    /// The daemon connection came back: retry a failed first page or a dropped stream now.
    public func connectionRestored() {
        guard target != nil else { return }
        let g = gen
        if !tailInFlight && (status.error != nil || status.loading) {
            retryTask?.cancel()
            retryTask = nil
            Task { await self.loadTail(g) }
        } else if status.reconnecting || (!status.streaming && !status.ended && !buffer.detached && !status.loading) {
            attempt = 0
            startStream(g)
        }
    }

    // MARK: Paging

    /// Prepends the page before the oldest loaded line (scrolled to the top).
    public func loadOlder() async {
        guard let target, let before = buffer.firstSeq, buffer.hasMoreBefore, !status.loadingOlder,
              let client = clientProvider() else { return }
        let g = gen
        status.loadingOlder = true
        defer { if g == gen { status.loadingOlder = false } }
        do {
            let page = try await client.logs(target.runId, before: before, limit: Self.pageSize)
            guard g == gen, page.runId == target.runId else { return }
            let entries = await LogEntry.parse(page.lines)
            guard g == gen else { return }
            let wasDetached = buffer.detached
            if buffer.prepend(entries, hasMoreBefore: page.hasMoreBefore) > 0 { changed() }
            if page.truncated { status.truncated = true }
            if buffer.detached && !wasDetached {
                // The newest lines were dropped: stop following until back at the tail.
                streamGen &+= 1
                streamTask?.cancel()
                streamTask = nil
                retryTask?.cancel()
                retryTask = nil
                status.streaming = false
                status.reconnecting = false
            }
        } catch {
            // keep what we have
        }
    }

    /// While detached: appends the page after the newest loaded line (scrolled to the bottom).
    public func loadNewer() async {
        guard let target, let after = buffer.lastSeq, buffer.detached, !status.loadingNewer,
              let client = clientProvider() else { return }
        let g = gen
        status.loadingNewer = true
        defer { if g == gen { status.loadingNewer = false } }
        do {
            let page = try await client.logs(target.runId, after: after, limit: Self.pageSize)
            guard g == gen, page.runId == target.runId else { return }
            let entries = await LogEntry.parse(page.lines)
            guard g == gen else { return }
            if buffer.appendPage(entries, hasMoreAfter: page.hasMoreAfter) > 0 { changed() }
            if page.runEnded && !page.hasMoreAfter { status.ended = true }
            if !buffer.detached && !status.ended { startStream(g) }
        } catch {
            // ignore
        }
    }

    // MARK: First page

    private func loadTail(_ g: Int) async {
        guard g == gen, let target else { return }
        guard let client = clientProvider() else {
            scheduleTailRetry(g)
            return
        }
        tailInFlight = true
        defer { if g == gen { tailInFlight = false } }
        do {
            let page = try await client.logs(target.runId, limit: Self.pageSize)
            guard g == gen, page.runId == target.runId else { return }
            let entries = await LogEntry.parse(page.lines)
            guard g == gen else { return }
            buffer.reset(entries, hasMoreBefore: page.hasMoreBefore)
            status.loading = false
            status.error = nil
            status.truncated = page.truncated
            status.ended = page.runEnded
            status.lastLineAt = Timestamps.date(entries.last?.line.ts)
            epoch &+= 1
            changed()
            if !page.runEnded { startStream(g) }
        } catch is CancellationError {
            return
        } catch {
            guard g == gen else { return }
            let api = error as? ApiError
            status.loading = false
            if api?.code == .runNotFound {
                status.error = "该运行的日志已按保留策略删除"
                return
            }
            status.error = "加载日志失败：\(api?.message ?? error.localizedDescription)"
            scheduleTailRetry(g)
        }
    }

    private func scheduleTailRetry(_ g: Int) {
        retryTask?.cancel()
        let sleep = env.sleep
        retryTask = Task {
            do { try await sleep(Self.tailRetry) } catch { return }
            guard g == self.gen, !Task.isCancelled else { return }
            self.retryTask = nil
            await self.loadTail(g)
        }
    }

    // MARK: Stream

    private enum Delivery: Sendable {
        case lines(RunID, [LogEntry])
        case event(LogStreamEvent)
    }

    private enum StreamEnd: Sendable {
        /// Closed without `end`, or failed: reconnect with backoff.
        case dropped
        /// `end` received.
        case ended
        /// `gap`: reconnect now from the last seq.
        case reopen
        /// A newer connection / target took over.
        case superseded
    }

    private enum Verdict: Sendable {
        case keepReading
        case stop(StreamEnd)
    }

    private func startStream(_ g: Int) {
        guard g == gen, let target, !status.ended, !buffer.detached else { return }
        streamTask?.cancel()
        streamTask = nil
        retryTask?.cancel()
        retryTask = nil
        streamGen &+= 1
        guard let client = clientProvider() else {
            status.streaming = false
            status.reconnecting = true
            scheduleStreamRetry(g)
            return
        }
        let sg = streamGen
        let after = buffer.lastSeq ?? 0
        let runId = target.runId
        status.streaming = true
        status.reconnecting = false
        streamsOpened += 1
        streamTask = Task.detached(priority: .userInitiated) { [weak self] in
            let stream = client.logStream(runId, afterSeq: after)
            var end = StreamEnd.dropped
            do {
                for try await event in stream {
                    let delivery: Delivery
                    if case .lines(let rid, let lines) = event {
                        delivery = .lines(rid, lines.map(LogEntry.init))  // parse off the main thread
                    } else {
                        delivery = .event(event)
                    }
                    guard let self else { return }
                    if case .stop(let reason) = await self.handle(delivery, g: g, sg: sg) {
                        end = reason
                        break
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                end = .dropped
            }
            if Task.isCancelled { return }
            await self?.streamFinished(end, g: g, sg: sg)
        }
    }

    private func handle(_ delivery: Delivery, g: Int, sg: Int) -> Verdict {
        guard g == gen, sg == streamGen, let target else { return .stop(.superseded) }
        switch delivery {
        case .lines(let runId, let entries):
            guard runId == target.runId else { return .keepReading }  // not ours: drop
            attempt = 0
            let added = buffer.append(entries)
            if added > 0 {
                unseen += added
                status.lastLineAt = Timestamps.date(entries.last?.line.ts) ?? status.lastLineAt
                changed()
            }
            return .keepReading
        case .event(let event):
            switch event {
            case .ping:
                attempt = 0
                return .keepReading
            case .truncated(let runId, _):
                guard runId == target.runId else { return .keepReading }
                status.truncated = true
                return .keepReading
            case .gap(let runId, _, let reason):
                guard runId == target.runId else { return .keepReading }
                status.gap = reason
                let now = env.now()
                if lastGapReopen.map({ now.timeIntervalSince($0) >= Self.gapReopenInterval }) ?? true {
                    lastGapReopen = now
                    return .stop(.reopen)
                }
                return .keepReading
            case .end(let runId, let run):
                guard runId == target.runId else { return .keepReading }
                status.ended = true
                status.endedRun = run
                status.streaming = false
                status.reconnecting = false
                return .stop(.ended)
            case .lines, .unknown:
                return .keepReading
            }
        }
    }

    private func streamFinished(_ end: StreamEnd, g: Int, sg: Int) {
        guard g == gen, sg == streamGen else { return }
        streamTask = nil
        status.streaming = false
        switch end {
        case .ended, .superseded:
            return
        case .reopen:
            startStream(g)
        case .dropped:
            status.reconnecting = true
            scheduleStreamRetry(g)
        }
    }

    private func scheduleStreamRetry(_ g: Int) {
        retryTask?.cancel()
        let delay = Self.backoff[min(attempt, Self.backoff.count - 1)]
        attempt += 1
        let sleep = env.sleep
        retryTask = Task {
            do { try await sleep(delay) } catch { return }
            guard g == self.gen, !Task.isCancelled else { return }
            self.retryTask = nil
            self.startStream(g)
        }
    }

    private func changed() {
        revision &+= 1
        onLinesChanged?()
    }
}
