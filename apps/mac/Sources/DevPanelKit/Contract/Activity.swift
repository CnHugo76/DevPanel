import Foundation

public enum ActivityKind: OpenEnum {
    case operation, config, taskRun, policy, other(String)
    public static let known: [Self] = [.operation, .config, .taskRun, .policy]
    public var rawValue: String {
        switch self {
        case .operation: "operation"
        case .config: "config"
        case .taskRun: "task-run"
        case .policy: "policy"
        case .other(let value): value
        }
    }
}

public struct Actor: Codable, Hashable, Sendable {
    public var client: ClientKind
    public var agent: String?
    public init(client: ClientKind, agent: String? = nil) { self.client = client; self.agent = agent }
    public var displayName: String {
        switch client {
        case .ui: "你"
        case .daemon: "DevPanel"
        case .cli:
            switch agent { case "claude-code": "Claude Code"; case "codex": "Codex"; case .some(let name): name; case nil: "命令行" }
        default: "未知"
        }
    }
}
public struct ActivityEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var projectId: ProjectID
    public var at: Timestamp
    public var actor: Actor
    public var detail: JSONValue
    public var kind: ActivityKind { ActivityKind(raw: detail["kind"]?.stringValue ?? "未知") }
    public var title: String {
        switch kind {
        case .operation:
            let action = detail["action"]?.stringValue ?? ""
            let word = ["start": "启动", "stop": "停止", "restart": "重启", "force-stop": "强制停止"][action] ?? action
            let ids = detail["serviceIds"]?.arrayValue?.compactMap(\.stringValue).joined(separator: "、") ?? ""
            let state = detail["state"]?.stringValue ?? ""
            let status = ["succeeded": "成功", "partial": "部分成功", "failed": "失败", "cancelled": "已取消"][state] ?? state
            return "\(word)了 \(ids) · \(status)" + (detail["overrideHold"]?.boolValue == true ? " · 越过了你的暂停" : "")
        case .config: return "修改了配置 · revision \(detail["fromRevision"]?.intValue ?? 0) → \(detail["toRevision"]?.intValue ?? 0)"
        case .taskRun: return "\(detail["label"]?.stringValue ?? "任务") · \(detail["state"]?.stringValue ?? "")"
        case .policy: return ["hold": "暂停了 AI 启动", "release": "允许 AI 启动", "lock": "锁定了服务", "unlock": "解锁了服务", "settings": "修改了 AI 权限"][detail["change"]?.stringValue ?? ""] ?? "修改了托管规则"
        default: return kind.rawValue
        }
    }
    public var runIds: [RunID] {
        if let id = detail["runId"]?.stringValue { return [id] }
        return detail["results"]?.arrayValue?.compactMap { $0["runId"]?.stringValue } ?? []
    }
}
public struct ActivityPage: Codable, Hashable, Sendable {
    public var entries: [ActivityEntry]
    public var hasMore: Bool
}
extension ServiceView {
    public var actorNote: String { actorNote(now: Date()) }
    public func actorNote(now: Date) -> String {
        if let run = currentRun { return "由 \(run.startedBy?.displayName ?? "未知") 启动 · \(Timestamps.date(run.startedAt).map { Format.ago(max(0, now.timeIntervalSince($0))) } ?? "未知时间")" }
        if let exit = lastRun?.exit, [.userStop, .forceStop, .startCancelled].contains(exit.reason) { return "由 \(exit.requestedBy?.displayName ?? "未知") 停止" }
        return lastRun == nil ? "" : "由 \(lastRun?.startedBy?.displayName ?? "未知") 启动"
    }
}
