import Foundation
import Testing
@testable import DevPanelKit

@Suite("操作来源与动态") struct ActivityTests {
    @Test func actorLabelsAndOldRecords() throws {
        #expect(Actor(client: .ui).displayName == "你")
        #expect(Actor(client: .cli, agent: "claude-code").displayName == "Claude Code")
        #expect(Actor(client: .cli, agent: "codex").displayName == "Codex")
        #expect(Actor(client: .cli).displayName == "命令行")
        #expect(Actor(client: .daemon).displayName == "DevPanel")
        let runs = try Fixture.decode([RunSummary].self, "recorded/runs.json")
        #expect(runs.allSatisfy { $0.startedBy == nil })
    }
    @Test func activityMasksAndRunNavigation() throws {
        let data = Data(#"{"entries":[{"id":"a_1","projectId":"p_1","at":"2026-10-22T10:00:00Z","actor":{"client":"cli","agent":"codex"},"detail":{"kind":"operation","operationId":"op_1","action":"start","serviceIds":["web"],"state":"succeeded","results":[{"serviceId":"web","outcome":"started","runId":"r_1","errorCode":null}],"overrideHold":true}}],"hasMore":false}"#.utf8)
        let page = try ContractCoding.decoder().decode(ActivityPage.self, from: data)
        #expect(page.entries[0].title.contains("越过了你的暂停"))
        #expect(page.entries[0].runIds == ["r_1"])
    }
}

@MainActor @Suite("动态刷新") struct ActivityRefreshTests {
    @Test func visibleEventsCoalesceAndHiddenDoesNotRead() async throws {
        let daemon = FakeDaemon()
        let stream = try daemon.connectedStream()
        daemon.enqueue(.stream(stream))
        daemon.transport.setHandler { _ in (200, Data(#"{"entries":[],"hasMore":false}"#.utf8)) }
        let model = AppModel(environment: .init(discover: { testDiscovery }, makeClient: { DaemonClient(discovery: $0, transport: daemon.transport) }))
        model.start()
        defer { model.stop() }
        await eventually { model.isConnected }
        let project = try #require(model.projects.first)
        func reads() -> Int { daemon.transport.requests.current.filter { $0.url?.path.hasSuffix("/activity") == true }.count }
        model.apply(.projectUpsert(project))
        try await Task.sleep(for: .milliseconds(100))
        #expect(reads() == 0)
        model.activityVisible = project.id
        for _ in 0..<10 { model.apply(.projectUpsert(project)) }
        await eventually { reads() == 1 }
        try await Task.sleep(for: .milliseconds(120))
        #expect(reads() == 1)
        model.activityVisible = nil
        model.apply(.projectUpsert(project))
        try await Task.sleep(for: .milliseconds(120))
        #expect(reads() == 1)
    }
}

struct ConfigConflictPathTests {
    @Test func decodesPathDiffsAndKeepsSecretMarkers() throws {
        let json = #"{"code":"CONFIG_CONFLICT","message":"conflict","details":{"diff":[{"path":"name","existing":"old","incoming":"new"},{"path":"env.TOKEN","existing":{"secret":true},"incoming":{"secret":true}},{"path":"services[0].command[1]","existing":null,"incoming":"--flag"}]}}"#
        let error = try JSONDecoder().decode(ApiError.self, from: Data(json.utf8))
        let diff = try #require(error.configDiff)
        #expect(diff.map(\.path) == ["name", "env.TOKEN", "services[0].command[1]"])
        #expect(diff[1].summary.contains(#"{"secret":true}"#))
    }
}
