import Foundation

// Status language (ui-design v1 §3, v2 §3), ported from apps/ui/src/lib/status.ts.
// Process state stays separate from readiness evidence; color is secondary to glyph + text.

/// Semantic color of a status; views map it to theme colors.
public enum DisplayTone: Sendable, Equatable {
    case gray, blue, green, amber, amberStrong, red, purple
}

public enum StatusGlyph: Sendable, Equatable {
    case idle, starting, running, stopping, stopped, exited, failed, unknown, partial

    /// Text glyph used in pills and badges (as in docs/ui-mockup-v2.html).
    public var symbol: String {
        switch self {
        case .idle: "○"
        case .starting: "◔"
        case .running: "●"
        case .stopping: "◑"
        case .stopped, .exited: "■"
        case .failed: "▲"
        case .unknown: "?"
        case .partial: "◐"
        }
    }
}

public struct StatusLabel: Sendable, Equatable {
    public var glyph: StatusGlyph
    public var text: String
    public var tone: DisplayTone

    public init(glyph: StatusGlyph, text: String, tone: DisplayTone) {
        self.glyph = glyph
        self.text = text
        self.tone = tone
    }
}

// MARK: - Errors and exits

extension ApiError {
    /// Short human text ("命令不存在 pnpm（PATH 中未找到）", "启动期间退出（1）", …).
    public var displayText: String {
        switch code {
        case .commandNotFound:
            if let program = details?["program"]?.stringValue { return "命令不存在 \(program)（PATH 中未找到）" }
            return message
        case .cwdUnavailable:
            if let cwd = details?["cwd"]?.stringValue { return "工作目录不可用 \(cwd)" }
            return message
        case .exitedDuringStart:
            if let code = details?["code"]?.intValue { return "启动期间退出（\(code)）" }
            if let signal = details?["signal"]?.stringValue { return "启动期间被 \(signal) 结束" }
            return "启动期间退出"
        case .stopTimeout:
            return message.isEmpty ? "旧进程未停止" : message
        case .stateUnverifiable:
            return "状态无法核验，已阻止启动"
        case .operationCancelled:
            return "已被停止操作取消"
        case .daemonUnreachable:
            return "无法连接管理服务"
        default:
            return message.isEmpty ? code.rawValue : message
        }
    }
}

extension ExitInfo {
    /// "退出（1）", "信号 SIGKILL", "管理服务中断，运行已丢失"; nil when nothing is known.
    public var displayText: String? {
        if reason == .daemonLost { return "管理服务中断，运行已丢失" }
        if let code { return "退出（\(code)）" }
        if let signal { return "信号 \(signal)" }
        return nil
    }
}

// MARK: - Services

extension ServiceState {
    /// idle / stopped / exited / failed: "▶ 启动" applies.
    public var isStartable: Bool {
        switch self {
        case .idle, .stopped, .exited, .failed: true
        default: false
        }
    }

    /// starting / running / stopping / unknown: "■ 停止" applies.
    public var isStoppable: Bool { isActive || self == .unknown }
}

extension ServiceView {
    /// Reason summary for a failed service.
    public var failureReason: String {
        if let error { return error.displayText }
        return lastRun?.exit?.displayText ?? "原因未知"
    }

    /// Seconds spent in the current state (nil when `stateSince` is missing).
    public func secondsInState(now: Date) -> Int? {
        guard let since = Timestamps.date(stateSince) else { return nil }
        return max(0, Int(now.timeIntervalSince(since).rounded(.down)))
    }

    /// Status pill: "● 运行中", "◑ 尚未停止 · 12 秒", "▲ 异常 · 退出（1）", …
    public func status(now: Date) -> StatusLabel {
        switch state {
        case .idle: return StatusLabel(glyph: .idle, text: "未启动", tone: .gray)
        case .starting: return StatusLabel(glyph: .starting, text: "启动中", tone: .blue)
        case .running: return StatusLabel(glyph: .running, text: "运行中", tone: currentRun?.ready?.processTone ?? .blue)
        case .stopping:
            let waited = secondsInState(now: now)
            if stopTimedOut {
                return StatusLabel(
                    glyph: .stopping, text: waited.map { "尚未停止 · \($0) 秒" } ?? "尚未停止", tone: .amberStrong)
            }
            return StatusLabel(glyph: .stopping, text: waited.map { "停止中 · \($0) 秒" } ?? "停止中", tone: .amber)
        case .stopped:
            return StatusLabel(glyph: .stopped, text: "已停止", tone: .gray)
        case .exited:
            if let code = lastRun?.exit?.code { return StatusLabel(glyph: .exited, text: "已退出（\(code)）", tone: .gray) }
            return StatusLabel(glyph: .exited, text: "已退出", tone: .gray)
        case .failed:
            return StatusLabel(glyph: .failed, text: "异常 · \(failureReason)", tone: .red)
        case .unknown:
            return StatusLabel(glyph: .unknown, text: "状态未知", tone: .purple)
        case .other(let raw):
            return StatusLabel(glyph: .unknown, text: raw, tone: .gray)
        }
    }
}

/// The small line under a service name in the overview.
public struct ServiceNote: Sendable, Equatable {
    public enum Tone: Sendable, Equatable { case warning, negative, muted }
    public var text: String
    public var tone: Tone

    public init(_ text: String, _ tone: Tone) {
        self.text = text
        self.tone = tone
    }
}

extension ServiceView {
    /// "选项已修改 · 下次启动生效", "退出（1）· 10:42", "已强制停止 · 昨天 18:02", … or nil.
    ///
    /// - Parameter paramChanged: a param this service references changed after its current run
    ///   started (see `ParamChip.pending`); picks "选项已修改" over the generic "配置已修改".
    public func note(paramChanged: Bool, now: Date, calendar: Calendar = .current) -> ServiceNote? {
        if currentRun != nil, configChangedSinceStart {
            return ServiceNote(paramChanged ? "选项已修改 · 下次启动生效" : "配置已修改 · 下次启动生效", .warning)
        }
        func at(_ ts: Timestamp?) -> String {
            Timestamps.date(ts).map { " · " + Format.dayTime($0, now: now, calendar: calendar) } ?? ""
        }
        switch state {
        case .failed:
            let exit = lastRun?.exit
            let what: String
            if exit?.reason == .spawnFailed {
                what = "启动失败"
            } else if let text = exit?.displayText {
                what = text
            } else if let error {
                what = error.displayText
            } else {
                what = "异常结束"
            }
            return ServiceNote(what + at(lastRun?.endedAt ?? exit?.at), .negative)
        case .exited, .stopped:
            guard let exit = lastRun?.exit else { return nil }
            switch exit.reason {
            case .selfExit: return ServiceNote((exit.displayText ?? "已退出") + at(exit.at), .muted)
            case .forceStop: return ServiceNote("已强制停止" + at(exit.at), .muted)
            case .daemonLost: return ServiceNote("管理服务中断，运行已丢失" + at(exit.at), .negative)
            default: return nil
            }
        case .unknown:
            return ServiceNote(error?.displayText ?? "状态无法核验", .negative)
        default:
            return nil
        }
    }
}

// MARK: - Projects

extension ProjectView {
    private var runningTone: DisplayTone {
        let active = services.filter { $0.state == .running }
        if services.contains(where: { $0.state == .failed }) { return .amberStrong }
        if active.contains(where: { $0.currentRun?.ready?.processTone == .amberStrong }) { return .amberStrong }
        if active.contains(where: { $0.currentRun?.ready?.processTone == .purple }) { return .purple }
        return !active.isEmpty && active.allSatisfy { $0.currentRun?.ready?.state == .ready } ? .green : .blue
    }
    /// Header badge: "2/2 运行中", "部分运行 1/2", "停止中", "异常", "已停止", "未启动", "状态未知".
    public func badge() -> StatusLabel {
        let n = "\(runningCount)/\(serviceCount)"
        switch aggregate {
        case .running: return StatusLabel(glyph: .running, text: "\(n) 运行中", tone: runningTone)
        case .partial: return StatusLabel(glyph: .partial, text: "部分运行 \(n)", tone: runningTone)
        case .transition:
            if let s = services.first(where: { $0.state == .stopping }) {
                return s.stopTimedOut
                    ? StatusLabel(glyph: .stopping, text: "尚未停止", tone: .amberStrong)
                    : StatusLabel(glyph: .stopping, text: "停止中", tone: .amber)
            }
            return StatusLabel(glyph: .starting, text: "启动中", tone: .blue)
        case .failed: return StatusLabel(glyph: .failed, text: "异常", tone: .red)
        case .stopped: return StatusLabel(glyph: .stopped, text: "已停止", tone: .gray)
        case .idle: return StatusLabel(glyph: .idle, text: "未启动", tone: .gray)
        case .unknown: return StatusLabel(glyph: .unknown, text: "状态未知", tone: .purple)
        case .other(let raw): return StatusLabel(glyph: .unknown, text: raw, tone: .gray)
        }
    }

    /// Which project-level buttons apply (v1 rules).
    public var availableActions: ActionAvailability {
        ActionAvailability(
            start: services.contains { $0.state.isStartable },
            stop: services.contains { $0.state.isStoppable },
            restart: services.contains { $0.state == .running },
            forceStop: services.contains { $0.state == .stopping && $0.stopTimedOut })
    }

    public func service(_ id: ServiceID) -> ServiceView? { services.first { $0.id == id } }
}

extension ServiceView {
    public var availableActions: ActionAvailability {
        ActionAvailability(
            start: state.isStartable,
            stop: state.isStoppable,
            restart: state == .running,
            forceStop: state == .stopping && stopTimedOut)
    }
}

public struct ActionAvailability: Sendable, Equatable {
    public var start: Bool
    public var stop: Bool
    public var restart: Bool
    /// Stop timed out: offer "强制停止" (red, confirmed) instead of "■".
    public var forceStop: Bool

    public init(start: Bool, stop: Bool, restart: Bool, forceStop: Bool) {
        self.start = start
        self.stop = stop
        self.restart = restart
        self.forceStop = forceStop
    }

    public static let none = ActionAvailability(start: false, stop: false, restart: false, forceStop: false)
}
