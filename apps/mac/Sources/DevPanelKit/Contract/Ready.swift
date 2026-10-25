import Foundation

public enum ReadyCheckKind: OpenEnum {
    case log, port, other(String)
    public static let known: [Self] = [.log, .port]
    public var rawValue: String {
        switch self {
        case .log: "log"
        case .port: "port"
        case .other(let value): value
        }
    }
}

public enum ReadyState: OpenEnum {
    case notConfigured, waiting, ready, timedOut, endedBeforeReady, unknown, other(String)
    public static let known: [Self] = [.notConfigured, .waiting, .ready, .timedOut, .endedBeforeReady, .unknown]
    public var rawValue: String {
        switch self {
        case .notConfigured: "not-configured"
        case .waiting: "waiting"
        case .ready: "ready"
        case .timedOut: "timed-out"
        case .endedBeforeReady: "ended-before-ready"
        case .unknown: "unknown"
        case .other(let value): value
        }
    }
}

public struct ReadyCheck: Codable, Hashable, Sendable {
    public var kind: ReadyCheckKind
    public var contains: [String]?
    public var port: ParamValue?
    public init(kind: ReadyCheckKind, contains: [String]? = nil, port: ParamValue? = nil) { self.kind = kind; self.contains = contains; self.port = port }
}
public struct ReadyConfig: Codable, Hashable, Sendable {
    public var check: ReadyCheck
    public var timeoutSec: Double?
    public init(check: ReadyCheck, timeoutSec: Double? = nil) { self.check = check; self.timeoutSec = timeoutSec }
}
public struct ReadyInfo: Codable, Hashable, Sendable {
    public var state: ReadyState
    public var at: Timestamp?
    public var afterMs: Double?
    public var evidence: Evidence?
    public struct Evidence: Codable, Hashable, Sendable {
        public var kind: ReadyCheckKind
        public var seq: Int?
        public var port: Int?
        public var address: String?
    }
    public var label: String? {
        switch state { case .notConfigured: "未配置就绪"; case .waiting: "等待就绪"; case .ready: "已就绪"; case .timedOut: "就绪超时"; case .endedBeforeReady: "就绪前结束"; case .unknown: "就绪未知"; default: nil }
    }
    public var explanation: String {
        var text = label ?? "未配置"
        if state == .ready, let afterMs { text = "启动后 \(String(format: "%.1f", afterMs / 1000)) 秒就绪" }
        if let evidence {
            if evidence.kind == .log, let seq = evidence.seq { text += " · 依据：日志第 \(seq) 行" }
            if evidence.kind == .port, let port = evidence.port { text += " · 依据：\(evidence.address ?? ""):\(port)" }
        }
        return text
    }

    /// A running process is separate from an observed readiness condition.
    public var processTone: DisplayTone {
        switch state {
        case .ready: .green
        case .timedOut, .endedBeforeReady: .amberStrong
        case .unknown, .other: .purple
        case .notConfigured, .waiting: .blue
        }
    }

    public var nextStep: String? {
        switch state {
        case .notConfigured: "在配置中添加日志关键字或监听端口条件，才能确认服务就绪。"
        case .waiting: "查看启动日志；只有观察到配置的日志或端口条件才会标记就绪。"
        case .timedOut: "查看错误上下文和实际启动参数，再核对就绪条件；超时不会自动结束进程。"
        case .endedBeforeReady: "查看退出信息和首个错误上下文，排除启动失败后再重试。"
        case .unknown, .other: "检查管理服务连接与运行记录；当前证据不足，不能确认可用。"
        case .ready: nil
        }
    }
}
