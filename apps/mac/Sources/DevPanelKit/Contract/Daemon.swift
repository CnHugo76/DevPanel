import Foundation

// Mirrors packages/contract/src/index.ts — "Daemon", "Validation", "Local discovery".

public enum API {
    public static let version = 1
    public static let basePath = "/api/v1"
    /// Header every mutating request must carry.
    public static let clientHeader = "X-DevPanel-Client"
    /// What this app sends in `X-DevPanel-Client` (params it changes are recorded as set by the user).
    public static let clientKind = "ui"
}

public struct Limits: Codable, Hashable, Sendable {
    public var taskRunsKept: Int?
    public var logBytesPerTaskRun: Int?
    public var logBytesPerRun: Int
    public var runsKeptPerService: Int
    public var logBytesGlobal: Int
    public var logLineMaxBytes: Int
    public var logPageMaxLines: Int
    public var statsIntervalMs: Int
    public var startGraceMs: Int
    public var defaultStopTimeoutSec: Int
}

public struct DaemonInfo: Codable, Hashable, Sendable {
    public var version: String
    public var apiVersion: Int
    public var pid: Int
    public var startedAt: Timestamp
    public var home: String
    public var limits: Limits
    /// The daemon's own footprint (wire name `self`).
    public var selfUsage: ResourceSample
    /// Optional on older daemons. Excludes all managed project processes.
    public var toolResources: DaemonToolResources?

    private enum CodingKeys: String, CodingKey {
        case version, apiVersion, pid, startedAt, home, limits, toolResources
        case selfUsage = "self"
    }
}

public struct DaemonToolResources: Codable, Hashable, Sendable {
    public var daemon: ResourceSample
    public var helpers: ResourceSample
    public var total: ResourceSample

    public init(daemon: ResourceSample, helpers: ResourceSample, total: ResourceSample) {
        self.daemon = daemon; self.helpers = helpers; self.total = total
    }
}

/// `<home>/daemon.json`, written by the daemon with mode 0600.
public struct DaemonDiscovery: Codable, Hashable, Sendable {
    public var pid: Int
    public var version: String
    public var apiVersion: Int
    public var socketPath: String
    public var httpPort: Int
    public var token: String
    public var startedAt: Timestamp

    public init(
        pid: Int, version: String, apiVersion: Int = API.version, socketPath: String, httpPort: Int,
        token: String, startedAt: Timestamp
    ) {
        self.pid = pid
        self.version = version
        self.apiVersion = apiVersion
        self.socketPath = socketPath
        self.httpPort = httpPort
        self.token = token
        self.startedAt = startedAt
    }
}

// MARK: - Validation

public enum WarningCode: OpenEnum {
    case backgroundCommand, shellCompound, secretLikePlain, paramUnused
    case other(String)

    public static let known: [WarningCode] = [
        .backgroundCommand, .shellCompound, .secretLikePlain, .paramUnused,
    ]
    public var rawValue: String {
        switch self {
        case .backgroundCommand: "WARN_BACKGROUND_COMMAND"
        case .shellCompound: "WARN_SHELL_COMPOUND"
        case .secretLikePlain: "WARN_SECRET_LIKE_PLAIN"
        case .paramUnused: "WARN_PARAM_UNUSED"
        case .other(let s): s
        }
    }
}

/// `ValidationIssue.code` is `ErrorCode | WarningCode`.
public enum IssueCode: Codable, Hashable, Sendable, CustomStringConvertible {
    case error(ErrorCode)
    case warning(WarningCode)
    /// Neither a known error code nor a known warning code.
    case other(String)

    public init(rawValue: String) {
        let e = ErrorCode(raw: rawValue)
        if e.isKnown {
            self = .error(e)
            return
        }
        let w = WarningCode(raw: rawValue)
        self = w.isKnown ? .warning(w) : .other(rawValue)
    }

    public var rawValue: String {
        switch self {
        case .error(let e): e.rawValue
        case .warning(let w): w.rawValue
        case .other(let s): s
        }
    }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public var description: String { rawValue }
}

public enum IssueSeverity: OpenEnum {
    case error, warning
    case other(String)

    public static let known: [IssueSeverity] = [.error, .warning]
    public var rawValue: String {
        switch self {
        case .error: "error"
        case .warning: "warning"
        case .other(let s): s
        }
    }
}

public struct ValidationIssue: Codable, Hashable, Sendable {
    /// e.g. "services[1].command[0]".
    public var path: String
    public var severity: IssueSeverity
    public var code: IssueCode
    public var message: String
}

public struct ServiceResolution: Codable, Hashable, Sendable {
    public var serviceId: ServiceID
    public var cwdAbs: String
    public var cwdExists: Bool
    public var program: String
    public var programResolved: String?
    public var pathUsed: String
}

public struct ValidateResult: Codable, Hashable, Sendable {
    public var ok: Bool
    public var issues: [ValidationIssue]
    public var services: [ServiceResolution]
}
