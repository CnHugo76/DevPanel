import Foundation
import Testing
@testable import DevPanelKit

@Suite("Run evidence and configuration comparison")
struct TroubleshootingTests {
    @Test func readinessControlsServiceAndAggregateToneWithoutChangingProcessState() throws {
        var run = try Fixture.decode(RunDetail.self, "recorded/run-detail.json").summary
        run.state = .running
        var service = ServiceView(id: run.serviceId, name: "App", state: .running, currentRun: run)
        #expect(service.status(now: Date()).tone == .blue)
        #expect(run.tone == .blue)
        for (state, tone) in [(ReadyState.waiting, DisplayTone.blue), (.timedOut, .amberStrong), (.ready, .green), (.notConfigured, .blue), (.unknown, .purple)] {
            service.currentRun?.ready = ReadyInfo(state: state)
            #expect(service.status(now: Date()).tone == tone)
            #expect(service.currentRun?.tone == tone)
            #expect(service.status(now: Date()).text == "运行中")
            let project = ProjectView(id: "p", name: "P", root: "/tmp", revision: 1, aggregate: .running,
                                      runningCount: 1, serviceCount: 1, services: [service])
            #expect(project.badge().tone == tone)
        }
        service.currentRun?.ready = ReadyInfo(state: .timedOut, afterMs: 9000)
        #expect(ServiceAssessment.make(service)?.evidence == "就绪超时")
        #expect(ServiceAssessment.make(service)?.nextStep?.contains("不会自动结束进程") == true)
    }

    @Test func selectedRunParamsCompareAgainstEffectiveSavedConfigurationWithoutSecrets() throws {
        var run = try Fixture.decode(RunDetail.self, "recorded/run-detail.json")
        run.command = ["app", "8080", "••••"]
        run.cwd = "/old/backend"
        run.envKeys = ["PORT", "OLD"]
        run.params = ["port": .value(.number(8080)), "token": .secret, "old": .value(.string("before"))]
        let service = ServiceConfig(id: "app", name: "App", cwd: "backend", command: ["app", "${port}", "${token}"],
                                    env: ["PORT": .plain("${port}"), "OVERRIDE": .plain("fixed")])
        let project = ProjectConfig(name: "P", root: "/new", env: ["OVERRIDE": .plain("${unused}")], services: [service],
                                    params: [ParamConfig(key: "port", label: "Port", type: .number, value: .number(9090)),
                                             ParamConfig(key: "token", label: "Token", type: .string, value: .string("must-not-appear"), secret: true),
                                             ParamConfig(key: "unused", label: "Unused", type: .string, value: .string("ignored"))])
        let comparison = RunComparison(run: run, config: service, project: project)
        #expect(comparison.nextCommand == ["app", "9090", "••••"])
        #expect(comparison.commandChanged && comparison.commandMasked && comparison.cwdChanged)
        #expect(comparison.params.first { $0.key == "port" }?.changed == true)
        #expect(comparison.params.first { $0.key == "token" }?.masked == true)
        #expect(comparison.params.first { $0.key == "token" }?.next == "••••")
        #expect(!comparison.params.contains { $0.key == "unused" })
        #expect(comparison.params.first { $0.key == "old" }?.next == "不再使用")
    }

    @Test func reportPinsEvidenceToRunAndBoundsCopySize() throws {
        var run = try Fixture.decode(RunDetail.self, "recorded/run-detail-secret-param.json")
        let digest = LogDigest(runId: run.id, lastSeq: 4, scannedLines: 4, errorBlocks: 1,
                               blocks: [LogDigestBlock(kind: .error, firstSeq: 2, lastSeq: 3, occurrences: 1, lastOccurrenceSeq: 2,
                                                      lines: [DigestLine(seq: 2, stream: .err, text: "ERROR masked ••••")])],
                               omitted: .init(errorBlocks: 0, bytes: 0), truncated: false, runEnded: true)
        run.ready = ReadyInfo(state: .timedOut)
        let report = try TroubleshootingReport.make(run: run, digest: digest)
        #expect(report.runId == run.id)
        #expect(report.text.contains("实际命令："))
        #expect(report.text.contains("就绪超时"))
        #expect(report.text.contains("••••"))
        #expect(report.firstError?.firstSeq == 2)
        var wrong = digest
        wrong.runId = "another-run"
        #expect(throws: ApiError.self) { try TroubleshootingReport.make(run: run, digest: wrong) }
        run.command = [String(repeating: "很长的命令", count: 20000)]
        let large = try TroubleshootingReport.make(run: run, digest: digest)
        #expect(large.text.utf8.count <= TroubleshootingReport.byteLimit)
        #expect(large.text.hasSuffix("[排障信息超过 48 KiB，后续内容已省略]"))
    }
}
