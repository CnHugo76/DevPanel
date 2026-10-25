import Foundation

// Mirrors packages/contract/src/index.ts — "Errors".

public enum ErrorCode: OpenEnum {
    case projectNotFound, serviceNotFound, runNotFound, operationNotFound
    case configInvalid, configConflict, revisionMismatch
    case commandNotFound, cwdUnavailable, spawnFailed, exitedDuringStart
    case stopTimeout, stateUnverifiable, projectRunning, operationCancelled
    case unauthorized, forbiddenOrigin, badRequest
    /// Produced by clients (this app), never by the daemon.
    case daemonUnreachable
    case paramUnknown, paramInvalid, paramInUse
    case `internal`
    case other(String)

    public static let known: [ErrorCode] = [
        .projectNotFound, .serviceNotFound, .runNotFound, .operationNotFound,
        .configInvalid, .configConflict, .revisionMismatch,
        .commandNotFound, .cwdUnavailable, .spawnFailed, .exitedDuringStart,
        .stopTimeout, .stateUnverifiable, .projectRunning, .operationCancelled,
        .unauthorized, .forbiddenOrigin, .badRequest, .daemonUnreachable,
        .paramUnknown, .paramInvalid, .paramInUse, .internal,
    ]

    public var rawValue: String {
        switch self {
        case .projectNotFound: "PROJECT_NOT_FOUND"
        case .serviceNotFound: "SERVICE_NOT_FOUND"
        case .runNotFound: "RUN_NOT_FOUND"
        case .operationNotFound: "OPERATION_NOT_FOUND"
        case .configInvalid: "CONFIG_INVALID"
        case .configConflict: "CONFIG_CONFLICT"
        case .revisionMismatch: "REVISION_MISMATCH"
        case .commandNotFound: "COMMAND_NOT_FOUND"
        case .cwdUnavailable: "CWD_UNAVAILABLE"
        case .spawnFailed: "SPAWN_FAILED"
        case .exitedDuringStart: "EXITED_DURING_START"
        case .stopTimeout: "STOP_TIMEOUT"
        case .stateUnverifiable: "STATE_UNVERIFIABLE"
        case .projectRunning: "PROJECT_RUNNING"
        case .operationCancelled: "OPERATION_CANCELLED"
        case .unauthorized: "UNAUTHORIZED"
        case .forbiddenOrigin: "FORBIDDEN_ORIGIN"
        case .badRequest: "BAD_REQUEST"
        case .daemonUnreachable: "DAEMON_UNREACHABLE"
        case .paramUnknown: "PARAM_UNKNOWN"
        case .paramInvalid: "PARAM_INVALID"
        case .paramInUse: "PARAM_IN_USE"
        case .internal: "INTERNAL"
        case .other(let s): s
        }
    }
}

public struct ApiError: Error, Codable, Hashable, Sendable, LocalizedError, CustomStringConvertible {
    public var code: ErrorCode
    public var message: String
    public var details: [String: JSONValue]?

    public init(code: ErrorCode, message: String, details: [String: JSONValue]? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }

    public var errorDescription: String? { message }
    public var description: String { "\(code.rawValue): \(message)" }

    // MARK: Typed views of documented `details`

    /// REVISION_MISMATCH / CONFIG_CONFLICT: the current revision.
    public var currentRevision: Int? { details?["revision"]?.intValue }

    /// CONFIG_INVALID: `details.issues`.
    public var issues: [ValidationIssue]? {
        guard let raw = details?["issues"] else { return nil }
        return try? raw.decode(as: [ValidationIssue].self)
    }

    /// CONFIG_CONFLICT: `details.diff`.
    public var configDiff: [ConfigDiffEntry]? {
        guard let raw = details?["diff"] else { return nil }
        return try? raw.decode(as: [ConfigDiffEntry].self)
    }

    /// STOP_TIMEOUT: `details.timeoutSec`.
    public var stopTimeoutSec: Int? { details?["timeoutSec"]?.intValue }
    /// STOP_TIMEOUT: `details.remaining` (still-live verified processes).
    public var remainingProcesses: Int? { details?["remaining"]?.intValue }

    /// PARAM_IN_USE: `details.usedBy`.
    public var paramUsedBy: [ParamReference]? {
        guard let raw = details?["usedBy"] else { return nil }
        return try? raw.decode(as: [ParamReference].self)
    }
}

public struct ErrorBody: Codable, Hashable, Sendable {
    public var error: ApiError

    public init(error: ApiError) { self.error = error }
}

extension ApiError {
    /// Built by the client when the daemon cannot be reached.
    public static func unreachable(_ message: String = "无法连接管理服务") -> ApiError {
        ApiError(code: .daemonUnreachable, message: message)
    }
}
