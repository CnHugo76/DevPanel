import Foundation

// Mirrors packages/contract/src/index.ts — "Operations" and "Logs".

public enum ClientKind: OpenEnum {
    case ui, cli
    /// `Operation.source` may also be "daemon".
    case daemon
    case other(String)

    public static let known: [ClientKind] = [.ui, .cli, .daemon]
    public var rawValue: String {
        switch self {
        case .ui: "ui"
        case .cli: "cli"
        case .daemon: "daemon"
        case .other(let s): s
        }
    }
}

public enum ActionKind: OpenEnum {
    case start, stop, restart, forceStop
    case other(String)

    public static let known: [ActionKind] = [.start, .stop, .restart, .forceStop]
    public var rawValue: String {
        switch self {
        case .start: "start"
        case .stop: "stop"
        case .restart: "restart"
        case .forceStop: "force-stop"
        case .other(let s): s
        }
    }
}

public struct ActionRequest: Codable, Hashable, Sendable {
    public var projectId: ProjectID
    /// nil = every service of the project (config order).
    public var serviceIds: [ServiceID]?
    public var action: ActionKind
    public var overrideHold: Bool? = nil

    public init(projectId: ProjectID, serviceIds: [ServiceID]? = nil, action: ActionKind) {
        self.projectId = projectId
        self.serviceIds = serviceIds
        self.action = action
    }
}

public enum OperationState: OpenEnum {
    case queued, running, succeeded, partial, failed, cancelled
    case other(String)

    public static let known: [OperationState] = [
        .queued, .running, .succeeded, .partial, .failed, .cancelled,
    ]
    public var rawValue: String {
        switch self {
        case .queued: "queued"
        case .running: "running"
        case .succeeded: "succeeded"
        case .partial: "partial"
        case .failed: "failed"
        case .cancelled: "cancelled"
        case .other(let s): s
        }
    }

    /// succeeded / partial / failed / cancelled (unknown future states count as finished
    /// only if `finishedAt` is set; see `Operation.isFinished`).
    public var isTerminal: Bool {
        switch self {
        case .succeeded, .partial, .failed, .cancelled: true
        default: false
        }
    }
}

public enum TargetOutcome: OpenEnum {
    case pending, started, alreadyRunning, stopped, alreadyStopped, stopTimeout, failed, cancelled
    case other(String)

    public static let known: [TargetOutcome] = [
        .pending, .started, .alreadyRunning, .stopped, .alreadyStopped, .stopTimeout, .failed,
        .cancelled,
    ]
    public var rawValue: String {
        switch self {
        case .pending: "pending"
        case .started: "started"
        case .alreadyRunning: "already-running"
        case .stopped: "stopped"
        case .alreadyStopped: "already-stopped"
        case .stopTimeout: "stop-timeout"
        case .failed: "failed"
        case .cancelled: "cancelled"
        case .other(let s): s
        }
    }
}

public struct OperationTargetResult: Codable, Hashable, Sendable {
    public var serviceId: ServiceID
    public var outcome: TargetOutcome
    public var runId: RunID?
    /// stop-timeout: STOP_TIMEOUT with details { timeoutSec, remaining }.
    public var error: ApiError?

    public init(serviceId: ServiceID, outcome: TargetOutcome, runId: RunID? = nil, error: ApiError? = nil) {
        self.serviceId = serviceId
        self.outcome = outcome
        self.runId = runId
        self.error = error
    }
}

public struct Operation: Codable, Hashable, Sendable, Identifiable {
    public var id: OperationID
    public var projectId: ProjectID
    public var action: ActionKind
    public var serviceIds: [ServiceID]
    public var actor: Actor? = nil
    public var source: ClientKind
    public var state: OperationState
    public var createdAt: Timestamp
    public var finishedAt: Timestamp?
    public var results: [OperationTargetResult]
    public var cancelledBy: OperationID?

    public init(
        id: OperationID, projectId: ProjectID, action: ActionKind, serviceIds: [ServiceID],
        source: ClientKind, state: OperationState, createdAt: Timestamp, finishedAt: Timestamp? = nil,
        results: [OperationTargetResult] = [], cancelledBy: OperationID? = nil
    ) {
        self.id = id
        self.projectId = projectId
        self.action = action
        self.serviceIds = serviceIds
        self.source = source
        self.state = state
        self.createdAt = createdAt
        self.finishedAt = finishedAt
        self.results = results
        self.cancelledBy = cancelledBy
    }

    public var isFinished: Bool { state.isTerminal || finishedAt != nil }
}

// MARK: - Logs

public enum LogStream: OpenEnum {
    case out, err, sys
    case other(String)

    public static let known: [LogStream] = [.out, .err, .sys]
    public var rawValue: String {
        switch self {
        case .out: "out"
        case .err: "err"
        case .sys: "sys"
        case .other(let s): s
        }
    }
}

public struct LogLine: Codable, Hashable, Sendable {
    /// Per-run, starts at 1, strictly increasing.
    public var seq: Int
    public var ts: Timestamp
    public var stream: LogStream
    /// Raw text without trailing newline; may contain ANSI escapes.
    public var text: String
    /// Split because it exceeded logLineMaxBytes; the next seq continues it.
    public var partial: Bool?

    public init(seq: Int, ts: Timestamp, stream: LogStream, text: String, partial: Bool? = nil) {
        self.seq = seq
        self.ts = ts
        self.stream = stream
        self.text = text
        self.partial = partial
    }
}

public struct LogPage: Codable, Hashable, Sendable {
    public var runId: RunID
    public var lines: [LogLine]
    public var firstSeq: Int?
    public var lastSeq: Int?
    public var truncated: Bool
    public var hasMoreBefore: Bool
    public var hasMoreAfter: Bool
    public var runEnded: Bool
}
