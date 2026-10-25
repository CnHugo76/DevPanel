import Foundation

// Mirrors packages/contract/src/index.ts — "Event streams (SSE)".
// Both enums dispatch on the JSON `type` field. Unknown types decode to `.unknown(type:)`
// so a newer daemon cannot break the stream; malformed known types still throw.

public struct SnapshotEvent: Codable, Hashable, Sendable {
    public var daemon: DaemonInfo
    public var projects: [ProjectView]
    public var operations: [Operation]
    public var stats: StatsSnapshot?

    public init(daemon: DaemonInfo, projects: [ProjectView], operations: [Operation], stats: StatsSnapshot?) {
        self.daemon = daemon
        self.projects = projects
        self.operations = operations
        self.stats = stats
    }
}

/// GET /api/v1/events
public enum DaemonEvent: Codable, Hashable, Sendable {
    case snapshot(SnapshotEvent)
    case projectUpsert(ProjectView)
    case projectRemove(projectId: ProjectID)
    case operation(Operation)
    case stats(StatsSnapshot)
    case ping(at: Timestamp)
    case unknown(type: String)

    private enum CodingKeys: String, CodingKey { case type, project, projectId, operation, stats, at }

    public var type: String {
        switch self {
        case .snapshot: "snapshot"
        case .projectUpsert: "project.upsert"
        case .projectRemove: "project.remove"
        case .operation: "operation"
        case .stats: "stats"
        case .ping: "ping"
        case .unknown(let t): t
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "snapshot": self = .snapshot(try SnapshotEvent(from: decoder))
        case "project.upsert": self = .projectUpsert(try c.decode(ProjectView.self, forKey: .project))
        case "project.remove": self = .projectRemove(projectId: try c.decode(String.self, forKey: .projectId))
        case "operation": self = .operation(try c.decode(Operation.self, forKey: .operation))
        case "stats": self = .stats(try c.decode(StatsSnapshot.self, forKey: .stats))
        case "ping": self = .ping(at: try c.decode(Timestamp.self, forKey: .at))
        default: self = .unknown(type: type)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        switch self {
        case .snapshot(let s): try s.encode(to: encoder)
        case .projectUpsert(let p): try c.encode(p, forKey: .project)
        case .projectRemove(let id): try c.encode(id, forKey: .projectId)
        case .operation(let o): try c.encode(o, forKey: .operation)
        case .stats(let s): try c.encode(s, forKey: .stats)
        case .ping(let at): try c.encode(at, forKey: .at)
        case .unknown: break
        }
    }
}

/// GET /api/v1/runs/:runId/logs/stream?afterSeq=N
public enum LogRun: Codable, Hashable, Sendable {
    case service(RunSummary)
    case task(TaskRunSummary)
    public var id: RunID { switch self { case .service(let r): r.id; case .task(let r): r.id } }
    public var startedAt: Timestamp { switch self { case .service(let r): r.startedAt; case .task(let r): r.startedAt } }
    public var stateText: String { switch self { case .service(let r): r.stateText; case .task(let r): r.state.title } }
    public func rangeText(now: Date, calendar: Calendar = .current) -> String {
        guard let start = Timestamps.date(startedAt) else { return "—" }
        return Format.range(start: start, end: Timestamps.date(endedAt), now: now, calendar: calendar)
    }
    public var endedAt: Timestamp? { switch self { case .service(let r): r.endedAt; case .task(let r): r.endedAt } }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        if c.contains(.kind) { self = .task(try TaskRunSummary(from: decoder)) }
        else { self = .service(try RunSummary(from: decoder)) }
    }
    private enum Keys: String, CodingKey { case kind }
    public func encode(to encoder: any Encoder) throws {
        switch self { case .service(let r): try r.encode(to: encoder); case .task(let r): try r.encode(to: encoder) }
    }
}

public enum LogStreamEvent: Codable, Hashable, Sendable {
    case lines(runId: RunID, lines: [LogLine])
    case truncated(runId: RunID, firstSeq: Int)
    case gap(runId: RunID, afterSeq: Int, reason: String)
    case end(runId: RunID, run: LogRun)
    case ping(at: Timestamp)
    case unknown(type: String)

    private enum CodingKeys: String, CodingKey { case type, runId, lines, firstSeq, afterSeq, reason, run, at }

    public var type: String {
        switch self {
        case .lines: "lines"
        case .truncated: "truncated"
        case .gap: "gap"
        case .end: "end"
        case .ping: "ping"
        case .unknown(let t): t
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "lines":
            self = .lines(runId: try c.decode(String.self, forKey: .runId), lines: try c.decode([LogLine].self, forKey: .lines))
        case "truncated":
            self = .truncated(runId: try c.decode(String.self, forKey: .runId), firstSeq: try c.decode(Int.self, forKey: .firstSeq))
        case "gap":
            self = .gap(
                runId: try c.decode(String.self, forKey: .runId),
                afterSeq: try c.decode(Int.self, forKey: .afterSeq),
                reason: try c.decode(String.self, forKey: .reason))
        case "end":
            self = .end(runId: try c.decode(String.self, forKey: .runId), run: try c.decode(LogRun.self, forKey: .run))
        case "ping":
            self = .ping(at: try c.decode(Timestamp.self, forKey: .at))
        default:
            self = .unknown(type: type)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        switch self {
        case .lines(let runId, let lines):
            try c.encode(runId, forKey: .runId)
            try c.encode(lines, forKey: .lines)
        case .truncated(let runId, let firstSeq):
            try c.encode(runId, forKey: .runId)
            try c.encode(firstSeq, forKey: .firstSeq)
        case .gap(let runId, let afterSeq, let reason):
            try c.encode(runId, forKey: .runId)
            try c.encode(afterSeq, forKey: .afterSeq)
            try c.encode(reason, forKey: .reason)
        case .end(let runId, let run):
            try c.encode(runId, forKey: .runId)
            try c.encode(run, forKey: .run)
        case .ping(let at):
            try c.encode(at, forKey: .at)
        case .unknown:
            break
        }
    }
}
