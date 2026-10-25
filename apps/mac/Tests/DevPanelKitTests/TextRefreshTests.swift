import Foundation
import Observation
import Testing
@testable import DevPanelKit

@Suite("Text refresh precision") struct TextRefreshTests {
    let start = Date(timeIntervalSince1970: 0)
    @Test(arguments: [(0.0, 1.0), (59, 60), (3599, 3600), (3600, 3660),
                      (86340, 86400), (86400, 90000)])
    func durationBoundaries(age: Double, next: Double) {
        let now = start.addingTimeInterval(age)
        let refresh = TextRefresh.duration(since: start).next(after: now)
        #expect(refresh == start.addingTimeInterval(next))
        #expect(Format.duration(age) != Format.duration(next))
        #expect(Format.duration(age) == Format.duration(next - 0.001))
    }
    @Test func fractionalStartAndAlignment() {
        let rule = TextRefresh.duration(since: start.addingTimeInterval(0.25))
        #expect(rule.next(after: start.addingTimeInterval(59.5)) == start.addingTimeInterval(60.25))
        #expect(TextRefresh.alignedNext([rule], after: start.addingTimeInterval(59.5)) == start.addingTimeInterval(61))
        #expect(TextRefresh.alignedNext([], after: start) == nil)
    }
    @Test func dayBoundaryAndDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 0)))
        let next = try #require(calendar.date(byAdding: .day, value: 1, to: date))
        #expect(next.timeIntervalSince(date) == 23 * 3600)
        let rule = TextRefresh.days([date])
        #expect(rule.next(after: next.addingTimeInterval(-1), calendar: calendar) == next)
        #expect(Format.dayTime(date, now: next.addingTimeInterval(-1), calendar: calendar) != Format.dayTime(date, now: next, calendar: calendar))
        let last = try #require(calendar.date(byAdding: .day, value: 2, to: date))
        #expect(rule.next(after: next, calendar: calendar) == last)
        #expect(rule.next(after: last, calendar: calendar) == nil)
        #expect(TextRefresh.days([]).next(after: date, calendar: calendar) == nil)
    }
    @Test(arguments: [(0.0, 0.5), (59.0, 59.5), (60, 119.5), (3599.5, 7199.5), (86400, 172799.5)])
    func agoRounding(age: Double, next: Double) {
        #expect(TextRefresh.ago(since: start).next(after: start.addingTimeInterval(age)) == start.addingTimeInterval(next))
        #expect(Format.ago(age) != Format.ago(next))
    }
    @Test func quietThresholdAndCountdown() {
        #expect(TextRefresh.ago(since: start, quietAfter: 60).next(after: start.addingTimeInterval(5)) == start.addingTimeInterval(60.001))
        #expect(TextRefresh.once(at: start).next(after: start) == nil)
        #expect(TextRefresh.once(at: start.addingTimeInterval(1)).next(after: start) == start.addingTimeInterval(1))
        let end = start.addingTimeInterval(10.5)
        #expect(TextRefresh.countdown(until: end).next(after: start.addingTimeInterval(7)) == start.addingTimeInterval(7.5))
        #expect(TextRefresh.countdown(until: end).next(after: end) == nil)
    }
}

@MainActor @Suite("Scoped stats observation") struct ScopedStatsTests {
    @Test func statsDoNotInvalidateProjectOrOptionSummary() throws {
        let model = AppModel(environment: .init(discover: { nil }, makeClient: { DaemonClient(discovery: $0) }))
        let event = try Fixture.decode(DaemonEvent.self, "recorded/event-snapshot.json")
        model.apply(event)
        model.storeConfig(try Fixture.decode(Project.self, "recorded/project-order-service.json"))
        let changedProject = Locked(false), changedOptions = Locked(false)
        withObservationTracking { _ = model.projects } onChange: { changedProject.withLock { $0 = true } }
        withObservationTracking { _ = model.paramGroups("p_ordersvc2a").flatMap(\.chips).filter(\.pending).count }
            onChange: { changedOptions.withLock { $0 = true } }
        var stats = try #require(model.stats)
        stats.sampledAt = "next"
        stats.projects["p_ordersvc2a"]?.total.cpuPercent = 99
        stats.projects["p_ordersvc2a"]?.services["backend"]?.cpuPercent = 98
        model.apply(.stats(stats))
        #expect(!changedProject.current && !changedOptions.current)
    }

    @Test func updatesOnlyChangedServiceAndTotals() {
        let model = AppModel(environment: .init(discover: { nil }, makeClient: { DaemonClient(discovery: $0, transport: FakeTransport()) }))
        let a = ServiceStats(runId: "a", status: .ok, cpuPercent: 1, rssBytes: 1024)
        let b = ServiceStats(runId: "b", status: .ok, cpuPercent: 2, rssBytes: 2048)
        var snapshot = StatsSnapshot(sampledAt: "now", intervalMs: 2000, projects: [
            "p": ProjectStats(total: ResourceSample(status: .ok, cpuPercent: 3), services: ["a": a, "b": b]),
            "q": ProjectStats(total: ResourceSample(status: .ok, cpuPercent: 0), services: [:])])
        model.apply(.stats(snapshot))
        let changedA = Locked(false), changedB = Locked(false), changedP = Locked(false), changedQ = Locked(false)
        withObservationTracking { _ = model.serviceStats("p", "a") } onChange: { changedA.withLock { $0 = true } }
        withObservationTracking { _ = model.serviceStats("p", "b") } onChange: { changedB.withLock { $0 = true } }
        withObservationTracking { _ = model.projectStats("p") } onChange: { changedP.withLock { $0 = true } }
        withObservationTracking { _ = model.projectStats("q") } onChange: { changedQ.withLock { $0 = true } }
        snapshot.projects["p"]?.services["a"]?.cpuPercent = 4
        snapshot.projects["p"]?.total.cpuPercent = 6
        model.apply(.stats(snapshot))
        #expect(changedA.current && changedP.current)
        #expect(!changedB.current && !changedQ.current)
    }
    @Test func identicalDisplayDoesNotNotifyButKeepsLatestSample() {
        let store = ServiceStatsStore()
        var sample = ServiceStats(runId: "a", status: .ok, sampledAt: "first", cpuPercent: 0.001, rssBytes: 1024)
        store.update(sample)
        let changed = Locked(false)
        withObservationTracking { _ = store.value } onChange: { changed.withLock { $0 = true } }
        sample.sampledAt = "second"; sample.cpuPercent = 0.002
        store.update(sample)
        #expect(!changed.current)
        #expect(store.value?.sampledAt == "second")
        sample.status = .unavailable
        store.update(sample)
        #expect(changed.current)
    }
    @Test func ordinaryStreamTrafficDoesNotInvalidateConnectionFlags() async throws {
        let daemon = FakeDaemon()
        let stream = try daemon.connectedStream()
        daemon.enqueue(.stream(stream))
        let model = AppModel(environment: .init(discover: { testDiscovery }, makeClient: {
            DaemonClient(discovery: $0, transport: daemon.transport)
        }))
        model.start()
        defer { model.stop() }
        await eventually { model.isConnected }
        let changed = Locked(false)
        withObservationTracking { _ = model.isConnected; _ = model.isStale } onChange: { changed.withLock { $0 = true } }
        let before = model.connection.lastEventAt
        try stream.sendEvent(fixture: "recorded/event-ping.json")
        await eventually { model.connection.lastEventAt != before }
        #expect(!changed.current)
        stream.finish(throwing: URLError(.networkConnectionLost))
        await eventually { !model.isConnected }
        #expect(changed.current)
        #expect(model.isStale)
    }

}
