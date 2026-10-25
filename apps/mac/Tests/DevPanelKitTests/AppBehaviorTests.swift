import Foundation
import Testing
@testable import DevPanelKit

@Suite("Application behavior") struct AppBehaviorTests {
    func snapshot() throws -> SnapshotEvent {
        guard case .snapshot(let s) = try Fixture.decode(DaemonEvent.self, "recorded/event-snapshot.json") else { throw ApiError.unreachable() }
        return s
    }
    @Test func baselineAndReconnectDedup() throws {
        var tracker = NotificationTracker()
        let s = try snapshot()
        #expect(tracker.consume(.snapshot(s)).isEmpty)
        var p = s.projects[0]
        var run = try #require(p.services[0].currentRun)
        run.state = .failed; run.endedAt = "2026-10-20T10:00:00Z"
        run.exit = .init(reason: .selfExit, code: 1, signal: nil, at: run.endedAt!)
        p.services[0].currentRun = nil; p.services[0].lastRun = run; p.services[0].state = .failed
        let notices = tracker.consume(.projectUpsert(p))
        #expect(notices.count == 1)
        #expect(notices.first?.body == "异常退出（1）")
        #expect(notices.first?.ref == .service(ServiceRef(p.id, p.services[0].id)))
        #expect(tracker.consume(.projectUpsert(p)).isEmpty)
        var reconnect = s; reconnect.projects = [p]
        #expect(tracker.consume(.snapshot(reconnect)).isEmpty)
        p.services[0].lastRun?.id = "r_new"
        #expect(tracker.consume(.projectUpsert(p)).count == 1)
    }
    @Test(arguments: [ExitReason.userStop, .forceStop, .startCancelled, .spawnFailed, .other("future")])
    func deliberateEndsDoNotNotify(_ reason: ExitReason) throws {
        var tracker = NotificationTracker(); let s = try snapshot(); _ = tracker.consume(.snapshot(s))
        var p = s.projects[0]; var run = try #require(p.services[0].currentRun)
        run.state = .failed; run.exit = .init(reason: reason, code: 1, signal: nil, at: "now")
        p.services[0].currentRun = nil; p.services[0].lastRun = run; p.services[0].state = .failed
        #expect(tracker.consume(.projectUpsert(p)).isEmpty)
        run.state = .exited; run.exit = .init(reason: .selfExit, code: 0, signal: nil, at: "now")
        p.services[0].lastRun = run; p.services[0].state = .exited
        #expect(tracker.consume(.projectUpsert(p)).isEmpty)
    }
    @Test func unknownThenLostOnlyOnceAndBadge() throws {
        var tracker = NotificationTracker(); let s = try snapshot(); _ = tracker.consume(.snapshot(s))
        var p = s.projects[0]; p.services[0].state = .unknown
        #expect(tracker.consume(.projectUpsert(p)).count == 1)
        var run = try #require(p.services[0].currentRun)
        run.exit = .init(reason: .daemonLost, code: nil, signal: nil, at: "now"); run.state = .stopped
        p.services[0].currentRun = nil; p.services[0].lastRun = run; p.services[0].state = .stopped
        #expect(tracker.consume(.projectUpsert(p)).isEmpty)
        p.services[0].lastRun?.id = "r_lost2"
        #expect(tracker.consume(.projectUpsert(p)).count == 1)
        p.services[0].state = .unknown; p.services[1].state = .failed
        #expect(NotificationTracker.badge([p]) == 2)
        p.services[0].state = .stopped; p.services[1].state = .running
        #expect(NotificationTracker.badge([p]) == 0)
    }
    @Test func missingDaemonAfterConnectionKeepsFrozenState() {
        var state = ConnectionState()
        state.status = .notRunning
        #expect(!state.isStale)
        let known = Date(timeIntervalSince1970: 100)
        state.syncedAt = known
        #expect(state.isStale)
        #expect(state.displayNow(Date(timeIntervalSince1970: 200)) == known)
    }
    @Test func shortPathLauncherDiagnostics() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dp-launch-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("devpanel")
        let absent = DaemonLauncher(cliPath: path, environment: ["PATH": "/usr/bin:/bin"])
        do { _ = try await absent.start(); Issue.record("must fail") }
        catch { #expect(error.localizedDescription.contains("pnpm setup:cli")) }
        try Data("#!/bin/sh\necho 'fixture launch error' >&2\nexit 9\n".utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        do { _ = try await absent.start(); Issue.record("must fail") }
        catch { #expect(error.localizedDescription.contains("fixture launch error")) }
        #expect(DaemonLauncher.defaultCLIPath.path.hasSuffix("/.local/bin/devpanel"))
    }
}
