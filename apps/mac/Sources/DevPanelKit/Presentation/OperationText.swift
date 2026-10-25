import Foundation

// Operation result bar (ui-design v1 §5.1), ported from status.ts `operationSummary`.

extension ActionKind {
    /// 启动 / 停止 / 重启 / 强制停止.
    public var verb: String {
        switch self {
        case .start: "启动"
        case .stop: "停止"
        case .restart: "重启"
        case .forceStop: "强制停止"
        case .other(let raw): raw
        }
    }
}

extension OperationTargetResult {
    /// "已启动", "失败：命令不存在 pnpm（PATH 中未找到）", "已发送 SIGTERM，10 秒内未全部退出（仍有 3 个受管进程）", …
    public var displayText: String {
        switch outcome {
        case .pending: return "进行中"
        case .started: return "已启动"
        case .alreadyRunning: return "已在运行"
        case .stopped: return "已停止"
        case .alreadyStopped: return "本就未运行"
        case .stopTimeout: return Self.stopTimeoutText(error)
        case .failed:
            if error?.code == .stopTimeout { return "失败：" + Self.stopTimeoutText(error) }
            return "失败：" + (error.map(\.displayText) ?? "原因未知")
        case .cancelled: return "已取消（被停止操作取代）"
        case .other(let raw): return raw
        }
    }

    public var tone: OperationSummary.Tone {
        switch outcome {
        case .started, .alreadyRunning, .stopped, .alreadyStopped, .pending: .ok
        case .stopTimeout, .cancelled: .warn
        case .failed: .bad
        case .other: .warn
        }
    }

    static func stopTimeoutText(_ error: ApiError?) -> String {
        let sec = error?.stopTimeoutSec
        let remaining = error?.remainingProcesses
        var text = "已发送 SIGTERM，" + (sec.map { "\($0) 秒内" } ?? "限时内") + "未全部退出"
        if let remaining { text += "（仍有 \(remaining) 个受管进程）" }
        return text
    }
}

public struct OperationSummary: Sendable, Equatable {
    public enum Tone: Sendable, Equatable { case ok, warn, bad }

    public struct Item: Sendable, Equatable {
        public var serviceId: ServiceID
        public var name: String
        public var text: String
        public var tone: Tone
    }

    /// "已启动", "部分运行", "停止未完成", "启动失败", "请求未被接受", …
    public var title: String
    public var items: [Item]
    public var tone: Tone
    /// Extra advice, e.g. "可继续等待，或强制停止。"
    public var hint: String?
    /// "来源 cli" when another client started it.
    public var sourceNote: String?

    public init(
        title: String, items: [Item], tone: Tone, hint: String? = nil, sourceNote: String? = nil
    ) {
        self.title = title
        self.items = items
        self.tone = tone
        self.hint = hint
        self.sourceNote = sourceNote
    }

    /// `POST /operations` itself failed.
    public static func rejected(_ error: ApiError) -> OperationSummary {
        OperationSummary(
            title: "请求未被接受",
            items: [Item(serviceId: "", name: "", text: error.displayText, tone: .bad)], tone: .bad)
    }
}

extension Operation {
    public func summary(nameOf: (ServiceID) -> String) -> OperationSummary {
        let verb = action.verb
        let items = results.map {
            OperationSummary.Item(serviceId: $0.serviceId, name: nameOf($0.serviceId), text: $0.displayText, tone: $0.tone)
        }
        let timedOut = results.contains { $0.outcome == .stopTimeout || $0.error?.code == .stopTimeout }
        let title: String
        let tone: OperationSummary.Tone
        switch state {
        case .succeeded:
            title = action == .start && !results.isEmpty && results.allSatisfy { $0.outcome == .alreadyRunning }
                ? "已在运行" : "已\(verb)"
            tone = .ok
        case .partial where timedOut:
            title = "\(verb)未完成"
            tone = .warn
        case .partial:
            title = action == .start || action == .restart ? "部分运行" : "部分\(verb)"
            tone = .warn
        case .failed:
            title = timedOut ? "\(verb)未完成" : "\(verb)失败"
            tone = timedOut ? .warn : .bad
        case .cancelled:
            title = "\(verb)已取消"
            tone = .warn
        default:
            title = "\(verb)进行中"
            tone = .ok
        }
        let hint = timedOut && (action == .stop || action == .restart) ? "可继续等待，或强制停止。" : nil
        let sourceNote: String? = source == .ui ? nil : "来源 \(source.rawValue)"
        return OperationSummary(title: title, items: items, tone: tone, hint: hint, sourceNote: sourceNote)
    }
}

// MARK: - Force stop confirmation

public enum ForceStopText {
    /// "将向「后端」本次运行的 3 个受管进程发送 SIGKILL，可能丢失未保存的数据。"
    ///
    /// - Parameters:
    ///   - names: names of the targeted services that have a current run.
    ///   - processCount: total verified processes, nil when unknown ("全部受管进程").
    ///   - multiServiceProject: name the service only when the project has more than one.
    public static func message(names: [String], processCount: Int?, multiServiceProject: Bool) -> String {
        let what = processCount.map { $0 > 0 ? "\($0) 个受管进程" : "全部受管进程" } ?? "全部受管进程"
        let who = names.count == 1 && multiServiceProject ? "「\(names[0])」" : ""
        return "将向\(who)本次运行的 \(what)发送 SIGKILL，可能丢失未保存的数据。"
    }

    public static let note = "只会作用于能核验属于本次运行的进程（PID + 启动时间一致）。"
}
