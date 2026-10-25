import Foundation
import Observation

public enum ConnectionStatus: String, Sendable, Equatable {
    /// First attempt in progress, nothing known yet.
    case connecting
    /// Event stream open and a snapshot applied.
    case connected
    /// The daemon was (or should be) there but the stream failed / went silent; retrying.
    case disconnected
    /// No `daemon.json` (or nothing listening on its port): "管理服务未运行".
    case notRunning
    /// The daemon rejected our token (401); retrying with a freshly read discovery file.
    case unauthorized
}

public struct ConnectionState: Equatable, Sendable {
    public var status: ConnectionStatus = .connecting
    /// When the next connection attempt happens; nil while connected or attempting.
    public var retryAt: Date?
    /// Arrival time of the last event of any kind, including `ping` (drives the 25 s watchdog).
    public var lastEventAt: Date?
    /// Last moment the local state was known to match the daemon. While disconnected this is
    /// the "下面是 hh:mm:ss 的状态" time; nil if never connected.
    public var syncedAt: Date?
    /// Why the last attempt failed (nil while connected).
    public var lastError: ApiError?
    /// Consecutive failed attempts since the last successful snapshot.
    public var failures: Int = 0
    /// notRunning because `daemon.json` exists but nothing accepts connections on its port
    /// (the daemon most likely crashed without cleaning up).
    public var staleDiscovery: Bool = false

    public init() {}
}

/// Result of the "启动管理服务" button.
public enum DaemonLaunchState: Equatable, Sendable {
    case idle
    case launching
    case failed(String)
}

/// The single source of truth for the UI, driven by `GET /events`.
///
/// Views read the published properties and call the action methods; they never talk to the
/// network directly. All I/O goes through `Environment`, so tests inject a fake transport,
/// a recording `sleep` and a controllable `now`.
@Observable
@MainActor
public final class AppModel {
    public var activityEntries: [ProjectID: [ActivityEntry]] = [:]
    public var activityHasMore: [ProjectID: Bool] = [:]
    public var activityVisible: ProjectID? {
        didSet {
            if oldValue != activityVisible, let oldValue {
                activityGeneration[oldValue, default: 0] += 1
                activityLoads[oldValue] = nil
                activityLoading.remove(oldValue)
            }
            if oldValue != activityVisible { activityError = nil }
        }
    }
    public internal(set) var activityTaskFilters: [ProjectID: String] = [:]
    public internal(set) var activityLoading: Set<ProjectID> = []
    public var activityError: String?
    @ObservationIgnored var activityRefreshes: [ProjectID: Task<Void, Never>] = [:]
    @ObservationIgnored var activityLoads: [ProjectID: UUID] = [:]
    @ObservationIgnored var activityGeneration: [ProjectID: Int] = [:]
    @ObservationIgnored var activityPending: Set<ProjectID> = []

    public struct Timing: Sendable {
        /// Reconnect delays after consecutive failures; the last one repeats.
        public var backoff: [Duration] = [.seconds(1), .seconds(2), .seconds(5), .seconds(10)]
        /// No event at all (pings come every 10 s) for this long → disconnected.
        public var staleAfter: Duration = .seconds(25)
        public var watchdogInterval: Duration = .seconds(1)
        /// How often to look for `daemon.json` while the daemon is not running.
        public var notRunningPoll: Duration = .seconds(2)

        public init() {}

        func backoffDelay(failures: Int) -> Duration {
            guard !backoff.isEmpty else { return .seconds(1) }
            return backoff[min(max(failures - 1, 0), backoff.count - 1)]
        }
    }

    public struct Environment: Sendable {
        /// Reads `<home>/daemon.json`; nil = not running.
        public var discover: @Sendable () throws -> DaemonDiscovery?
        public var makeClient: @Sendable (DaemonDiscovery) -> DaemonClient
        /// Waits before a reconnect attempt (cancelled by `retryNow()`).
        public var sleep: @Sendable (Duration) async throws -> Void
        public var now: @Sendable () -> Date
        /// Runs `devpanel daemon start`.
        public var launchDaemon: @Sendable () async throws -> String
        /// Enabled for the real app; injected test environments opt in explicitly.
        public var monitorToolResources: Bool

        public init(
            discover: @escaping @Sendable () throws -> DaemonDiscovery?,
            makeClient: @escaping @Sendable (DaemonDiscovery) -> DaemonClient,
            sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
            now: @escaping @Sendable () -> Date = { Date() },
            launchDaemon: @escaping @Sendable () async throws -> String = {
                try await DaemonLauncher().start()
            },
            monitorToolResources: Bool = false
        ) {
            self.discover = discover
            self.makeClient = makeClient
            self.sleep = sleep
            self.now = now
            self.launchDaemon = launchDaemon
            self.monitorToolResources = monitorToolResources
        }

        /// Real discovery file + URLSession.
        public static func live(home: DaemonHome = .resolve()) -> Environment {
            let reader = DiscoveryReader(home: home)
            let transport = URLSessionTransport()
            return Environment(
                discover: { try reader.read() },
                makeClient: { DaemonClient(discovery: $0, transport: transport) }, monitorToolResources: true)
        }
    }

    // MARK: Published state

    public private(set) var connection = ConnectionState() {
        didSet {
            if connectionStatus != connection.status { connectionStatus = connection.status }
            if isStale != connection.isStale { isStale = connection.isStale }
            if oldValue.status != connection.status { toolResources.connectionChanged(model: self) }
        }
    }
    public private(set) var connectionStatus: ConnectionStatus = .connecting
    public private(set) var isStale = false
    public private(set) var daemon: DaemonInfo?
    public let toolResources = ToolResourceMonitor()
    public private(set) var connectionGeneration = 0
    /// Registration order (as the daemon sends it); upserts of new projects append.
    public private(set) var projects: [ProjectView] = [] { didSet { refreshParamPresentation() } }
    public private(set) var stats: StatsSnapshot? { didSet { updateStatsStores() } }
    public private(set) var operations: [OperationID: Operation] = [:]
    public private(set) var daemonLaunch: DaemonLaunchState = .idle
    /// `GET /projects/:id` per project (secrets masked): params, commands. Fetched automatically
    /// whenever a project's `revision` is newer than the cached one (F2).
    public private(set) var configs: [ProjectID: Project] = [:] { didSet { refreshParamPresentation() } }
    /// The service shown in the inspector (F2). Cleared when it disappears.
    public private(set) var inspectorSelection: InspectorSelection?
    public var selection: ServiceRef? {
        guard case .service(let ref) = inspectorSelection else { return nil }
        return ref
    }
    public let projectInspector: ProjectInspectorState
    public let maven: MavenState
    public let git = GitState()
    /// Result bar per project: the last action started from this window (F2).
    public private(set) var actionResults: [ProjectID: ActionResult] = [:]
    /// Arrival time of the last `stats` event (not the snapshot's embedded stats).
    public private(set) var lastStatsAt: Date?
    /// Client of the current connection (nil unless connected). For F2–F6 calls that have no
    /// dedicated method yet; prefer adding methods here so views stay network-free.
    public private(set) var client: DaemonClient?
    /// Inspector tab, chosen run, run history and the log session (F3, `AppModel+Inspector.swift`).
    public let inspector = InspectorState()

    @ObservationIgnored public var eventObserver: ((DaemonEvent) -> Void)?

    public let timing: Timing
    @ObservationIgnored private let env: Environment
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var waiter: Task<Void, Never>?
    @ObservationIgnored private var configLoads: Set<ProjectID> = []
    /// Revision whose config fetch failed; not retried until the revision changes.
    @ObservationIgnored private var configFailures: [ProjectID: Int] = [:]
    /// Action keys with a request in flight or an unfinished operation (double-click guard).
    private var inflight: [ActionKey: OperationID?] = [:]

    /// Finished operations kept between snapshots (the daemon keeps them ≥ 10 min).
    public static let maxFinishedOperations = 200

    public init(environment: Environment, timing: Timing = Timing(), preferences: UserDefaults? = nil) {
        self.env = environment
        self.projectInspector = ProjectInspectorState(defaults: preferences)
        self.maven = MavenState(defaults: preferences)
        self.timing = timing
        inspector.detailsChanged = { [weak self] in self?.refreshParamPresentation() }
    }

    @ObservationIgnored private var rawStats: StatsSnapshot?
    @ObservationIgnored private var serviceStores: [ServiceRef: ServiceStatsStore] = [:]
    @ObservationIgnored private var projectStores: [ProjectID: ProjectStatsStore] = [:]
    @ObservationIgnored private var paramStores: [ProjectID: ParamPresentationStore] = [:]

    private func updateStatsStores() {
        rawStats = stats
        for (ref, store) in serviceStores { store.update(stats?.projects[ref.projectId]?.services[ref.serviceId]) }
        for (id, store) in projectStores { store.update(stats?.projects[id]) }
    }

    func refreshParamPresentation() {
        for project in projects {
            let store = paramStores[project.id] ?? ParamPresentationStore()
            paramStores[project.id] = store
            store.update(project: project, params: configs[project.id]?.config.params ?? [], details: inspector.runDetails)
        }
        let ids = Set(projects.map(\.id))
        let refs = Set(projects.flatMap { project in project.services.map { ServiceRef(project.id, $0.id) } })
        paramStores = paramStores.filter { ids.contains($0.key) }
        projectStores = projectStores.filter { ids.contains($0.key) }
        serviceStores = serviceStores.filter { refs.contains($0.key) }
    }

    public func hasPendingParams(_ project: ProjectID, _ service: ServiceID) -> Bool {
        paramStores[project]?.pendingServices.contains(service) ?? false
    }
    public func paramGroups(_ project: ProjectID) -> [ParamChipGroup] { paramStores[project]?.groups ?? [] }

    // MARK: Derived

    public var isConnected: Bool { connectionStatus == .connected }
    public var serviceCount: Int { projects.reduce(0) { $0 + $1.serviceCount } }
    public var runningServiceCount: Int { projects.reduce(0) { $0 + $1.runningCount } }

    public func project(_ id: ProjectID) -> ProjectView? { projects.first { $0.id == id } }
    public func projectStats(_ id: ProjectID) -> ProjectStats? {
        if let store = projectStores[id] { return store.value }
        let store = ProjectStatsStore()
        // Initial reads must not register a dependency on the whole snapshot.
        store.update(rawStats?.projects[id])
        projectStores[id] = store
        return store.value
    }
    public func serviceStats(_ projectId: ProjectID, _ serviceId: ServiceID) -> ServiceStats? {
        let ref = ServiceRef(projectId, serviceId)
        if let store = serviceStores[ref] { return store.value }
        let store = ServiceStatsStore()
        store.update(rawStats?.projects[projectId]?.services[serviceId])
        serviceStores[ref] = store
        return store.value
    }

    // MARK: Lifecycle

    /// Starts the connect / reconnect loop (idempotent).
    public func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in await self?.runLoop() }
        if env.monitorToolResources { toolResources.start(model: self) }
    }

    /// Stops the loop and closes the event stream. State is kept.
    public func stop() {
        connectionGeneration += 1
        toolResources.stop()
        loopTask?.cancel()
        loopTask = nil
        waiter?.cancel()
        waiter = nil
        client = nil
    }

    /// Skips the remaining reconnect wait.
    public func retryNow() {
        waiter?.cancel()
    }

    // MARK: Events

    /// Applies one event to the local state. `snapshot` replaces everything.
    public func apply(_ event: DaemonEvent) {
        defer { eventObserver?(event) }
        switch event {
        case .snapshot(let s):
            daemon = s.daemon
            projects = s.projects
            stats = s.stats
            var ops = Dictionary(s.operations.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
            // Keep operations behind a visible result bar even if the daemon no longer lists them.
            for r in actionResults.values {
                if let id = r.operationId, ops[id] == nil, let op = operations[id] { ops[id] = op }
            }
            operations = ops
            let ids = Set(projects.map(\.id))
            configs = configs.filter { ids.contains($0.key) }
            actionResults = actionResults.filter { ids.contains($0.key) }
            pruneSelection()
        case .projectUpsert(let p):
            scheduleActivityRefresh(p.id)
            if let i = projects.firstIndex(where: { $0.id == p.id }) {
                projects[i] = p
            } else {
                projects.append(p)
            }
            pruneSelection()
        case .projectRemove(let id):
            projects.removeAll { $0.id == id }
            stats?.projects[id] = nil
            configs[id] = nil
            actionResults[id] = nil
            pruneSelection()
        case .operation(let op):
            scheduleActivityRefresh(op.projectId)
            upsertOperation(op)
        case .stats(let s):
            stats = s
            lastStatsAt = env.now()
        case .ping, .unknown:
            break
        }
    }

    private func upsertOperation(_ op: Operation) {
        // An HTTP response can arrive after a newer event; never move a finished op backwards.
        if let existing = operations[op.id], existing.isFinished, !op.isFinished { return }
        operations[op.id] = op
        if op.isFinished {
            for (key, id) in inflight where id == op.id { inflight[key] = nil }
        }
        let finished = operations.values.filter(\.isFinished)
        if finished.count > Self.maxFinishedOperations {
            let drop = finished.sorted { ($0.finishedAt ?? "") < ($1.finishedAt ?? "") }
                .prefix(finished.count - Self.maxFinishedOperations)
            for o in drop { operations[o.id] = nil }
        }
    }

    // MARK: Actions

    /// POST /operations. The returned operation is also tracked in `operations`.
    @discardableResult
    public func perform(_ request: ActionRequest) async throws -> Operation {
        let op = try await requireClient().createOperation(request)
        upsertOperation(op)
        return op
    }

    /// POST /daemon/shutdown. Stops every service first when `stopServices` is true.
    @discardableResult
    public func shutdownDaemon(stopServices: Bool) async throws -> Operation? {
        let op = try await requireClient().shutdown(stopServices: stopServices)
        if let op { upsertOperation(op) }
        return op
    }

    /// Runs `devpanel daemon start`, then reconnects immediately. Never starts a project.
    public func startDaemon() async {
        guard daemonLaunch != .launching else { return }
        daemonLaunch = .launching
        do {
            _ = try await env.launchDaemon()
            daemonLaunch = .idle
            retryNow()
        } catch {
            daemonLaunch = .failed(error.localizedDescription)
        }
    }

    /// Starts an action from the UI and tracks it for the project's result bar. Never throws:
    /// a rejected request becomes an `ActionResult` with `error`. A second call for the same
    /// target and action while the first is unfinished is ignored (the daemon still guarantees
    /// correctness). The operation is followed by long-polling as a backup to the event stream.
    public func runAction(_ request: ActionRequest) async {
        let key = ActionKey(request)
        guard !isPending(request) else { return }
        inflight[key] = .some(nil)
        let startedAt = env.now()
        do {
            let op = try await perform(request)
            if op.isFinished {
                inflight[key] = nil
            } else {
                inflight[key] = op.id
            }
            actionResults[request.projectId] = ActionResult(
                operationId: op.id, error: nil, action: request.action, at: startedAt)
            if !op.isFinished { follow(op.id, key: key) }
        } catch {
            inflight[key] = nil
            let apiError = error as? ApiError ?? ApiError(code: .internal, message: error.localizedDescription)
            actionResults[request.projectId] = ActionResult(
                operationId: nil, error: apiError, action: request.action, at: startedAt)
        }
    }

    /// True while the same action on the same targets is in flight or unfinished.
    public func isPending(_ request: ActionRequest) -> Bool {
        let key = ActionKey(request)
        guard let entry = inflight[key] else { return false }
        guard let id = entry else { return true }
        return !(operations[id]?.isFinished ?? false)
    }

    /// True while any action on the project (or on `serviceId`) is in flight.
    public func hasPendingAction(projectId: ProjectID, serviceId: ServiceID? = nil) -> Bool {
        inflight.contains { key, id in
            guard key.projectId == projectId else { return false }
            if let serviceId, let ids = key.serviceIds, !ids.contains(serviceId) { return false }
            guard let id else { return true }
            return !(operations[id]?.isFinished ?? false)
        }
    }

    /// Closes a project's result bar.
    public func dismissResult(_ projectId: ProjectID) {
        actionResults[projectId] = nil
    }

    /// The operation behind a result bar, once it finished (nil while running).
    public func finishedOperation(for projectId: ProjectID) -> Operation? {
        guard let id = actionResults[projectId]?.operationId, let op = operations[id], op.isFinished else { return nil }
        return op
    }

    private func follow(_ id: OperationID, key: ActionKey) {
        Task { [weak self] in
            for _ in 0..<20 {
                guard let self else { return }
                if self.operations[id]?.isFinished == true { return }
                guard let client = self.client else {
                    try? await self.env.sleep(.seconds(2))
                    continue
                }
                do {
                    let op = try await client.waitOperation(id, timeoutMs: 30_000)
                    self.upsertOperation(op)
                    if op.isFinished { return }
                } catch is CancellationError {
                    return
                } catch {
                    try? await self.env.sleep(.seconds(2))
                }
            }
        }
    }

    // MARK: Selection

    public func select(_ ref: ServiceRef?) {
        guard let ref else {
            inspectorSelection = nil
            syncLogSession()
            return
        }
        guard project(ref.projectId)?.service(ref.serviceId) != nil else { return }
        inspectorSelection = .service(ref)
        prepareServiceTools(ref)
        syncLogSession()
    }

    public func selectProject(_ id: ProjectID, tab: ProjectInspectorTab? = nil) {
        guard let project = project(id) else { return }
        if let tab, let ref = serviceForTool(id, tab: tab) {
            selectServiceTab(tab == .git ? .git : .maven, for: ref)
            return
        }
        inspectorSelection = .project(id)
        let fallback: ProjectInspectorTab = project.actions.isEmpty ? .activity : .actions
        if let tab { projectInspector.tabs[id] = tab }
        else if projectInspector.tabs[id] == nil || ([.git, .maven].contains(projectInspector.tabs[id]) || (projectInspector.tabs[id] == .actions && project.actions.isEmpty)) {
            projectInspector.tabs[id] = fallback
        }
        if projectInspector.tabs[id] == .maven, project.maven == nil { projectInspector.tabs[id] = fallback }
        syncLogSession()
    }

    private func pruneSelection() {
        if case .project(let id) = inspectorSelection, project(id) == nil { inspectorSelection = nil }

        if let s = selection, project(s.projectId)?.service(s.serviceId) == nil { inspectorSelection = nil }
    }

    // MARK: Config cache

    /// Params of a project in display order (empty until its config is loaded).
    public func params(_ projectId: ProjectID) -> [ParamConfig] {
        configs[projectId]?.config.params ?? []
    }

    public func serviceConfig(_ projectId: ProjectID, _ serviceId: ServiceID) -> ServiceConfig? {
        configs[projectId]?.config.services.first { $0.id == serviceId }
    }

    /// Whether every project's config is cached at its current revision.
    public var configsLoaded: Bool {
        projects.allSatisfy { (configs[$0.id]?.revision ?? -1) >= $0.revision || configFailures[$0.id] == $0.revision }
    }

    /// Stores a config returned by a mutating call (F4/F5), if it is not older than the cache.
    public func storeConfig(_ project: Project) {
        if let cached = configs[project.id], cached.revision > project.revision { return }
        configs[project.id] = project
    }

    private func refreshConfigs(using client: DaemonClient) {
        for p in projects {
            let cached = configs[p.id]?.revision ?? -1
            guard cached < p.revision, !configLoads.contains(p.id), configFailures[p.id] != p.revision else { continue }
            configLoads.insert(p.id)
            let id = p.id
            let revision = p.revision
            Task { [weak self] in
                let project = try? await client.project(id)
                guard let self else { return }
                self.configLoads.remove(id)
                if let project, project.id == id {
                    self.configFailures[id] = nil
                    if self.project(id) != nil { self.storeConfig(project) }
                } else {
                    self.configFailures[id] = revision
                }
            }
        }
    }

    // MARK: Force stop

    /// Verified processes a force stop would signal: `STOP_TIMEOUT.details.remaining` of the
    /// service's current error, else the process count of its current-run stats; nil if unknown.
    public func forceStopProcessCount(_ projectId: ProjectID, serviceIds: [ServiceID]?) -> Int? {
        guard let p = project(projectId) else { return nil }
        let targets = p.services.filter { (serviceIds?.contains($0.id) ?? true) && $0.currentRun != nil }
        guard !targets.isEmpty else { return nil }
        var total = 0
        for s in targets {
            if let n = s.error?.remainingProcesses {
                total += n
            } else if let n = Metrics.currentSample(s, serviceStats(projectId, s.id))?.processCount {
                total += n
            } else {
                return nil
            }
        }
        return total
    }

    private func requireClient() throws -> DaemonClient {
        guard let client, connection.status == .connected else {
            throw ApiError.unreachable("管理服务未连接")
        }
        return client
    }

    // MARK: Connection loop

    private enum AttemptOutcome {
        case cancelled
        case notRunning(stale: Bool)
        case unauthorized(ApiError)
        case failed(ApiError)
    }

    private func runLoop() async {
        while !Task.isCancelled {
            let outcome = await attempt()
            client = nil
            let delay: Duration
            switch outcome {
            case .cancelled:
                return
            case .notRunning(let stale):
                connection.failures = 0
                connection.status = .notRunning
                connection.staleDiscovery = stale
                connection.lastError = nil
                delay = timing.notRunningPoll
            case .unauthorized(let error):
                connection.failures += 1
                connection.status = .unauthorized
                connection.staleDiscovery = false
                connection.lastError = error
                delay = timing.backoffDelay(failures: connection.failures)
            case .failed(let error):
                connection.failures += 1
                connection.status = .disconnected
                connection.staleDiscovery = false
                connection.lastError = error
                delay = timing.backoffDelay(failures: connection.failures)
            }
            connection.retryAt = env.now().addingTimeInterval(delay.timeInterval)
            let sleep = env.sleep
            let waiter = Task<Void, Never> { _ = try? await sleep(delay) }
            self.waiter = waiter
            await withTaskCancellationHandler {
                await waiter.value
            } onCancel: {
                waiter.cancel()
            }
            self.waiter = nil
            connection.retryAt = nil
        }
    }

    private func attempt() async -> AttemptOutcome {
        connectionGeneration += 1
        let discovery: DaemonDiscovery?
        do {
            discovery = try env.discover()
        } catch {
            return .failed(ApiError(code: .internal, message: error.localizedDescription))
        }
        guard let discovery else { return .notRunning(stale: false) }

        let client = env.makeClient(discovery)
        let stream = client.events()
        let startedAt = env.now()
        var staleFired = false

        let consumer = Task { @MainActor [weak self] in
            for try await event in stream {
                guard let self else { return }
                self.receive(event, from: client)
            }
        }
        let watchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: self?.timing.watchdogInterval ?? .seconds(1)) } catch { return }
                guard let self else { return }
                let last = self.connection.lastEventAt.map { max($0, startedAt) } ?? startedAt
                if self.env.now().timeIntervalSince(last) > self.timing.staleAfter.timeInterval {
                    staleFired = true
                    consumer.cancel()
                    return
                }
            }
        }
        let result = await withTaskCancellationHandler {
            await consumer.result
        } onCancel: {
            consumer.cancel()
        }
        watchdog.cancel()

        if Task.isCancelled { return .cancelled }
        if staleFired {
            let secs = Int(timing.staleAfter.timeInterval.rounded())
            return .failed(ApiError.unreachable("超过 \(secs) 秒没有收到管理服务的事件"))
        }
        switch result {
        case .success:
            return .failed(ApiError.unreachable("管理服务关闭了事件流"))
        case .failure(let error as ApiError):
            if error.code == .unauthorized { return .unauthorized(error) }
            if error.isConnectionRefused { return .notRunning(stale: true) }
            return .failed(error)
        case .failure(let error):
            return .failed(ApiError.unreachable(error.localizedDescription))
        }
    }

    private func receive(_ event: DaemonEvent, from client: DaemonClient) {
        let now = env.now()
        connection.lastEventAt = now
        if case .snapshot = event {
            self.client = client
            connection.status = .connected
            connection.failures = 0
            connection.lastError = nil
            connection.staleDiscovery = false
            connection.retryAt = nil
        }
        apply(event)
        if connection.status == .connected {
            connection.syncedAt = now
            switch event {
            case .snapshot:
                configFailures = [:]
                refreshConfigs(using: client)
            case .projectUpsert: refreshConfigs(using: client)
            default: break
            }
        }
    }
}

/// A service in a project.
public struct ServiceRef: Hashable, Sendable {
    public var projectId: ProjectID
    public var serviceId: ServiceID

    public init(_ projectId: ProjectID, _ serviceId: ServiceID) {
        self.projectId = projectId
        self.serviceId = serviceId
    }
}

/// What the result bar of a project shows.
public struct ActionResult: Equatable, Sendable {
    /// nil when the request itself was rejected.
    public var operationId: OperationID?
    public var error: ApiError?
    public var action: ActionKind
    public var at: Date
}

struct ActionKey: Hashable, Sendable {
    var projectId: ProjectID
    var serviceIds: [ServiceID]?
    var action: ActionKind

    init(_ r: ActionRequest) {
        projectId = r.projectId
        serviceIds = r.serviceIds
        action = r.action
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let (s, atto) = components
        return TimeInterval(s) + TimeInterval(atto) / 1e18
    }
}
