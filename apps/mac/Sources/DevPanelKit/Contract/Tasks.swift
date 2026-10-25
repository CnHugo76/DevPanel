import Foundation

public struct ActionConfig: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var description: String?
    public var cwd: String
    public var command: [String]
    public var env: EnvMap?
    public var stopTimeoutSec: Int?
    public var timeoutSec: Int?
    public var confirmWhenServicesRunning: Bool?
    public init(id: String, name: String, description: String? = nil, cwd: String = ".", command: [String], env: EnvMap? = nil, stopTimeoutSec: Int? = nil, timeoutSec: Int? = nil, confirmWhenServicesRunning: Bool? = nil) {
        self.id = id; self.name = name; self.description = description; self.cwd = cwd; self.command = command
        self.env = env; self.stopTimeoutSec = stopTimeoutSec; self.timeoutSec = timeoutSec; self.confirmWhenServicesRunning = confirmWhenServicesRunning
    }
}
public struct MavenConfig: Codable, Hashable, Sendable {
    public var executable: String?
    public init(executable: String? = nil) { self.executable = executable }
}
public struct MavenRunRequest: Codable, Hashable, Sendable {
    public var mavenProjectId: String?
    public var moduleId: String
    public var goals: [String]
    public var profiles: [String]?
    public var skipTests: Bool?
    public var offline: Bool?
    public var alsoMake: Bool?
}
public enum TaskRunState: OpenEnum {
    case running, cancelling, succeeded, failed, cancelled, timedOut, unknown
    case other(String)
    public static let known: [Self] = [.running, .cancelling, .succeeded, .failed, .cancelled, .timedOut, .unknown]
    public var rawValue: String {
        switch self {
        case .running: "running"
        case .cancelling: "cancelling"
        case .succeeded: "succeeded"
        case .failed: "failed"
        case .cancelled: "cancelled"
        case .timedOut: "timed-out"
        case .unknown: "unknown"
        case .other(let s): s
        }
    }
    public var isActive: Bool { self == .running || self == .cancelling }
    public var title: String {
        switch self {
        case .running: "运行中"
        case .cancelling: "取消中"
        case .succeeded: "成功"
        case .failed: "失败"
        case .cancelled: "已取消"
        case .timedOut: "超时"
        case .unknown, .other: "状态未知"
        }
    }
}
public enum TaskRunKind: OpenEnum {
    case action, maven
    case other(String)
    public static let known: [Self] = [.action, .maven]
    public var rawValue: String { switch self { case .action: "action"; case .maven: "maven"; case .other(let s): s } }
}
public struct TaskRunSummary: Codable, Hashable, Sendable, Identifiable {
    public var id: RunID
    public var projectId: ProjectID
    public var kind: TaskRunKind
    public var actionId: String?
    public var maven: MavenRunRequest?
    public var label: String
    public var configRevision: Int
    public var source: ClientKind
    public var startedBy: Actor? = nil
    public var startedAt: Timestamp
    public var endedAt: Timestamp?
    public var pid: Int?
    public var state: TaskRunState
    public var exit: ExitInfo?
    public var cancelTimedOut: Bool
    public func duration(now: Date) -> TimeInterval? {
        guard let start = Timestamps.date(startedAt) else { return nil }
        let end = Timestamps.date(endedAt) ?? (endedAt == nil ? now : nil)
        return end.map { max(0, $0.timeIntervalSince(start)) }
    }
    public func statusText(now: Date) -> String {
        var parts = [state.title]
        if let code = exit?.code { parts.append("退出码 \(code)") }
        if let duration = duration(now: now) { parts.append("用时 " + Format.duration(duration)) }
        return parts.joined(separator: " · ")
    }
}
public struct TaskRunDetail: Codable, Hashable, Sendable {
    public var id: RunID
    public var projectId: ProjectID
    public var kind: TaskRunKind
    public var actionId: String?
    public var maven: MavenRunRequest?
    public var label: String
    public var configRevision: Int
    public var source: ClientKind
    public var startedBy: Actor? = nil
    public var startedAt: Timestamp
    public var endedAt: Timestamp?
    public var pid: Int?
    public var state: TaskRunState
    public var exit: ExitInfo?
    public var cancelTimedOut: Bool
    public var command: [String]
    public var cwd: String
    public var envKeys: [String]
    public var params: [String: RunParamValue]
    public var log: LogInfo
    public var processes: [RunProcessInfo]
}
public struct ActionView: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var description: String?
    public var confirmWhenServicesRunning: Bool
    public var currentRun: TaskRunSummary?
    public var lastRun: TaskRunSummary?
}
public struct MavenView: Codable, Hashable, Sendable {
    public var currentRun: TaskRunSummary?
    public var lastRun: TaskRunSummary?
}
public struct StartTaskRunResponse: Codable, Hashable, Sendable {
    public var created: Bool
    public var run: TaskRunSummary
}
public struct CancelTaskRunRequest: Encodable, Sendable { public var force: Bool }
