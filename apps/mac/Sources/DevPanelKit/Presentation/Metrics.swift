import Foundation

// Resource and port cells (ui-design v1 §5.2 missing-value rules, v2 §3.2):
// sampling → "采样中", partial → value + "部分", unavailable → "不可用". Never show 0 for unknown.

public struct MetricText: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// A real number.
        case value
        /// "采样中" / "不可用": a known gap, shown dimmed.
        case placeholder
        /// Not running: "—".
        case none
    }

    public var text: String
    public var kind: Kind
    /// Status `partial`: show a "部分" tag next to the value.
    public var partial: Bool
    public var help: String?

    public init(_ text: String, _ kind: Kind, partial: Bool = false, help: String? = nil) {
        self.text = text
        self.kind = kind
        self.partial = partial
        self.help = help
    }

    public static let notRunning = MetricText("—", .none)
}

public enum Metrics {
    public static let cpuHelp = "受管进程 CPU 使用率之和；100% = 一个逻辑 CPU 满载，不截断"
    public static let memoryHelp = "受管进程内存占用（footprint）合计，包含系统计入进程的压缩及换出内存；与活动监视器采用相同口径。服务包含根进程及已核验子进程，项目按进程身份去重。"
    public static let rssHelp = "footprint 暂不可用，显示受管进程 RSS 之和；仅统计当前驻留内存，含共享页，可能重复计入，与活动监视器的内存口径不同。"
    static let partialHelp = "部分进程无法读取，数值偏低"

    /// The stats of the service's *current* run (stats of an older run are ignored).
    public static func currentSample(_ service: ServiceView, _ stats: ServiceStats?) -> ServiceStats? {
        guard let run = service.currentRun, let stats, stats.runId == run.id else { return nil }
        return stats
    }

    public static func cpu(_ sample: ResourceSample?, active: Bool) -> MetricText {
        guard active else { return .notRunning }
        guard let sample, sample.status != .sampling else {
            return MetricText("采样中", .placeholder, help: "首次采样需要一个采样周期")
        }
        guard sample.status != .unavailable, let cpu = sample.cpuPercent else {
            return MetricText("不可用", .placeholder, help: sample.note ?? "无法读取受管进程")
        }
        let partial = sample.status == .partial
        let help = partial ? "\(cpuHelp)\n\(sample.note ?? partialHelp)" : cpuHelp
        return MetricText(Format.cpu(cpu), .value, partial: partial, help: help)
    }

    public static func memory(_ sample: ResourceSample?, active: Bool) -> MetricText {
        guard active else { return .notRunning }
        if let sample, sample.status != .unavailable,
           let bytes = sample.footprintBytes ?? sample.rssBytes {
            let hasFootprint = sample.footprintBytes != nil
            let partial = sample.status == .partial
            var help = hasFootprint ? memoryHelp : rssHelp
            if hasFootprint, let rss = sample.rssBytes { help += "\nRSS：\(Format.bytes(rss))" }
            if partial { help += "\n\(sample.note ?? partialHelp)" }
            let text = Format.bytes(bytes) + (hasFootprint ? "" : " RSS")
            return MetricText(text, .value, partial: partial, help: help)
        }
        if sample == nil || sample?.status == .sampling {
            return MetricText("采样中", .placeholder, help: "首次采样需要一个采样周期")
        }
        return MetricText("不可用", .placeholder, help: sample?.note ?? "无法读取受管进程")
    }

    /// No new sample for more than three intervals: values are shown dimmed.
    public static func isStale(sampledAt: Timestamp?, intervalMs: Int, now: Date) -> Bool {
        guard let at = Timestamps.date(sampledAt) else { return false }
        return now.timeIntervalSince(at) > 3 * Double(max(intervalMs, 1)) / 1000
    }

    /// Run time of the current run ("1h12m"), or "—".
    public static func uptime(_ service: ServiceView, now: Date) -> MetricText {
        guard let started = Timestamps.date(service.currentRun?.startedAt) else { return .notRunning }
        return MetricText(Format.duration(now.timeIntervalSince(started)), .value)
    }
}

// MARK: - Listening ports (v1.1-B)

public struct PortChip: Sendable, Equatable, Identifiable {
    public var port: Int
    /// Some socket on this port listens on all interfaces (`scope == all`): "局域网".
    public var lan: Bool
    /// Distinct addresses for this port, in daemon order.
    public var addresses: [String]

    public var id: Int { port }
    public var url: URL { URL(string: "http://localhost:\(port)")! }

    public var help: String {
        let listen = addresses.map { Self.hostPort($0, port) }.joined(separator: "、")
        let reach = lan ? "监听所有网卡，同一网络的其他设备也能访问" : "监听 \(listen)"
        return "\(reach)\n点击在浏览器打开 http://localhost:\(port)"
    }

    static func hostPort(_ address: String, _ port: Int) -> String {
        address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)"
    }
}

public enum PortCell: Sendable, Equatable {
    /// No current run: "—".
    case notRunning
    /// `listening == nil`: not read this cycle / older daemon: "—" with an explanation.
    case unknown
    /// `[]`: confirmed no TCP LISTEN socket.
    case none
    case ports([PortChip])

    public var help: String? {
        switch self {
        case .notRunning: nil
        case .unknown: "端口读取中 / 不可用"
        case .none: "受管进程没有监听 TCP 端口"
        case .ports: nil
        }
    }

    /// Deduplicates by port (IPv4 + IPv6 sockets of one server are one chip), sorted by port.
    public static func make(_ listening: [ListeningPort]?, active: Bool) -> PortCell {
        guard active else { return .notRunning }
        guard let listening else { return .unknown }
        if listening.isEmpty { return .none }
        var byPort: [Int: PortChip] = [:]
        for l in listening {
            var chip = byPort[l.port] ?? PortChip(port: l.port, lan: false, addresses: [])
            if l.scope == .all { chip.lan = true }
            if !chip.addresses.contains(l.address) { chip.addresses.append(l.address) }
            byPort[l.port] = chip
        }
        return .ports(byPort.values.sorted { $0.port < $1.port })
    }
}
