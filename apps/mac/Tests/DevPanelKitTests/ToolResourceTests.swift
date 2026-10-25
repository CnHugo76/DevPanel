import Foundation
import Observation
import Testing

@testable import DevPanelKit

@Suite("Tool resource accounting")
struct ToolResourceTests {
    let now = Date(timeIntervalSince1970: 1_792_540_800)

    func sample(cpu: Double? = 1, rss: Int? = 100, footprint: Int? = 200,
                status: SampleStatus = .ok, age: TimeInterval = 0) -> ResourceSample {
        ResourceSample(status: status, sampledAt: Timestamps.string(now.addingTimeInterval(-age)),
                       cpuPercent: cpu, rssBytes: rss, footprintBytes: footprint, processCount: 1)
    }

    func daemon() throws -> DaemonInfo {
        var info = try Fixture.decode(DaemonInfo.self, "recorded-real/daemon-info.json")
        info.selfUsage = sample(cpu: 2)
        info.toolResources = DaemonToolResources(daemon: sample(cpu: 2), helpers: sample(cpu: 3),
            total: sample(cpu: 5, rss: 200, footprint: 400))
        return info
    }

    @Test func optionalContractAndRoundTrip() throws {
        let old = try Fixture.decode(DaemonInfo.self, "recorded-real/daemon-info.json")
        #expect(old.toolResources == nil)
        let info = try daemon()
        let encoded = try JSONEncoder().encode(info)
        let decoded = try ContractCoding.decoder().decode(DaemonInfo.self, from: encoded)
        #expect(decoded.toolResources == info.toolResources)
        #expect(decoded.selfUsage == info.selfUsage)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(json["toolResources"] != nil)
        #expect(json["self"] != nil)
    }

    @Test func totalUsesAppAndBackendTotalOnce() throws {
        let result = ToolResourceReadout.make(interface: sample(), backend: try daemon(), connected: true, now: now)
        #expect(result.total.cpuPercent == 6)
        #expect(result.total.footprintBytes == 600)
        #expect(result.total.rssBytes == 300)
        #expect(result.notice == nil)
        #expect(result.daemon.cpuPercent == 2)
        #expect(result.helpers.cpuPercent == 3)
    }

    @Test func neverMixesMemoryDefinitions() {
        let mixed = ToolResourceReadout.sum([sample(), sample(rss: 400, footprint: nil)], now: now)
        #expect(mixed.footprintBytes == nil)
        #expect(mixed.rssBytes == 500)
        #expect(Metrics.memory(mixed, active: true).text.hasSuffix(" RSS"))
        let incompatible = ToolResourceReadout.sum([sample(rss: nil), sample(footprint: nil)], now: now)
        #expect(incompatible.footprintBytes == nil)
        #expect(incompatible.rssBytes == nil)
        #expect(Metrics.memory(incompatible, active: true).text == "不可用")
    }

    @Test func missingHelperSupportAndDisconnectKeepKnownRowsButNoFalseTotal() throws {
        var info = try daemon()
        info.toolResources = nil
        let old = ToolResourceReadout.make(interface: sample(), backend: info, connected: true, now: now)
        #expect(old.daemon.cpuPercent == 2)
        #expect(old.helpers.status == .unavailable)
        #expect(old.helpers.note?.contains("不支持") == true)
        #expect(old.total.cpuPercent == nil && old.total.footprintBytes == nil)
        let offline = ToolResourceReadout.make(interface: sample(), backend: try daemon(), connected: false, now: now)
        #expect(offline.interface.cpuPercent == 1)
        #expect(offline.daemon.cpuPercent == nil)
        #expect(offline.total.rssBytes == nil)
        #expect(offline.notice == "部分不可用")
    }

    @Test func incompleteBackendNeverProducesACompleteTotal() throws {
        var info = try daemon()
        info.toolResources?.total = sample(cpu: 2, status: .partial)
        let result = ToolResourceReadout.make(interface: sample(), backend: info, connected: true, now: now)
        #expect(result.total.cpuPercent == nil)
        #expect(result.total.footprintBytes == nil)
        #expect(result.daemon.footprintBytes == 200)
        #expect(result.notice == "部分不可用")
    }

    @Test func staleAfterSixSecondsAndUnknownCPUIsNotZero() throws {
        let result = ToolResourceReadout.make(interface: sample(age: 6.01), backend: try daemon(), connected: true, now: now)
        #expect(result.interface.status == .unavailable)
        #expect(result.total.cpuPercent == nil)
        #expect(result.notice?.contains("过期") == true)
        #expect(ToolResourceReadout.sum([sample(age: 6), sample()], now: now).cpuPercent == 2)
        let first = ToolResourceReadout.sum([sample(cpu: nil, status: .sampling), sample()], now: now)
        #expect(first.status == .sampling)
        #expect(first.cpuPercent == nil)
        #expect(first.footprintBytes == 400)
    }

    @Test func cpuUsesMachTimebaseAndSingleCorePercent() {
        #expect(ProcessCPU.nanoseconds(ticks: 24, numerator: 125, denominator: 3) == 1000)
        #expect(ProcessCPU.percent(cpuTicks: 200, previousCPUTicks: 100, wallTicks: 400,
            previousWallTicks: 200, numerator: 125, denominator: 3) == 50)
        #expect(ProcessCPU.percent(cpuTicks: 800, previousCPUTicks: 100, wallTicks: 400,
            previousWallTicks: 200, numerator: 125, denominator: 3) == 350)
        #expect(ProcessCPU.percent(cpuTicks: 1, previousCPUTicks: 2, wallTicks: 4,
            previousWallTicks: 3, numerator: 1, denominator: 1) == nil)
        #expect(ProcessCPU.nanoseconds(ticks: 1, numerator: 1, denominator: 0) == nil)
    }

    @Test func lateRepliesCannotCrossReconnectsOrDaemonRestarts() throws {
        var info = try daemon()
        let identity = ToolResourceConnection(generation: 1, pid: info.pid, startedAt: info.startedAt)
        #expect(identity.accepts(info, current: identity))
        #expect(!identity.accepts(info, current: nil))
        #expect(!identity.accepts(info, current: ToolResourceConnection(generation: 2, pid: info.pid, startedAt: info.startedAt)))
        info.pid += 1
        #expect(!identity.accepts(info, current: identity))
        info.pid -= 1
        info.startedAt = "2026-10-22T00:00:00Z"
        #expect(!identity.accepts(info, current: identity))
    }

    @Test @MainActor func oneMonitorSamplesLocallyAndStops() async throws {
        let model = AppModel(environment: .init(discover: { nil }, makeClient: { DaemonClient(discovery: $0) }))
        // Starting just before an even second permits a second sample within 100ms.
        let clock = ManualToolResourceClock(now: now.addingTimeInterval(1.9375))
        var events = clock.events.makeAsyncIterator()
        let monitor = ToolResourceMonitor(timing: clock.timing)
        defer { monitor.stop() }
        monitor.start(model: model)
        monitor.start(model: model)
        monitor.setVisible(true, model: model)
        #expect(await events.next() == .sleeping(.seconds(0.0625)))
        let first = try #require(monitor.interface)
        #expect(first.processCount == 1)
        #expect(first.footprintBytes != nil)
        #expect(first.cpuPercent == nil)
        #expect(first.sampledAt == Timestamps.string(clock.now))
        #expect(clock.sleeps.count == 1) // repeated start/visible calls share one loop

        clock.advance(by: 0.03125)
        #expect(monitor.interface == first)
        clock.advance(by: 0.03125)
        #expect(await events.next() == .sleeping(.seconds(2)))
        let second = try #require(monitor.interface)
        #expect(second.sampledAt == Timestamps.string(clock.now))
        #expect(second.cpuPercent != nil)
        monitor.stop()
        #expect(await events.next() == .cancelled)
        clock.advance(by: 10)
        #expect(monitor.interface == second)
        #expect(clock.sleeps.count == 2)
        #expect(!monitor.backendAvailable)
    }

    @Test @MainActor func hiddenMonitorPausesSamplesAndRequestsAndResumesImmediately() async throws {
        let stream = try FakeDaemon().connectedStream()
        let (requests, requestContinuation) = AsyncStream<Void>.makeStream()
        var requestEvents = requests.makeAsyncIterator()
        let info = try Fixture.data("recorded/daemon-info.json")
        let transport = FakeTransport(handler: { request in
            if request.url?.path == "/api/v1/daemon" {
                requestContinuation.yield(())
                return (200, info)
            }
            return (404, Data())
        }, stream: { _ in stream })
        let model = AppModel(environment: .init(discover: { testDiscovery }, makeClient: {
            DaemonClient(discovery: $0, transport: transport)
        }))
        defer { model.stop() }
        let (connections, connectionContinuation) = AsyncStream<Void>.makeStream()
        var connectionEvents = connections.makeAsyncIterator()
        withObservationTracking { _ = model.isConnected } onChange: { connectionContinuation.yield(()) }
        model.start()
        await connectionEvents.next()
        #expect(model.isConnected)

        let clock = ManualToolResourceClock(now: now.addingTimeInterval(1.9375))
        var events = clock.events.makeAsyncIterator()
        let monitor = ToolResourceMonitor(timing: clock.timing)
        defer { monitor.stop() }
        monitor.setVisible(false, model: model)
        monitor.start(model: model)
        #expect(monitor.interface == nil && clock.sleeps.isEmpty)
        monitor.setVisible(true, model: model)
        monitor.start(model: model)
        #expect(await events.next() == .sleeping(.seconds(0.0625)))
        await requestEvents.next()
        #expect(clock.sleeps.count == 1)
        monitor.setVisible(false, model: model)
        #expect(await events.next() == .cancelled)
        let first = monitor.interface
        let count = transport.requests.current.filter { $0.url?.path == "/api/v1/daemon" }.count
        clock.advance(by: 10)
        #expect(monitor.interface == first)
        #expect(transport.requests.current.filter { $0.url?.path == "/api/v1/daemon" }.count == count)
        #expect(clock.sleeps.count == 1)

        monitor.setVisible(true, model: model)
        monitor.setVisible(true, model: model)
        #expect(await events.next() == .sleeping(.seconds(0.0625)))
        await requestEvents.next()
        #expect(monitor.interface != first)
        #expect(monitor.interface?.sampledAt == Timestamps.string(clock.now))
        #expect(monitor.interface?.cpuPercent == nil) // resume resets the CPU baseline
        #expect(transport.requests.current.filter { $0.url?.path == "/api/v1/daemon" }.count == count + 1)
        #expect(clock.sleeps.count == 2)
        monitor.stop()
        #expect(await events.next() == .cancelled)
        let stopped = monitor.interface
        monitor.setVisible(false, model: model)
        monitor.setVisible(true, model: model)
        clock.advance(by: 10)
        #expect(monitor.interface == stopped && clock.sleeps.count == 2)
    }
}

/// Explicit deadlines and cancellation handshakes; no wall-time sleeps in monitor tests.
@MainActor private final class ManualToolResourceClock {
    enum Event: Equatable { case sleeping(Duration), cancelled }
    var now: Date
    private(set) var sleeps: [Duration] = []
    let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private var waiters: [UUID: (deadline: Date, resume: CheckedContinuation<Void, any Error>)] = [:]

    init(now: Date) {
        self.now = now
        (events, continuation) = AsyncStream.makeStream()
    }

    var timing: ToolResourceMonitor.Timing {
        .init(now: { self.now }, sleep: { try await self.sleep(for: $0) })
    }

    private func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { resume in
                let parts = duration.components
                let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
                waiters[id] = (now.addingTimeInterval(seconds), resume)
                sleeps.append(duration)
                continuation.yield(.sleeping(duration))
            }
        } onCancel: {
            Task { @MainActor in
                if let waiter = self.waiters.removeValue(forKey: id) {
                    waiter.resume.resume(throwing: CancellationError())
                    self.continuation.yield(.cancelled)
                }
            }
        }
    }

    func advance(by seconds: TimeInterval) {
        now.addTimeInterval(seconds)
        for (id, waiter) in waiters where waiter.deadline <= now {
            waiters.removeValue(forKey: id)
            waiter.resume.resume()
        }
    }
}
