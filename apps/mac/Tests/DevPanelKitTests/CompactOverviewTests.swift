import Foundation
import Testing
@testable import DevPanelKit

@Suite("Compact project overview")
struct CompactOverviewTests {
    @Test @MainActor func attentionKeepsVisibleFailuresOnceAndPreservesGroupOrder() throws {
        let org = ProjectOrganization(defaults: nil)
        let stopped = ServiceView(id: "web", name: "Web", state: .stopped)
        let failed = ServiceView(id: "api", name: "API", state: .failed)
        func project(_ id: String, _ services: [ServiceView]) -> ProjectView {
            ProjectView(id: id, name: id, root: "/tmp/" + id, revision: 1, aggregate: .stopped,
                        runningCount: 0, serviceCount: services.count, services: services)
        }
        let projects = [project("one", [stopped]), project("two", [stopped, failed]), project("three", [stopped])]
        let group = try #require(org.createGroup("Work", projects: projects))
        for p in projects { org.moveProject(p.id, to: group, projects: projects) }
        org.toggleCollapsed(group)
        let list = CompactProjectList(sections: org.sections(projects), filter: .all)
        #expect(list.attention.map(\.id) == ["two"])
        #expect(list.sections.flatMap(\.projects).map(\.id) == ["one", "three"])
        #expect(list.otherCount == 2)
        #expect(CompactProjectList(sections: org.sections(projects), filter: .running).attention.count == 1)
        let search = CompactProjectList(sections: org.sections(projects, query: "web"), filter: .all)
        #expect(search.attention.isEmpty && search.otherCount == 3)
        #expect(org.isCollapsed(group))
    }

    @Test @MainActor func evidenceAndBrowserAddressesMustBelongToTheCurrentRun() throws {
        var run = try Fixture.decode(RunDetail.self, "recorded/run-detail.json").summary
        run.state = .running
        var service = ServiceView(id: run.serviceId, name: "前端", state: .running, currentRun: run)
        let socket = ListeningPort(port: 4100, address: "127.0.0.1", family: .ipv4, scope: .loopback, pid: 2)
        var sample = ServiceStats(runId: run.id, status: .ok, listening: [socket, socket])
        let store = ServiceStatsStore()
        store.update(sample)
        #expect(service.overviewURLs(customURL: nil, listening: store.listening(for: run.id), command: []).map(\.port) == [4100])
        sample.runId = "previous-run"
        store.update(sample)
        #expect(service.overviewURLs(customURL: nil, listening: store.listening(for: run.id), command: []).isEmpty)
        let custom = try #require(URL(string: "https://localhost:4400/app"))
        #expect(service.overviewURLs(customURL: custom, listening: nil, command: []) == [custom])
        service.state = .failed
        service.currentRun = nil
        service.lastRun = run
        #expect(service.overviewURLs(customURL: custom, listening: sample.listening, command: []).isEmpty)
        #expect(OverviewProblem(projectID: run.projectId, service: service)?.runID == nil)
        service.lastRun?.state = .failed
        let problem = try #require(OverviewProblem(projectID: run.projectId, service: service))
        var digest = LogDigest(runId: run.id, scannedLines: 1, errorBlocks: 1, blocks: [
            .init(kind: .error, firstSeq: 4, lastSeq: 4, occurrences: 1, lastOccurrenceSeq: 4,
                  lines: [.init(seq: 4, stream: .err, text: "Port 4100 was already in use.")])
        ], omitted: .init(errorBlocks: 0, bytes: 0), truncated: false, runEnded: true)
        #expect(problem.evidence(in: digest) == "日志提示 4100 端口已被占用")
        digest.blocks[0].lines[0].text = "Failed to bind port 4100"
        #expect(problem.evidence(in: digest) == "日志提示无法绑定 4100 端口")
        digest.runId = "previous-run"
        #expect(problem.evidence(in: digest) == nil)
    }
}
