import Foundation

// UI wording shared by all views (ui-design v1 §3, v2 §3.1 / §7). Kept in the kit so it is
// testable and every view says the same thing. Forbidden words: 健康、就绪、验证通过、正常.

extension ProjectAggregate {
    /// "2/2 运行中", "部分运行 1/2", "异常", … (ui-design v2 §3.1)
    public func label(running: Int, total: Int) -> String {
        switch self {
        case .running: "\(running)/\(total) 运行中"
        case .partial: "部分运行 \(running)/\(total)"
        case .transition: "处理中"
        case .failed: "异常"
        case .stopped: "已停止"
        case .idle: "未启动"
        case .unknown: "状态未知"
        case .other(let raw): raw
        }
    }
}

extension ServiceState {
    public var label: String {
        switch self {
        case .idle: "未启动"
        case .starting: "启动中"
        case .running: "运行中"
        case .stopping: "停止中"
        case .stopped: "已停止"
        case .exited: "已退出"
        case .failed: "异常"
        case .unknown: "状态未知"
        case .other(let raw): raw
        }
    }
}

/// Visual tone of a connection status (the view maps it to colors).
public enum StatusTone: Sendable, Equatable {
    case positive, warning, negative, neutral
}

extension ConnectionState {
    /// Toolbar text, e.g. "已连接 · 4/7 服务运行中" or "管理服务连接中断 · 5 秒后重连".
    public func summary(running: Int, total: Int, projectCount: Int, now: Date) -> String {
        switch status {
        case .connecting:
            return "正在连接管理服务…"
        case .connected:
            return projectCount == 0 ? "已连接 · 还没有项目" : "已连接 · \(running)/\(total) 服务运行中"
        case .disconnected:
            return "管理服务连接中断 · \(retryText(now: now, verb: "重连"))"
        case .unauthorized:
            return "管理服务拒绝了认证 · \(retryText(now: now, verb: "重试"))"
        case .notRunning:
            return "管理服务未运行"
        }
    }

    public var tone: StatusTone {
        switch status {
        case .connected: .positive
        case .disconnected, .connecting: .warning
        case .unauthorized: .negative
        case .notRunning: .neutral
        }
    }

    /// Whole seconds until the next attempt (nil while attempting).
    public func secondsUntilRetry(now: Date) -> Int? {
        guard let retryAt else { return nil }
        return max(0, Int(retryAt.timeIntervalSince(now).rounded(.up)))
    }

    private func retryText(now: Date, verb: String) -> String {
        guard let s = secondsUntilRetry(now: now), s > 0 else { return "正在\(verb)" }
        return "\(s) 秒后\(verb)"
    }
}

/// Disconnected banner (ui-design v2 §7, mockup "管理服务断开").
public enum StaleCopy {
    /// "下面是 10:46:12 的状态，可能已过期；操作暂时不可用。"
    public static func banner(syncedAt: Date?, calendar: Calendar = .current) -> String {
        let at = syncedAt.map { Format.clock($0, calendar: calendar) } ?? "—"
        return "下面是 \(at) 的状态，可能已过期；操作暂时不可用。"
    }
}

/// No projects yet (ui-design v2 §8).
public enum EmptyStateCopy {
    public static let title = "还没有项目"
    public static let body = "在项目里对你的编程 Agent 说「把这个项目加入 DevPanel」。它会读懂启动方式，把常改的配置做成选项并写好说明。"
    public static let registerCommand = "devpanel project register --config ./devpanel.json"
    public static let manualAdd = "＋ 手动添加项目"
    public static func noMatch(_ query: String) -> String { "没有名称包含「\(query)」的项目或服务" }
}
