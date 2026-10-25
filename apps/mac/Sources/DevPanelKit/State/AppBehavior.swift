import Foundation

public struct ServiceNotice: Equatable, Sendable {
    public var id: String
    public var ref: LogOwner
    public var title: String
    public var body: String
    public init(id: String, ref: ServiceRef, title: String, body: String) { self.id = id; self.ref = .service(ref); self.title = title; self.body = body }
    public init(id: String, ref: TaskRef, title: String, body: String) { self.id = id; self.ref = .task(ref); self.title = title; self.body = body }
}

/// Event-driven, not a timer. First snapshot establishes a baseline, reconnects detect changes.
public struct NotificationTracker: Sendable {
    private var initialized = false
    private var seen: Set<String> = []
    private var order: [String] = []
    public init() {}

    public mutating func consume(_ event: DaemonEvent) -> [ServiceNotice] {
        let projects: [ProjectView]
        switch event {
        case .snapshot(let s): projects = s.projects
        case .projectUpsert(let p): projects = [p]
        default: return []
        }
        let candidates = projects.flatMap { p in p.services.compactMap { Self.notice(project: p, service: $0) } }
        let fresh = candidates.filter { !seen.contains($0.id) }
        for item in fresh { seen.insert(item.id); order.append(item.id) }
        if order.count > 2000 {
            let old = order.prefix(order.count - 2000); seen.subtract(old); order.removeFirst(old.count)
        }
        if !initialized {
            if case .snapshot = event { initialized = true }
            return []
        }
        return fresh
    }

    public static func badge(_ projects: [ProjectView]) -> Int {
        projects.reduce(0) { $0 + $1.services.filter { $0.state == .failed || $0.state == .unknown }.count }
    }

    private static func notice(project: ProjectView, service: ServiceView) -> ServiceNotice? {
        let run = service.currentRun ?? service.lastRun
        let body: String
        if service.state == .unknown { body = "状态未知，运行归属无法核验" }
        else if run?.exit?.reason == .daemonLost { body = "管理服务中断，运行已丢失" }
        else if run?.exit?.reason == .selfExit && run?.state == .failed {
            body = "异常退出" + (run?.exit?.code.map { "（\($0)）" } ?? run?.exit?.signal.map { "（\($0)）" } ?? "")
        } else { return nil }
        return ServiceNotice(id: run?.id ?? "\(project.id)/\(service.id)/\(service.stateSince ?? "unknown")", ref: ServiceRef(project.id, service.id), title: "\(project.name) · \(service.name)", body: body)
    }
}

extension AppModel {
    public var abnormalServiceCount: Int { NotificationTracker.badge(projects) }

    /// Wait for a final outcome when an implementation returns a queued 202.
    public func stopAllAndShutdown() async throws {
        guard let client, isConnected else { throw ApiError.unreachable() }
        guard var op = try await shutdownDaemon(stopServices: true) else { return }
        while !op.isFinished {
            op = try await client.waitOperation(op.id)
        }
        guard op.state == .succeeded else {
            let reasons = op.results.compactMap { $0.error?.message }
            throw ApiError(code: .stopTimeout, message: reasons.isEmpty ? "停止未完成，管理服务保持运行" : reasons.joined(separator: "；") + "。管理服务保持运行")
        }
    }
}

/// Separate IDs keep timeout notices from suppressing later process failures.
public struct ReadyNotificationTracker: Sendable {
    private var initialized = false
    private var seen: Set<RunID> = []
    public init() {}
    public mutating func consume(_ event: DaemonEvent, foreground: Bool) -> [ServiceNotice] {
        let projects: [ProjectView]
        switch event { case .snapshot(let snapshot): projects = snapshot.projects; case .projectUpsert(let project): projects = [project]; default: return [] }
        var notices: [ServiceNotice] = []
        for project in projects { for service in project.services {
            guard let run = service.currentRun ?? service.lastRun, run.ready?.state == .timedOut, !seen.contains(run.id) else { continue }
            seen.insert(run.id)
            if initialized && !foreground { notices.append(ServiceNotice(id: "ready-" + run.id, ref: ServiceRef(project.id, service.id), title: "\(project.name) · \(service.name)", body: "\(Timestamps.date(run.ready?.at).flatMap { at in Timestamps.date(run.startedAt).map { Int(at.timeIntervalSince($0).rounded()) } }.map { "\($0) 秒内未就绪" } ?? "等待上限内未就绪")")) }
        } }
        if case .snapshot = event { initialized = true }
        return notices
    }
}
