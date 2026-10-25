import Darwin
import Foundation
import Observation

/// Mach CPU and wall counters use the same timebase, including Apple Silicon's non-1:1 ticks.
public enum ProcessCPU {
    public static func nanoseconds(ticks: UInt64, numerator: UInt32, denominator: UInt32) -> Double? {
        guard denominator > 0 else { return nil }
        return Double(ticks) * Double(numerator) / Double(denominator)
    }

    public static func percent(cpuTicks: UInt64, previousCPUTicks: UInt64, wallTicks: UInt64,
                               previousWallTicks: UInt64, numerator: UInt32, denominator: UInt32) -> Double? {
        guard cpuTicks >= previousCPUTicks, wallTicks > previousWallTicks,
              let cpu = nanoseconds(ticks: cpuTicks - previousCPUTicks, numerator: numerator, denominator: denominator),
              let wall = nanoseconds(ticks: wallTicks - previousWallTicks, numerator: numerator, denominator: denominator),
              wall > 0 else { return nil }
        return cpu / wall * 100
    }
}

/// Queries only this UI process; no process listing or helper process is spawned.
struct InterfaceResourceSampler {
    private var previous: (cpu: UInt64, wall: UInt64)?
    private var timebase: mach_timebase_info_data_t = {
        var value = mach_timebase_info_data_t()
        mach_timebase_info(&value)
        return value
    }()

    mutating func sample(now: Date) -> ResourceSample {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else {
            previous = nil
            return ResourceSample(status: .unavailable, sampledAt: Timestamps.string(now), note: "无法读取界面进程")
        }
        let cpu = usage.ri_user_time &+ usage.ri_system_time
        let wall = mach_absolute_time()
        let percent = previous.flatMap {
            ProcessCPU.percent(cpuTicks: cpu, previousCPUTicks: $0.cpu, wallTicks: wall,
                               previousWallTicks: $0.wall, numerator: timebase.numer, denominator: timebase.denom)
        }
        previous = (cpu, wall)
        return ResourceSample(status: percent == nil ? .sampling : .ok, sampledAt: Timestamps.string(now),
                              cpuPercent: percent, rssBytes: Int(exactly: usage.ri_resident_size),
                              footprintBytes: Int(exactly: usage.ri_phys_footprint), processCount: 1)
    }
}

public struct ToolResourceReadout: Codable, Sendable, Equatable {
    public var interface: ResourceSample
    public var daemon: ResourceSample
    public var helpers: ResourceSample
    public var total: ResourceSample
    public var notice: String?

    public static let staleAfter: TimeInterval = 6

    static func fresh(_ sample: ResourceSample?, now: Date, missing: String) -> ResourceSample {
        guard let sample else { return ResourceSample(status: .unavailable, note: missing) }
        guard let date = Timestamps.date(sample.sampledAt), now.timeIntervalSince(date) <= staleAfter else {
            return ResourceSample(status: .unavailable, sampledAt: sample.sampledAt, note: "数据已过期")
        }
        return sample
    }

    /// Complete components only. If a footprint is missing, RSS can be summed only when every
    /// component has RSS; we never add an RSS number to a footprint number.
    public static func sum(_ samples: [ResourceSample], now: Date) -> ResourceSample {
        guard !samples.isEmpty, samples.allSatisfy({
            $0.status == .ok || $0.status == .sampling
        }) else {
            return ResourceSample(status: .unavailable, note: "部分不可用，无法计算完整合计")
        }
        let checked = samples.map { fresh($0, now: now, missing: "采样中") }
        guard checked.allSatisfy({ $0.status != .unavailable }) else {
            return ResourceSample(status: .unavailable, note: "数据已过期，无法计算完整合计")
        }
        func sumInt(_ key: KeyPath<ResourceSample, Int?>) -> Int? {
            var total = 0
            for sample in checked {
                guard let value = sample[keyPath: key] else { return nil }
                let next = total.addingReportingOverflow(value)
                guard !next.overflow else { return nil }
                total = next.partialValue
            }
            return total
        }
        let cpuValues = checked.compactMap(\.cpuPercent)
        let cpu = cpuValues.count == checked.count ? cpuValues.reduce(0, +) : nil
        return ResourceSample(status: cpu == nil ? .sampling : .ok,
            sampledAt: checked.compactMap(\.sampledAt).min(), cpuPercent: cpu,
            rssBytes: sumInt(\.rssBytes), footprintBytes: sumInt(\.footprintBytes),
            processCount: sumInt(\.processCount))
    }

    public static func make(interface: ResourceSample?, backend: DaemonInfo?, connected: Bool,
                            backendAvailable: Bool = true, now: Date) -> ToolResourceReadout {
        let app = fresh(interface, now: now, missing: "界面采样中")
        let reason = !connected ? "管理服务未连接" : "管理服务资源暂不可用"
        let usable = connected && backendAvailable
        let daemon = fresh(usable ? (backend?.toolResources?.daemon ?? backend?.selfUsage) : nil,
                           now: now, missing: reason)
        let helpers = fresh(usable ? backend?.toolResources?.helpers : nil, now: now,
                            missing: usable && backend != nil ? "此管理服务不支持辅助进程统计" : reason)
        let backendTotal = fresh(usable ? backend?.toolResources?.total : nil, now: now, missing: reason)
        let total = sum([app, backendTotal], now: now)
        let rows = [app, daemon, helpers, backendTotal]
        let stale = rows.contains { $0.note?.contains("过期") == true }
        let incomplete = rows.contains { $0.status == .unavailable || $0.status == .partial }
        return ToolResourceReadout(interface: app, daemon: daemon, helpers: helpers, total: total,
                                   notice: stale ? "数据已过期 · 部分不可用" : incomplete ? "部分不可用" : nil)
    }
}

/// A connection identity includes a generation so an old HTTP reply cannot cross reconnects.
struct ToolResourceConnection: Equatable {
    var generation: Int
    var pid: Int
    var startedAt: Timestamp

    init(generation: Int, pid: Int, startedAt: Timestamp) {
        self.generation = generation; self.pid = pid; self.startedAt = startedAt
    }

    @MainActor init?(model: AppModel) {
        guard model.isConnected, let daemon = model.daemon else { return nil }
        generation = model.connectionGeneration; pid = daemon.pid; startedAt = daemon.startedAt
    }

    func accepts(_ daemon: DaemonInfo, current: ToolResourceConnection?) -> Bool {
        self == current && daemon.pid == pid && daemon.startedAt == startedAt
    }
}

/// Owned once by AppModel, independent of windows. Local sampling never waits for HTTP.
@Observable @MainActor
public final class ToolResourceMonitor {
    struct Timing {
        var now: @MainActor () -> Date = { Date() }
        var sleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    }

    @ObservationIgnored private let timing: Timing
    public private(set) var currentReadout = ToolResourceReadout.make(interface: nil, backend: nil, connected: false, now: Date())
    @ObservationIgnored private var enabled = false
    @ObservationIgnored private var visible = true
    public private(set) var interface: ResourceSample?
    public private(set) var backend: DaemonInfo?
    public private(set) var backendAvailable = false
    @ObservationIgnored private var sampler = InterfaceResourceSampler()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var request: Task<Void, Never>?
    @ObservationIgnored private var requestID: UUID?
    @ObservationIgnored private var acceptedConnection: ToolResourceConnection?

    public init() { timing = Timing() }
    init(timing: Timing) { self.timing = timing }

    public func start(model: AppModel) {
        enabled = true
        resume(model: model)
    }

    public func setVisible(_ visible: Bool, model: AppModel) {
        guard self.visible != visible else { return }
        self.visible = visible
        if visible { resume(model: model) } else { suspend() }
    }

    private func resume(model: AppModel) {
        guard enabled, visible, loop == nil else { return }
        loop = Task { [weak self, weak model] in
            while !Task.isCancelled {
                guard self != nil, model != nil else { return }
                if let model { self?.tick(model: model) }
                guard let now = self?.timing.now().timeIntervalSince1970,
                      let sleep = self?.timing.sleep else { return }
                let next = (floor(now / 2) + 1) * 2
                do { try await sleep(.seconds(next - now)) } catch { return }
            }
        }
    }

    public func stop() {
        enabled = false
        suspend()
    }

    private func suspend() {
        loop?.cancel(); loop = nil
        request?.cancel(); request = nil; requestID = nil
        backendAvailable = false
        sampler = InterfaceResourceSampler()
    }

    public func readout(model: AppModel, now: Date) -> ToolResourceReadout {
        ToolResourceReadout.make(interface: interface, backend: backend, connected: model.isConnected,
            backendAvailable: backendAvailable && acceptedConnection == ToolResourceConnection(model: model), now: now)
    }

    public func connectionChanged(model: AppModel) {
        refreshReadout(model: model)
    }

    private func refreshReadout(model: AppModel) {
        let next = readout(model: model, now: timing.now())
        if currentReadout != next { currentReadout = next }
    }

    private func tick(model: AppModel) {
        interface = sampler.sample(now: timing.now())
        defer { refreshReadout(model: model) }
        guard let identity = ToolResourceConnection(model: model), var client = model.client else {
            backendAvailable = false
            return
        }
        guard request == nil else { return }
        let id = UUID()
        requestID = id
        // This endpoint reads an existing sample. An unresponsive daemon must not stall the UI sampler.
        client.requestTimeout = 1.5
        request = Task { [weak self, weak model] in
            defer {
                if self?.requestID == id {
                    self?.request = nil; self?.requestID = nil
                    if let model { self?.refreshReadout(model: model) }
                }
            }
            do {
                let info = try await client.daemonInfo()
                guard !Task.isCancelled, let self, let model,
                      self.requestID == id, identity.accepts(info, current: ToolResourceConnection(model: model)) else { return }
                self.backend = info
                self.acceptedConnection = identity
                self.backendAvailable = true
            } catch {
                guard let self, self.requestID == id else { return }
                self.backendAvailable = false
            }
        }
    }
}
