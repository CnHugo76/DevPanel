import Foundation

// Wording for runs: the log view's run picker and the "运行记录" tab (ui-design v1 §5.4, v2 §4),
// ported from apps/ui/src/lib/status.ts `runLabel` / `runStateText` and format.ts.

extension Format {
    /// `12,304`.
    public static func count(_ n: Int) -> String {
        let digits = String(n.magnitude)
        var out = ""
        for (i, ch) in digits.enumerated() {
            if i > 0, (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return n < 0 ? "-" + out : out
    }

    /// `12 秒前`, `3 分钟前`, `2 小时前`, `1 天前`.
    public static func ago(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "\(s) 秒前" }
        let m = s / 60
        if m < 60 { return "\(m) 分钟前" }
        let h = m / 60
        if h < 24 { return "\(h) 小时前" }
        return "\(h / 24) 天前"
    }

    /// `10:42 起`, `10:12–10:40`, `昨天 18:02–10/19 01:10`.
    public static func range(start: Date, end: Date?, now: Date, calendar: Calendar = .current) -> String {
        let s = dayTime(start, now: now, calendar: calendar)
        guard let end else { return "\(s) 起" }
        if calendar.isDate(start, inSameDayAs: end) {
            let c = calendar.dateComponents([.hour, .minute], from: end)
            return "\(s)–\(String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0))"
        }
        return "\(s)–\(dayTime(end, now: now, calendar: calendar))"
    }

    /// `10/20 10:42:07` (local, seconds included) for the run history.
    public static func dateTime(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let day: String
        if calendar.isDate(date, inSameDayAs: now) {
            day = "今天"
        } else if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) {
            day = "昨天"
        } else {
            let c = calendar.dateComponents([.month, .day], from: date)
            day = "\(c.month ?? 0)/\(c.day ?? 0)"
        }
        return "\(day) \(clock(date, calendar: calendar))"
    }
}

extension ExitReason {
    /// 手动停止 / 强制停止 / 自行退出 / 启动失败 / 启动被取消 / 管理服务中断.
    public var label: String {
        switch self {
        case .userStop: "手动停止"
        case .forceStop: "强制停止"
        case .selfExit: "自行退出"
        case .spawnFailed: "启动失败"
        case .startCancelled: "启动被取消"
        case .daemonLost: "管理服务中断"
        case .other(let raw): raw
        }
    }
}

extension ExitInfo {
    /// "手动停止 · 信号 SIGTERM", "自行退出 · 退出（1）", "管理服务中断，运行已丢失".
    public var summary: String {
        if reason == .daemonLost { return "管理服务中断，运行已丢失" }
        guard let detail = displayText else { return reason.label }
        return "\(reason.label) · \(detail)"
    }
}

extension RunSummary {
    /// 已停止 / 已强制停止 / 已退出（0）/ 启动失败 / 异常（1）/ 运行中 / …
    public var stateText: String {
        switch state {
        case .stopped: return exit?.reason == .forceStop ? "已强制停止" : "已停止"
        case .exited: return "已退出（\(exit?.code ?? 0)）"
        case .failed:
            if exit?.reason == .spawnFailed { return "启动失败" }
            if exit?.reason == .daemonLost { return "管理服务中断" }
            if let code = exit?.code { return "异常（\(code)）" }
            if let signal = exit?.signal { return "异常（\(signal)）" }
            return "异常"
        case .starting: return "启动中"
        case .running: return "运行中"
        case .stopping: return "停止中"
        case .unknown: return "状态未知"
        case .idle: return "未启动"
        case .other(let raw): return raw
        }
    }

    public var tone: DisplayTone {
        switch state {
        case .running: .green
        case .starting: .blue
        case .stopping: .amber
        case .failed: .red
        case .unknown: .purple
        default: .gray
        }
    }

    /// Run time: until `endedAt`, or until `now` while it has not ended.
    public func duration(now: Date) -> TimeInterval? {
        guard let start = Timestamps.date(startedAt) else { return nil }
        let end = Timestamps.date(endedAt) ?? (endedAt == nil ? now : nil)
        return end.map { max(0, $0.timeIntervalSince(start)) }
    }

    /// `10:42 起` / `10:12–10:40`.
    public func rangeText(now: Date, calendar: Calendar = .current) -> String {
        guard let start = Timestamps.date(startedAt) else { return "—" }
        return Format.range(start: start, end: Timestamps.date(endedAt), now: now, calendar: calendar)
    }
}

public enum RunLabels {
    /// Segment titles of the log view's run picker / run history cards, by position in the
    /// newest-first list: "当前运行" (the active run) or "最近一次", then "上一次", "更早".
    public static func title(index: Int, isCurrent: Bool) -> String {
        if isCurrent { return "当前运行" }
        switch index {
        case 0: return "最近一次"
        case 1: return "上一次"
        default: return "更早"
        }
    }

    /// Picker tooltip: "当前运行 · 10:42 起", "上一次 · 10:12–10:40 · 已停止".
    public static func detail(_ run: RunSummary, index: Int, isCurrent: Bool, now: Date, calendar: Calendar = .current) -> String {
        let title = title(index: index, isCurrent: isCurrent)
        if isCurrent { return "\(title) · \(run.rangeText(now: now, calendar: calendar))" }
        return "\(title) · \(run.rangeText(now: now, calendar: calendar)) · \(run.stateText)"
    }

    /// Newest first: the fetched list with the service view's `currentRun` / `lastRun` merged in
    /// (the view is fresher), only this service's runs, at most `limit`.
    public static func merge(_ fetched: [RunSummary], service: ServiceView, serviceId: ServiceID, limit: Int) -> [RunSummary] {
        var list = fetched.filter { $0.serviceId == serviceId }
        for r in [service.lastRun, service.currentRun].compactMap({ $0 }) where r.serviceId == serviceId {
            if let i = list.firstIndex(where: { $0.id == r.id }) { list[i] = r } else { list.append(r) }
        }
        list.sort { (Timestamps.date($0.startedAt) ?? .distantPast) > (Timestamps.date($1.startedAt) ?? .distantPast) }
        return Array(list.prefix(max(limit, 1)))
    }
}

/// One param value a run started with (`RunDetail.params`).
public struct RunParamRow: Sendable, Equatable, Identifiable {
    public var key: String
    /// The param's current label when it still exists, else the key.
    public var label: String
    /// "dev（本地开发）", "8081", "true", "••••".
    public var value: String
    public var secret: Bool
    public var id: String { key }

    /// Rows in the project's param order (unknown keys last, alphabetically).
    public static func make(_ params: [String: RunParamValue], config: [ParamConfig]) -> [RunParamRow] {
        let order = Dictionary(config.enumerated().map { ($1.key, $0) }, uniquingKeysWith: { a, _ in a })
        let byKey = Dictionary(config.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        return params.keys.sorted { a, b in
            switch (order[a], order[b]) {
            case let (x?, y?): x < y
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): a < b
            }
        }.map { key in
            let p = byKey[key]
            switch params[key]! {
            case .secret:
                return RunParamRow(key: key, label: p?.label ?? key, value: "••••", secret: true)
            case .value(let v):
                var text = v.description
                if case .string(let s) = v, p?.type == .enum,
                   let label = p?.choices?.first(where: { $0.value == s })?.label, !label.isEmpty, label != s {
                    text = "\(s)（\(label)）"
                }
                if text.isEmpty { text = "（空）" }
                return RunParamRow(key: key, label: p?.label ?? key, value: text, secret: false)
            }
        }
    }
}

/// One environment variable of the saved config ("命令与环境").
public struct EnvDisplayRow: Sendable, Equatable, Identifiable {
    public enum Source: Sendable, Equatable { case project, service }
    public var key: String
    /// The saved value (placeholders as written); "••••" for secrets.
    public var value: String
    public var secret: Bool
    public var source: Source
    /// With the current param values substituted, when it contains placeholders.
    public var preview: String?
    public var id: String { key }

    /// Project env overridden by the service env (the service wins), sorted by key.
    public static func make(project: EnvMap?, service: EnvMap?, params: [ParamConfig]) -> [EnvDisplayRow] {
        var rows: [String: EnvDisplayRow] = [:]
        func add(_ map: EnvMap?, _ source: Source) {
            for (key, value) in map ?? [:] {
                switch value {
                case .secret:
                    rows[key] = EnvDisplayRow(key: key, value: "••••", secret: true, source: source, preview: nil)
                case .plain(let s):
                    var preview: String?
                    if CommandText.hasPlaceholders([s]) {
                        preview = CommandText.substitute([s], params: params).first
                    }
                    rows[key] = EnvDisplayRow(key: key, value: s, secret: false, source: source, preview: preview)
                }
            }
        }
        add(project, .project)
        add(service, .service)
        return rows.values.sorted { $0.key < $1.key }
    }
}
