import Foundation
import Testing

@testable import DevPanelKit

@Suite("Decoding contract fixtures")
struct DecodingTests {
    /// Every recorded JSON fixture must decode as its contract type.
    @Test("all recorded fixtures decode")
    func allRecorded() throws {
        let map: [String: (Data) throws -> Void] = [
            "daemon-info.json": { _ = try ContractCoding.decoder().decode(DaemonInfo.self, from: $0) },
            "projects.json": { _ = try ContractCoding.decoder().decode([ProjectView].self, from: $0) },
            "project-order-service.json": { _ = try ContractCoding.decoder().decode(Project.self, from: $0) },
            "project-ml-api-secret-param.json": { _ = try ContractCoding.decoder().decode(Project.self, from: $0) },
            "project-view.json": { _ = try ContractCoding.decoder().decode(ProjectView.self, from: $0) },
            "project-stats.json": { _ = try ContractCoding.decoder().decode(ProjectStats.self, from: $0) },
            "project-stats-idle.json": { _ = try ContractCoding.decoder().decode(ProjectStats.self, from: $0) },
            "project-stats-ml-api.json": { _ = try ContractCoding.decoder().decode(ProjectStats.self, from: $0) },
            "v1.0-project-stats-no-listening.json": { _ = try ContractCoding.decoder().decode(ProjectStats.self, from: $0) },
            "runs.json": { _ = try ContractCoding.decoder().decode([RunSummary].self, from: $0) },
            "run-detail.json": { _ = try ContractCoding.decoder().decode(RunDetail.self, from: $0) },
            "run-detail-failed.json": { _ = try ContractCoding.decoder().decode(RunDetail.self, from: $0) },
            "run-detail-secret-param.json": { _ = try ContractCoding.decoder().decode(RunDetail.self, from: $0) },
            "v1.0-run-detail-no-params.json": { _ = try ContractCoding.decoder().decode(RunDetail.self, from: $0) },
            "logs-page.json": { _ = try ContractCoding.decoder().decode(LogPage.self, from: $0) },
            "operation-created.json": { _ = try ContractCoding.decoder().decode(Operation.self, from: $0) },
            "operation-finished.json": { _ = try ContractCoding.decoder().decode(Operation.self, from: $0) },
            "operation-stop-finished.json": { _ = try ContractCoding.decoder().decode(Operation.self, from: $0) },
            "validate-ok.json": { _ = try ContractCoding.decoder().decode(ValidateResult.self, from: $0) },
            "validate-issues.json": { _ = try ContractCoding.decoder().decode(ValidateResult.self, from: $0) },
            "register-response.json": { _ = try ContractCoding.decoder().decode(RegisterResponse.self, from: $0) },
            "update-response-kept.json": { _ = try ContractCoding.decoder().decode(UpdateResponse.self, from: $0) },
            "param-add.json": { _ = try ContractCoding.decoder().decode(Project.self, from: $0) },
            "param-patch.json": { _ = try ContractCoding.decoder().decode(Project.self, from: $0) },
            "param-delete-inline.json": { _ = try ContractCoding.decoder().decode(Project.self, from: $0) },
        ]
        var covered = 0
        for name in try Fixture.names(in: "recorded") {
            let data = try Fixture.data("recorded/\(name)")
            if name.hasPrefix("error-") {
                _ = try ContractCoding.decoder().decode(ErrorBody.self, from: data)
            } else if name.hasPrefix("event-") {
                _ = try ContractCoding.decoder().decode(DaemonEvent.self, from: data)
            } else if name.hasSuffix(".sse") {
                continue  // covered by SSE tests
            } else {
                let decode = try #require(map[name], "no decoder registered for fixture \(name)")
                try decode(data)
            }
            covered += 1
        }
        #expect(covered >= 38)
    }

    /// Fixtures/recorded-real: captured from the real daemon (packages/daemon, temp
    /// DEVPANEL_HOME, a throwaway `sleep` project). Guards against mock/daemon drift.
    @Test("real daemon fixtures decode")
    func realDaemon() throws {
        let info = try Fixture.decode(DaemonInfo.self, "recorded-real/daemon-info.json")
        #expect(info.apiVersion == 1)
        let reg = try Fixture.decode(RegisterResponse.self, "recorded-real/register-response.json")
        let params = try #require(reg.project.config.params)
        #expect(params.map(\.type) == [.number, .enum, .boolean, .string])
        #expect(params.last?.isSecret == true && params.last?.value == nil)
        #expect(reg.project.config.env?["TOKEN"] == .secret(value: nil))
        let patched = try Fixture.decode(Project.self, "recorded-real/param-patch.json")
        #expect(patched.config.params?.first?.setBy == .user)
        #expect(patched.config.params?.first?.value == .number(600))
        let validate = try Fixture.decode(ValidateResult.self, "recorded-real/validate.json")
        #expect(validate.ok)
        #expect(validate.issues.allSatisfy { $0.code == .warning(.paramUnused) })
        let run = try Fixture.decode(RunDetail.self, "recorded-real/run-detail.json")
        #expect(run.command == ["sleep", "600"])
        #expect(run.params == ["secs": .value(.number(600)), "mode": .value(.string("a"))])
        let stats = try Fixture.decode(ProjectStats.self, "recorded-real/project-stats.json")
        #expect(stats.services["app"]?.listening == [])
        _ = try Fixture.decode(ProjectView.self, "recorded-real/project-view.json")
        #expect(try Fixture.decode(Operation.self, "recorded-real/operation-finished.json").results.first?.outcome == .started)
        #expect(try Fixture.decode(Operation.self, "recorded-real/operation-stop.json").results.first?.outcome == .stopped)
        var parser = SSEParser()
        let events = try parser.feed(Fixture.data("recorded-real/events.sse")).map {
            try ContractCoding.decoder().decode(DaemonEvent.self, from: Data($0.data.utf8))
        }
        #expect(events.first?.type == "snapshot")
        #expect(events.count >= 10)
        #expect(!events.contains { if case .unknown = $0 { true } else { false } })
    }

    @Test func daemonInfo() throws {
        let info = try Fixture.decode(DaemonInfo.self, "recorded/daemon-info.json")
        #expect(info.apiVersion == 1)
        #expect(info.limits.logPageMaxLines == 2000)
        #expect(info.limits.defaultStopTimeoutSec == 10)
        #expect(info.selfUsage.status == .ok)
    }

    @Test func discovery() throws {
        let d = try Fixture.decode(DaemonDiscovery.self, "handwritten/discovery.json")
        #expect(d.httpPort == 47823)
        #expect(DaemonEndpoint(discovery: d).baseURL.absoluteString == "http://127.0.0.1:47823/api/v1")
    }

    @Test("params: enum choices, number min/max, setBy, usedBy")
    func paramsRecorded() throws {
        let project = try Fixture.decode(Project.self, "recorded/project-order-service.json")
        let params = try #require(project.config.params)
        let profile = try #require(params.first { $0.key == "profile" })
        #expect(profile.type == .enum)
        #expect(profile.value == .string("dev"))
        #expect(profile.choices?.map(\.value) == ["dev", "test", "prod"])
        #expect(profile.choices?.first?.label == "本地开发")
        #expect(profile.choices?.first?.description?.isEmpty == false)
        #expect(profile.setBy == .agent)
        #expect(profile.usedBy == [ParamReference(serviceId: "backend", where: .command, index: 2)])
        let port = try #require(params.first { $0.key == "apiPort" })
        #expect(port.type == .number)
        #expect(port.value == .number(8081))
        #expect(port.value?.description == "8081")
        #expect(port.min == 1024 && port.max == 65535)
        #expect(params.contains { $0.setBy == .user })
    }

    @Test("params: secret has no value, boolean value")
    func secretParamRecorded() throws {
        let project = try Fixture.decode(Project.self, "recorded/project-ml-api-secret-param.json")
        let params = try #require(project.config.params)
        let token = try #require(params.first { $0.key == "hfToken" })
        #expect(token.isSecret)
        #expect(token.value == nil)
        let reload = try #require(params.first { $0.key == "reload" })
        #expect(reload.type == .boolean)
        #expect(reload.value == .bool(true))
    }

    @Test("params: every type, fractional number, project-level usedBy, unknown type/setter")
    func paramsHandwritten() throws {
        let project = try Fixture.decode(Project.self, "handwritten/project-params-all-types.json")
        let params = try #require(project.config.params)
        #expect(params.count == 8)
        let byKey = Dictionary(uniqueKeysWithValues: params.map { ($0.key, $0) })
        #expect(byKey["ratio"]?.value == .number(0.25))
        #expect(byKey["ratio"]?.value?.description == "0.25")
        #expect(byKey["debug"]?.value == .bool(false))
        #expect(byKey["debug"]?.describedBy == .user)
        #expect(byKey["host"]?.usedBy?.first?.isProjectLevel == true)
        #expect(byKey["host"]?.usedBy?.first?.envKey == "BIND")
        #expect(byKey["apiToken"]?.isSecret == true)
        #expect(byKey["apiToken"]?.value == nil)
        #expect(byKey["profile"]?.choices?.last == ParamChoice(value: "prod"))
        #expect(byKey["future"]?.type == .other("color"))
        #expect(byKey["future"]?.setBy == .other("robot"))
        #expect(project.config.env?["DB_PASSWORD"] == .secret(value: nil))
        #expect(project.config.env?["BIND"] == .plain("${host}"))
        #expect(project.config.services[0].stopTimeoutSec == 15)
    }

    @Test("RunDetail.params with secret; v1.0 run without params")
    func runParams() throws {
        let run = try Fixture.decode(RunDetail.self, "recorded/run-detail-secret-param.json")
        #expect(run.params["port"] == .value(.number(8000)))
        #expect(run.params["reload"] == .value(.bool(true)))
        #expect(run.params["hfToken"] == .secret)
        #expect(run.processes.count >= 1)
        let old = try Fixture.decode(RunDetail.self, "recorded/v1.0-run-detail-no-params.json")
        #expect(old.params.isEmpty)
        let failed = try Fixture.decode(RunDetail.self, "recorded/run-detail-failed.json")
        #expect(failed.state == .failed)
        #expect(failed.endedAt != nil)
    }

    @Test("listening: recorded multi-port, ipv6")
    func listeningRecorded() throws {
        let stats = try Fixture.decode(ProjectStats.self, "recorded/project-stats.json")
        let backend = try #require(stats.services["backend"])
        #expect(backend.listening?.map(\.port) == [8081, 35729])
        #expect(backend.listening?.first?.scope == .loopback)
        #expect(backend.listening?.last?.scope == .all)
        let frontend = try #require(stats.services["frontend"])
        #expect(frontend.listening?.first?.family == .ipv6)
        #expect(frontend.listening?.first?.address == "::")
        let old = try Fixture.decode(ProjectStats.self, "recorded/v1.0-project-stats-no-listening.json")
        #expect(old.services.values.allSatisfy { $0.listening == nil })
    }

    @Test("listening: null, [], many incl. scope other; sample statuses")
    func listeningVariants() throws {
        let snap = try Fixture.decode(StatsSnapshot.self, "handwritten/stats-listening-variants.json")
        let services = try #require(snap.projects["p_7k2m9q4tza"]?.services)
        #expect(services["notyet"]?.listening == nil)
        #expect(services["notyet"]?.status == .sampling)
        #expect(services["notyet"]?.cpuPercent == nil)
        #expect(services["none"]?.listening == [])
        #expect(services["many"]?.listening?.count == 5)
        #expect(services["many"]?.listening?.last?.scope == .specific)
        #expect(services["many"]?.listening?.last?.scope.rawValue == "other")
        #expect(services["many"]?.status == .partial)
        #expect(services["many"]?.note == "1 个进程无法读取")
        #expect(services["gone"]?.status == .unavailable)
        #expect(services["gone"]?.listening == nil)
        #expect(snap.projects["p_7k2m9q4tza"]?.total.rssBytes == 734_003_200)
    }

    @Test func projectsAndViews() throws {
        let projects = try Fixture.decode([ProjectView].self, "recorded/projects.json")
        #expect(projects.count == 6)
        #expect(projects.map(\.aggregate).contains(.failed))
        let order = try #require(projects.first)
        #expect(order.services.count == order.serviceCount)
        #expect(order.services.first?.currentRun != nil)
        let view = try Fixture.decode(ServiceView.self, "handwritten/service-view-stopping-timeout.json")
        #expect(view.stopTimedOut)
        #expect(view.error?.code == .stopTimeout)
        #expect(view.error?.stopTimeoutSec == 10)
        #expect(view.error?.remainingProcesses == 3)
        #expect(view.configChangedSinceStart)
    }

    @Test("unknown enum values never fail decoding")
    func unknownValues() throws {
        let view = try Fixture.decode(ProjectView.self, "handwritten/project-view-unknown-values.json")
        #expect(view.aggregate == .other("mystery"))
        #expect(!view.aggregate.isKnown)
        let svc = try #require(view.services.first)
        #expect(svc.state == .other("hibernating"))
        #expect(svc.lastRun?.exit?.reason == .other("moon-phase"))
        #expect(svc.error?.code == .other("NEW_FAILURE_KIND"))
        let op = try Fixture.decode(Operation.self, "handwritten/operation-unknown-values.json")
        #expect(op.action == .other("hibernate"))
        #expect(op.source == .other("scheduler"))
        #expect(op.state == .other("paused"))
        #expect(!op.isFinished)
        #expect(op.results.first?.outcome == .other("snoozed"))
        // Known values still map to their cases.
        #expect(ServiceState(raw: "running") == .running)
        #expect(ExitReason(raw: "self-exit") == .selfExit)
        #expect(TargetOutcome(raw: "already-running") == .alreadyRunning)
    }

    @Test("operations: lifecycle and stop-timeout details")
    func operations() throws {
        let created = try Fixture.decode(Operation.self, "recorded/operation-created.json")
        #expect(created.results.first?.outcome == .pending)
        #expect(!created.isFinished)
        let done = try Fixture.decode(Operation.self, "recorded/operation-finished.json")
        #expect(done.state == .succeeded)
        #expect(done.results.first?.outcome == .started)
        #expect(done.results.first?.runId != nil)
        let stopped = try Fixture.decode(Operation.self, "recorded/operation-stop-finished.json")
        #expect(stopped.action == .stop)
        #expect(stopped.results.first?.outcome == .stopped)
        let timeout = try Fixture.decode(Operation.self, "handwritten/error-stop-timeout-operation.json")
        #expect(timeout.state == .partial)
        #expect(timeout.results.map(\.outcome) == [.failed, .stopTimeout])
        #expect(timeout.results.last?.error?.remainingProcesses == 1)
        #expect(timeout.results.last?.error?.stopTimeoutSec == 10)
    }

    @Test func logs() throws {
        let page = try Fixture.decode(LogPage.self, "recorded/logs-page.json")
        #expect(page.lines.count == 5)
        #expect(page.hasMoreBefore)
        let seqs = page.lines.map(\.seq)
        #expect(seqs == seqs.sorted())
    }

    @Test func validation() throws {
        let ok = try Fixture.decode(ValidateResult.self, "recorded/validate-ok.json")
        #expect(ok.ok)
        #expect(ok.services.first?.programResolved != nil)
        let bad = try Fixture.decode(ValidateResult.self, "recorded/validate-issues.json")
        #expect(!bad.ok)
        let codes = bad.issues.map(\.code)
        #expect(codes.contains(.error(.paramUnknown)))
        #expect(codes.contains(.warning(.paramUnused)))
        #expect(codes.contains(.warning(.backgroundCommand)))
        #expect(bad.issues.contains { $0.severity == .warning })
        #expect(bad.services.first?.programResolved == nil)
        #expect(IssueCode(rawValue: "WARN_FROM_FUTURE") == .other("WARN_FROM_FUTURE"))
    }

    @Test func registerAndUpdate() throws {
        let reg = try Fixture.decode(RegisterResponse.self, "recorded/register-response.json")
        #expect(reg.created)
        #expect(reg.project.revision == 1)
        #expect(reg.project.config.env?["API_KEY"] == .secret(value: nil))
        let upd = try Fixture.decode(UpdateResponse.self, "recorded/update-response-kept.json")
        #expect(upd.keptUserValues == ["port"])
        #expect(upd.project.config.params?.first { $0.key == "port" }?.value == .number(4000))
        let inline = try Fixture.decode(Project.self, "recorded/param-delete-inline.json")
        #expect(inline.config.env?["PORT"] == .plain("4000"))
        #expect(inline.config.params?.contains { $0.key == "port" } == false)
        let patched = try Fixture.decode(Project.self, "recorded/param-patch.json")
        #expect(patched.config.params?.first { $0.key == "port" }?.setBy == .user)
    }

    @Test("errors: known codes, details, unknown code")
    func errors() throws {
        let unauthorized = try Fixture.decode(ErrorBody.self, "recorded/error-unauthorized.json").error
        #expect(unauthorized.code == .unauthorized)
        let mismatch = try Fixture.decode(ErrorBody.self, "recorded/error-revision-mismatch.json").error
        #expect(mismatch.code == .revisionMismatch)
        #expect(mismatch.currentRevision != nil)
        let conflict = try Fixture.decode(ErrorBody.self, "recorded/error-config-conflict.json").error
        #expect(conflict.code == .configConflict)
        #expect(conflict.configDiff?.isEmpty == false)
        #expect(conflict.details?["projectId"]?.stringValue?.hasPrefix("p_") == true)
        let invalid = try Fixture.decode(ErrorBody.self, "recorded/error-config-invalid.json").error
        #expect(invalid.code == .configInvalid)
        #expect(invalid.issues?.isEmpty == false)
        let inUse = try Fixture.decode(ErrorBody.self, "recorded/error-param-in-use.json").error
        #expect(inUse.code == .paramInUse)
        #expect(inUse.paramUsedBy?.first?.envKey == "PORT")
        let secret = try Fixture.decode(ErrorBody.self, "handwritten/error-param-in-use-secret.json").error
        #expect(secret.details?["reason"]?.stringValue == "secret")
        #expect(try Fixture.decode(ErrorBody.self, "recorded/error-project-running.json").error.code == .projectRunning)
        #expect(try Fixture.decode(ErrorBody.self, "recorded/error-run-not-found.json").error.code == .runNotFound)
        #expect(try Fixture.decode(ErrorBody.self, "recorded/error-bad-request.json").error.code == .badRequest)

        let unknown = try Fixture.decode(ErrorBody.self, "handwritten/error-unknown-code.json").error
        #expect(unknown.code == .other("SOMETHING_NEW_FROM_A_FUTURE_DAEMON"))
        #expect(unknown.details?["n"]?.intValue == 3)
        #expect(unknown.details?["nested"]?["a"]?.arrayValue == [.number(1), .bool(true), .null])
    }

    @Test("DaemonEvent: every recorded type")
    func daemonEvents() throws {
        guard case .snapshot(let snap) = try Fixture.decode(DaemonEvent.self, "recorded/event-snapshot.json") else {
            Issue.record("not a snapshot"); return
        }
        #expect(snap.projects.count == 6)
        #expect(snap.daemon.apiVersion == 1)
        guard case .projectUpsert(let p) = try Fixture.decode(DaemonEvent.self, "recorded/event-project.upsert.json") else {
            Issue.record("not an upsert"); return
        }
        #expect(p.id.hasPrefix("p_"))
        guard case .projectRemove(let id) = try Fixture.decode(DaemonEvent.self, "recorded/event-project.remove.json") else {
            Issue.record("not a remove"); return
        }
        #expect(id.hasPrefix("p_"))
        guard case .operation = try Fixture.decode(DaemonEvent.self, "recorded/event-operation.json") else {
            Issue.record("not an operation"); return
        }
        guard case .stats(let stats) = try Fixture.decode(DaemonEvent.self, "recorded/event-stats.json") else {
            Issue.record("not stats"); return
        }
        #expect(stats.intervalMs == 2000)
        #expect(stats.projects.values.flatMap(\.services.values).contains { $0.listening?.isEmpty == false })
        guard case .ping(let at) = try Fixture.decode(DaemonEvent.self, "recorded/event-ping.json") else {
            Issue.record("not a ping"); return
        }
        #expect(Timestamps.date(at) != nil)
        let unknown = try ContractCoding.decoder().decode(DaemonEvent.self, from: Data(#"{"type":"future.thing","x":1}"#.utf8))
        #expect(unknown == .unknown(type: "future.thing"))
    }

    @Test("malformed known event type throws")
    func malformedEvent() {
        #expect(throws: DecodingError.self) {
            _ = try ContractCoding.decoder().decode(DaemonEvent.self, from: Data(#"{"type":"stats"}"#.utf8))
        }
    }

    @Test("LogStreamEvent: lines / truncated / gap / end / ping / unknown")
    func logEvents() throws {
        var parser = SSEParser()
        let text = String(decoding: try Fixture.data("handwritten/logstream-variants.sse"), as: UTF8.self)
        let events = try parser.feed(text).map {
            try ContractCoding.decoder().decode(LogStreamEvent.self, from: Data($0.data.utf8))
        }
        #expect(events.map(\.type) == ["lines", "truncated", "gap", "future", "ping"])
        guard case .lines(_, let lines) = events[0] else { Issue.record("lines"); return }
        #expect(lines.count == 2)
        #expect(lines[0].text.contains("\u{1B}[32m"))
        #expect(lines[0].text.hasSuffix("中文"))
        #expect(lines[1].stream == .err)
        #expect(lines[1].partial == true)
        #expect(events[1] == .truncated(runId: "r_1", firstSeq: 120))
        #expect(events[2] == .gap(runId: "r_1", afterSeq: 340, reason: "client too slow"))
        #expect(events[3] == .unknown(type: "future"))

        var recorded = SSEParser()
        let rec = try recorded.feed(Fixture.data("recorded/logstream.sse")).map {
            try ContractCoding.decoder().decode(LogStreamEvent.self, from: Data($0.data.utf8))
        }
        guard case .end(_, .service(let run)) = try #require(rec.last) else { Issue.record("no end"); return }
        #expect(run.state == .stopped)
        #expect(run.exit?.reason == .userStop)
        #expect(run.exit?.signal == "SIGTERM")
        let all = rec.flatMap { e -> [LogLine] in if case .lines(_, let l) = e { l } else { [] } }
        #expect(all.map(\.seq) == Array(1...all.count))
        #expect(all.contains { $0.stream == .sys })
    }

    @Test("decode → encode → decode is lossless")
    func roundTrip() throws {
        for (type, name) in [
            (Project.self as any Codable.Type, "handwritten/project-params-all-types.json"),
            (Project.self, "recorded/project-ml-api-secret-param.json"),
            (RunDetail.self, "recorded/run-detail-secret-param.json"),
            (StatsSnapshot.self, "handwritten/stats-listening-variants.json"),
            (DaemonEvent.self, "recorded/event-snapshot.json"),
            (Operation.self, "handwritten/operation-unknown-values.json"),
            (UpdateResponse.self, "recorded/update-response-kept.json"),
        ] {
            try roundTrip(type, name)
        }
    }

    private func roundTrip<T: Codable>(_ type: T.Type, _ name: String) throws {
        let a = try Fixture.decode(T.self, name)
        let encoded = try ContractCoding.encoder().encode(a)
        let b = try ContractCoding.decoder().decode(T.self, from: encoded)
        let again = try ContractCoding.encoder().encode(b)
        #expect(encoded == again, "\(name) did not round-trip")
    }
}
