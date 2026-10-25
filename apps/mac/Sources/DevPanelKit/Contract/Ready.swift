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
        switch state { case .waiting: "等待中"; case .ready: "已就绪"; case .timedOut: "未就绪"; case .endedBeforeReady: "就绪前结束"; case .unknown: "就绪未知"; default: nil }
    }
    public var explanation: String {
        var text = label ?? "未配置"
        if let afterMs { text = "启动后 \(String(format: "%.1f", afterMs / 1000)) 秒就绪" }
        if let evidence {
            if evidence.kind == .log, let seq = evidence.seq { text += " · 依据：日志第 \(seq) 行" }
            if evidence.kind == .port, let port = evidence.port { text += " · 依据：\(evidence.address ?? ""):\(port)" }
        }
        return text
    }
}
