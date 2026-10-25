import Foundation

// Mirrors packages/contract/src/index.ts — "Runtime state".

public enum ServiceState: OpenEnum {
    case idle, starting, running, stopping, stopped, exited, failed, unknown
    case other(String)

    public static let known: [ServiceState] = [
        .idle, .starting, .running, .stopping, .stopped, .exited, .failed, .unknown,
    ]
    public var rawValue: String {
        switch self {
        case .idle: "idle"
        case .starting: "starting"
        case .running: "running"
        case .stopping: "stopping"
        case .stopped: "stopped"
        case .exited: "exited"
        case .failed: "failed"
        case .unknown: "unknown"
        case .other(let s): s
        }
    }

    /// starting / running / stopping: a current run exists.
    public var isActive: Bool { self == .starting || self == .running || self == .stopping }
}

public enum ExitReason: OpenEnum {
    case userStop, forceStop, selfExit, spawnFailed, startCancelled, daemonLost
    case other(String)

    public static let known: [ExitReason] = [
        .userStop, .forceStop, .selfExit, .spawnFailed, .startCancelled, .daemonLost,
    ]
    public var rawValue: String {
        switch self {
        case .userStop: "user-stop"
        case .forceStop: "force-stop"
        case .selfExit: "self-exit"
        case .spawnFailed: "spawn-failed"
        case .startCancelled: "start-cancelled"
        case .daemonLost: "daemon-lost"
        case .other(let s): s
        }
    }
}

public struct ExitInfo: Codable, Hashable, Sendable {
    public var requestedBy: Actor? = nil
    public var reason: ExitReason
    public var code: Int?
    public var signal: String?
    public var at: Timestamp

    public init(reason: ExitReason, code: Int?, signal: String?, at: Timestamp) {
        self.reason = reason
        self.code = code
        self.signal = signal
        self.at = at
    }
}

public struct RunSummary: Codable, Hashable, Sendable, Identifiable {
    public var id: RunID
    public var projectId: ProjectID
    public var serviceId: ServiceID
    public var configRevision: Int
    public var startedBy: Actor? = nil
    public var startedAt: Timestamp
    public var endedAt: Timestamp?
    public var pid: Int?
    public var state: ServiceState
    public var ready: ReadyInfo?
    public var exit: ExitInfo?

    public init(
        id: RunID, projectId: ProjectID, serviceId: ServiceID, configRevision: Int,
        startedAt: Timestamp, endedAt: Timestamp?, pid: Int?, state: ServiceState, exit: ExitInfo?, startedBy: Actor? = nil, ready: ReadyInfo? = nil
    ) {
        self.id = id
        self.projectId = projectId
        self.serviceId = serviceId
        self.configRevision = configRevision
        self.startedAt = startedAt
        self.startedBy = startedBy
        self.endedAt = endedAt
        self.pid = pid
        self.state = state
        self.exit = exit
        self.ready = ready
    }
}

public struct LogInfo: Codable, Hashable, Sendable {
    public var firstSeq: Int?
    public var lastSeq: Int?
    public var bytes: Int
    public var truncated: Bool
}

/// Contract `ProcessInfo` (renamed to avoid shadowing Foundation.ProcessInfo).
public struct RunProcessInfo: Codable, Hashable, Sendable {
    public var pid: Int
    public var ppid: Int
    /// Process identity = pid + startedAt.
    public var startedAt: Timestamp
    /// Short name, e.g. "java".
    public var command: String
}

/// A value a run started with (`RunDetail.params`): the value, or `{ secret: true }`.
public enum RunParamValue: Codable, Hashable, Sendable {
    case value(ParamValue)
    case secret

    private struct SecretMarker: Codable { var secret: Bool }

    public init(from decoder: any Decoder) throws {
        if let marker = try? decoder.singleValueContainer().decode(SecretMarker.self), marker.secret {
            self = .secret
        } else {
            self = .value(try ParamValue(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .value(let v): try v.encode(to: encoder)
        case .secret:
            var c = encoder.singleValueContainer()
            try c.encode(SecretMarker(secret: true))
        }
    }
}

public struct RunDetail: Codable, Hashable, Sendable, Identifiable {
    public var id: RunID
    public var projectId: ProjectID
    public var serviceId: ServiceID
    public var configRevision: Int
    public var startedBy: Actor? = nil
    public var startedAt: Timestamp
    public var endedAt: Timestamp?
    public var pid: Int?
    public var state: ServiceState
    public var ready: ReadyInfo?
    public var exit: ExitInfo?
    /// argv actually executed, after ${key} substitution; secret fragments are "••••".
    public var command: [String]
    public var cwd: String
    public var envKeys: [String]
    /// v1.1-A. Values of the params this service actually referenced (command + effective
    /// non-secret env), not every project param. Required by the contract; decoded as empty
    /// when a v1.0 daemon omits it.
    public var params: [String: RunParamValue]
    public var log: LogInfo
    public var processes: [RunProcessInfo]

    private enum CodingKeys: String, CodingKey {
        case id, projectId, serviceId, configRevision, startedAt, endedAt, pid, state, exit, startedBy, ready
        case command, cwd, envKeys, params, log, processes
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(RunID.self, forKey: .id)
        projectId = try c.decode(ProjectID.self, forKey: .projectId)
        serviceId = try c.decode(ServiceID.self, forKey: .serviceId)
        configRevision = try c.decode(Int.self, forKey: .configRevision)
        startedBy = try c.decodeIfPresent(Actor.self, forKey: .startedBy)
        startedAt = try c.decode(Timestamp.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Timestamp.self, forKey: .endedAt)
        pid = try c.decodeIfPresent(Int.self, forKey: .pid)
        state = try c.decode(ServiceState.self, forKey: .state)
        exit = try c.decodeIfPresent(ExitInfo.self, forKey: .exit)
        ready = try c.decodeIfPresent(ReadyInfo.self, forKey: .ready)
        command = try c.decode([String].self, forKey: .command)
        cwd = try c.decode(String.self, forKey: .cwd)
        envKeys = try c.decode([String].self, forKey: .envKeys)
        params = try c.decodeIfPresent([String: RunParamValue].self, forKey: .params) ?? [:]
        log = try c.decode(LogInfo.self, forKey: .log)
        processes = try c.decode([RunProcessInfo].self, forKey: .processes)
    }

    public var summary: RunSummary {
        RunSummary(
            id: id, projectId: projectId, serviceId: serviceId, configRevision: configRevision,
            startedAt: startedAt, endedAt: endedAt, pid: pid, state: state, exit: exit, startedBy: startedBy, ready: ready)
    }
}

public struct ServiceView: Codable, Hashable, Sendable, Identifiable {
    public var hold: ServiceHold? = nil
    public var locked: Bool? = nil
    public var id: ServiceID
    public var name: String
    public var state: ServiceState
    public var stateSince: Timestamp?
    public var currentRun: RunSummary?
    public var lastRun: RunSummary?
    public var stopTimedOut: Bool
    public var pendingOperationId: OperationID?
    public var configChangedSinceStart: Bool
    public var error: ApiError?

    public init(
        id: ServiceID, name: String, state: ServiceState, stateSince: Timestamp? = nil,
        currentRun: RunSummary? = nil, lastRun: RunSummary? = nil, stopTimedOut: Bool = false,
        pendingOperationId: OperationID? = nil, configChangedSinceStart: Bool = false,
        error: ApiError? = nil
    ) {
        self.id = id
        self.name = name
        self.state = state
        self.stateSince = stateSince
        self.currentRun = currentRun
        self.lastRun = lastRun
        self.stopTimedOut = stopTimedOut
        self.pendingOperationId = pendingOperationId
        self.configChangedSinceStart = configChangedSinceStart
        self.error = error
    }
}

public enum ProjectAggregate: OpenEnum {
    case idle, running, partial, transition, stopped, failed, unknown
    case other(String)

    public static let known: [ProjectAggregate] = [
        .idle, .running, .partial, .transition, .stopped, .failed, .unknown,
    ]
    public var rawValue: String {
        switch self {
        case .idle: "idle"
        case .running: "running"
        case .partial: "partial"
        case .transition: "transition"
        case .stopped: "stopped"
        case .failed: "failed"
        case .unknown: "unknown"
        case .other(let s): s
        }
    }
}

public struct ProjectView: Codable, Hashable, Sendable, Identifiable {
    public var instance: ProjectInstance?
    public var policy: ProjectPolicy? = nil
    public var id: ProjectID
    public var name: String
    public var root: String
    public var revision: Int
    public var aggregate: ProjectAggregate
    public var runningCount: Int
    public var serviceCount: Int
    /// Config order.
    public var services: [ServiceView]
    private var decodedActions: [ActionView]?
    public var actions: [ActionView] { get { decodedActions ?? [] } set { decodedActions = newValue } }
    public var maven: MavenView?
    public var repositories: [RepositoryConfig]?
    public var mavenProjects: [MavenProjectView]?

    private enum CodingKeys: String, CodingKey {
        case id, name, root, revision, aggregate, runningCount, serviceCount, services, maven, policy, repositories, mavenProjects, instance
        case decodedActions = "actions"
    }

    public init(
        id: ProjectID, name: String, root: String, revision: Int, aggregate: ProjectAggregate,
        runningCount: Int, serviceCount: Int, services: [ServiceView], actions: [ActionView] = [], maven: MavenView? = nil
    ) {
        self.id = id
        self.name = name
        self.root = root
        self.revision = revision
        self.aggregate = aggregate
        self.runningCount = runningCount
        self.serviceCount = serviceCount
        self.services = services
        self.decodedActions = actions
        self.maven = maven
    }
}

public struct MavenProjectView: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var path: String
    public var executable: String?
    public var currentRun: TaskRunSummary?
    public var lastRun: TaskRunSummary?
}
