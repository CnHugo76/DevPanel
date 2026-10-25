import Foundation

// Status line and empty states of the log view (ui-design v1 §5.4).

public struct LogFooterItem: Equatable, Sendable, Identifiable {
    public enum Tone: Equatable, Sendable { case muted, warning, negative }
    public var id: String
    public var text: String
    public var tone: Tone

    public init(_ id: String, _ text: String, _ tone: Tone = .muted) {
        self.id = id
        self.text = text
        self.tone = tone
    }
}

public enum LogFooter {
    /// Silence longer than this shows "暂无新输出 · 最后输出于 …".
    public static let quietAfter: TimeInterval = 60

    /// - Parameters:
    ///   - live: the viewed run has not ended.
    ///   - stale: the daemon connection is down (shown state may be old).
    ///   - now: `AppModel.displayNow` (frozen while stale).
    public static func items(
        status: LogStatus, buffer: LogBuffer, live: Bool, stale: Bool, now: Date, logBytesPerRun: Int?
    ) -> [LogFooterItem] {
        var out: [LogFooterItem] = []
        if !buffer.isEmpty { out.append(LogFooterItem("count", "已加载 \(Format.count(buffer.count)) 行")) }
        if status.loading { out.append(LogFooterItem("loading", "正在加载…")) }
        if status.loadingOlder { out.append(LogFooterItem("older", "正在加载更早的日志…")) }
        if status.truncated {
            let limit = Format.bytes(logBytesPerRun ?? 32 * 1024 * 1024)
            out.append(LogFooterItem("truncated", "较早内容已按上限截断（每次运行 \(limit)）", .warning))
        }
        if buffer.localTrimmed {
            out.append(LogFooterItem(
                "trimmed", "界面最多保留 \(Format.count(buffer.cap)) 行，更早的已移出内存，向上滚动可重新加载"))
        }
        if let gap = status.gap { out.append(LogFooterItem("gap", "采集中断：\(gap)", .negative)) }
        if live, stale || status.reconnecting {
            let resume = buffer.lastSeq.map { "重连后从第 \(Format.count($0)) 行续接" } ?? "正在重连"
            out.append(LogFooterItem("reconnect", "日志流已断开，\(resume)", .warning))
        }
        if live, let last = status.lastLineAt, now.timeIntervalSince(last) > quietAfter {
            out.append(LogFooterItem("quiet", "暂无新输出 · 最后输出于 \(Format.ago(now.timeIntervalSince(last)))"))
        }
        if !live, !status.loading, status.error == nil { out.append(LogFooterItem("ended", "运行已结束")) }
        return out
    }
}

/// What the log body shows instead of lines.
public enum LogEmptyState: Equatable, Sendable {
    /// The service never ran.
    case neverRun
    /// Running, nothing printed yet.
    case waitingForOutput
    /// The run ended without output.
    case noOutput
    case error(String)

    public var title: String? {
        switch self {
        case .neverRun: "该服务尚未运行"
        default: nil
        }
    }

    public var text: String {
        switch self {
        case .neverRun: "点击「启动」后，日志会显示在这里。注册项目不会自动启动。"
        case .waitingForOutput: "暂无输出。部分程序会缓冲输出，日志可能延迟出现。"
        case .noOutput: "该运行没有任何输出。"
        case .error(let message): message
        }
    }

    /// nil = show the lines (or nothing while the first page loads).
    public static func make(hasRun: Bool, status: LogStatus, lineCount: Int, live: Bool) -> LogEmptyState? {
        guard hasRun else { return .neverRun }
        guard lineCount == 0 else { return nil }
        if let error = status.error { return .error(error) }
        if status.loading { return nil }
        return live ? .waitingForOutput : .noOutput
    }
}
