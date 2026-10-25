import Foundation
import Testing

@testable import DevPanelKit

private let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

private func date(_ ts: String) -> Date { Timestamps.date(ts)! }

private func snapshot() throws -> SnapshotEvent {
    guard case .snapshot(let s) = try Fixture.decode(DaemonEvent.self, "recorded/event-snapshot.json") else {
        throw ApiError(code: .internal, message: "not a snapshot")
    }
    return s
}

private func service(
    _ state: ServiceState, since: Timestamp? = nil, timedOut: Bool = false, exit: ExitInfo? = nil,
    error: ApiError? = nil, run: Bool = false, changed: Bool = false
) -> ServiceView {
    let r = RunSummary(
        id: "r_01ABCDEFGHJKMN", projectId: "p", serviceId: "s", configRevision: 1,
        startedAt: "2026-10-20T10:00:00.000Z", endedAt: exit == nil ? nil : "2026-10-20T10:42:00.000Z",
        pid: 42, state: state, exit: exit)
    return ServiceView(
        id: "s", name: "后端", state: state, stateSince: since, currentRun: run ? r : nil, lastRun: r,
        stopTimedOut: timedOut, configChangedSinceStart: changed, error: error)
}

@Suite("Format")
struct FormatTests {
    @Test func bytes() {
        #expect(Format.bytes(512) == "512 B")
        #expect(Format.bytes(1536) == "1.5 KiB")
        #expect(Format.bytes(196 * 1024 * 1024) == "196 MiB")
        #expect(Format.bytes(Int(12.34 * 1024 * 1024)) == "12.3 MiB")
        #expect(Format.bytes(Int(1.12 * 1024 * 1024 * 1024)) == "1.12 GiB")
    }

    @Test func cpuIsNeverCapped() {
        #expect(Format.cpu(128) == "128.0%")
        #expect(Format.cpu(4.44) == "4.4%")
    }

    @Test func durations() {
        #expect(Format.duration(45.9) == "45s")
        #expect(Format.duration(185) == "3m05s")
        #expect(Format.duration(72 * 60) == "1h12m")
        #expect(Format.duration(2 * 86_400 + 3 * 3600 + 5) == "2d3h")
        #expect(Format.duration(-3) == "0s")
    }

    @Test func clockAndDayTime() {
        let now = date("2026-10-20T12:00:00.000Z")
        #expect(Format.clock(date("2026-10-20T10:46:12.345Z"), calendar: utc) == "10:46:12")
        #expect(Format.dayTime(date("2026-10-20T10:42:00.000Z"), now: now, calendar: utc) == "10:42")
        #expect(Format.dayTime(date("2026-10-19T18:02:00.000Z"), now: now, calendar: utc) == "昨天 18:02")
        #expect(Format.dayTime(date("2026-10-18T18:02:00.000Z"), now: now, calendar: utc) == "10/18 18:02")
    }

    @Test func pathsAndIds() {
        #expect(Format.tildePath("/Users/demo/Project/foo") == "~/Project/foo")
        #expect(Format.tildePath("/Users/demo") == "~")
        #expect(Format.tildePath("/opt/foo") == "/opt/foo")
        #expect(Format.shortRunId("r_01JC8ZB3P1XQ4K") == "r_P1XQ4K")
        #expect(Format.shortRunId("r_1") == "r_1")
    }
}

@Suite("Status wording")
struct StatusTextTests {
    let now = date("2026-10-20T10:42:12.000Z")

    @Test func serviceStates() {
        #expect(service(.idle).status(now: now) == StatusLabel(glyph: .idle, text: "未启动", tone: .gray))
        #expect(service(.running, run: true).status(now: now).text == "运行中")
        #expect(service(.starting).status(now: now).tone == .blue)
        #expect(service(.stopping, since: "2026-10-20T10:42:09.000Z").status(now: now).text == "停止中 · 3 秒")
        let timedOut = service(.stopping, since: "2026-10-20T10:42:00.000Z", timedOut: true).status(now: now)
        #expect(timedOut.text == "尚未停止 · 12 秒")
        #expect(timedOut.tone == .amberStrong)
        let exit0 = ExitInfo(reason: .selfExit, code: 0, signal: nil, at: "2026-10-20T10:42:00.000Z")
        #expect(service(.exited, exit: exit0).status(now: now).text == "已退出（0）")
        #expect(service(.unknown).status(now: now).tone == .purple)
        #expect(service(.other("paused")).status(now: now).text == "paused")
    }

    @Test func failureReasons() {
        let exit1 = ExitInfo(reason: .selfExit, code: 1, signal: nil, at: "2026-10-20T10:42:00.000Z")
        #expect(service(.failed, exit: exit1).status(now: now).text == "异常 · 退出（1）")
        let notFound = ApiError(code: .commandNotFound, message: "x", details: ["program": .string("pnpm")])
        #expect(service(.failed, error: notFound).status(now: now).text == "异常 · 命令不存在 pnpm（PATH 中未找到）")
        #expect(ApiError(code: .exitedDuringStart, message: "", details: ["code": .number(2)]).displayText == "启动期间退出（2）")
        #expect(ApiError(code: .other("NEW_CODE"), message: "").displayText == "NEW_CODE")
        #expect(ExitInfo(reason: .daemonLost, code: nil, signal: nil, at: "").displayText == "管理服务中断，运行已丢失")
        #expect(ExitInfo(reason: .userStop, code: nil, signal: "SIGTERM", at: "").displayText == "信号 SIGTERM")
    }

    @Test func notes() {
        #expect(service(.running, run: true, changed: true).note(paramChanged: true, now: now, calendar: utc)
            == ServiceNote("选项已修改 · 下次启动生效", .warning))
        #expect(service(.running, run: true, changed: true).note(paramChanged: false, now: now, calendar: utc)?.text
            == "配置已修改 · 下次启动生效")
        let exit1 = ExitInfo(reason: .selfExit, code: 1, signal: nil, at: "2026-10-20T10:42:00.000Z")
        #expect(service(.failed, exit: exit1).note(paramChanged: false, now: now, calendar: utc)
            == ServiceNote("退出（1） · 10:42", .negative))
        let forced = ExitInfo(reason: .forceStop, code: nil, signal: "SIGKILL", at: "2026-10-19T18:02:00.000Z")
        #expect(service(.stopped, exit: forced).note(paramChanged: false, now: now, calendar: utc)?.text == "已强制停止 · 昨天 18:02")
        let user = ExitInfo(reason: .userStop, code: nil, signal: "SIGTERM", at: "2026-10-20T10:00:00.000Z")
        #expect(service(.stopped, exit: user).note(paramChanged: false, now: now, calendar: utc) == nil)
        #expect(service(.running, run: true).note(paramChanged: false, now: now) == nil)
    }

    @Test func projectBadges() throws {
        let snap = try snapshot()
        let order = snap.projects[0]
        #expect(order.badge().text == "2/2 运行中")
        #expect(order.badge().tone == .green)
        #expect(ProjectAggregate.running.label(running: 2, total: 2) == "2/2 运行中")
        var p = order
        p.aggregate = .partial
        p.runningCount = 1
        #expect(p.badge().text == "部分运行 1/2")
        p.aggregate = .transition
        p.services[0] = service(.stopping, timedOut: true)
        #expect(p.badge().text == "尚未停止")
        p.aggregate = .failed
        #expect(p.badge() == StatusLabel(glyph: .failed, text: "异常", tone: .red))
        p.aggregate = .idle
        #expect(p.badge().text == "未启动")
        p.aggregate = .unknown
        #expect(p.badge().text == "状态未知")
        p.aggregate = .other("weird")
        #expect(p.badge().text == "weird")
    }

    @Test func actionAvailability() throws {
        let snap = try snapshot()
        let running = snap.projects[0].availableActions
        #expect(running == ActionAvailability(start: false, stop: true, restart: true, forceStop: false))
        let idle = snap.projects[2].availableActions
        #expect(idle == ActionAvailability(start: true, stop: false, restart: false, forceStop: false))
        let stuck = try Fixture.decode(ServiceView.self, "handwritten/service-view-stopping-timeout.json")
        #expect(stuck.availableActions.forceStop)
        #expect(stuck.availableActions.stop)
        #expect(service(.unknown).availableActions.stop)
        #expect(!service(.unknown).availableActions.start)
    }
}

@Suite("Resources and ports")
struct MetricsTests {
    let stats: ProjectStats

    init() throws {
        let snap = try Fixture.decode(StatsSnapshot.self, "handwritten/stats-listening-variants.json")
        stats = try #require(snap.projects["p_7k2m9q4tza"])
    }

    @Test func missingValuesAreNeverZero() {
        #expect(Metrics.cpu(nil, active: false) == .notRunning)
        #expect(Metrics.cpu(nil, active: true).text == "采样中")
        #expect(Metrics.cpu(stats.services["notyet"]?.sample, active: true).text == "采样中")
        #expect(Metrics.memory(stats.services["notyet"]?.sample, active: true).text == "采样中")
        #expect(Metrics.cpu(stats.services["gone"]?.sample, active: true).text == "不可用")
        #expect(Metrics.memory(stats.services["gone"]?.sample, active: true).text == "不可用")
        #expect(Metrics.cpu(stats.services["gone"]?.sample, active: true).help == "进程已退出")
        let partial = Metrics.cpu(stats.services["many"]?.sample, active: true)
        #expect(partial.text == "11.2%")
        #expect(partial.partial)
        #expect(Metrics.memory(stats.services["many"]?.sample, active: true).text == "668 MiB RSS")
        #expect(Metrics.cpu(stats.services["none"]?.sample, active: true) == MetricText("0.3%", .value, help: Metrics.cpuHelp))
    }

    @Test func statsOfAnotherRunAreIgnored() {
        let s = service(.running, run: true)
        #expect(Metrics.currentSample(s, stats.services["none"]) == nil)
        var mine = stats.services["none"]!
        mine.runId = s.currentRun!.id
        #expect(Metrics.currentSample(s, mine) == mine)
        #expect(Metrics.currentSample(service(.idle), mine) == nil)
    }

    @Test func staleness() {
        let now = date("2026-10-20T10:00:07.000Z")
        #expect(!Metrics.isStale(sampledAt: "2026-10-20T10:00:02.000Z", intervalMs: 2000, now: now))
        #expect(Metrics.isStale(sampledAt: "2026-10-20T10:00:00.000Z", intervalMs: 2000, now: now))
        #expect(!Metrics.isStale(sampledAt: nil, intervalMs: 2000, now: now))
    }

    @Test func uptime() {
        let s = service(.running, run: true)
        #expect(Metrics.uptime(s, now: date("2026-10-20T11:12:30.000Z")).text == "1h12m")
        #expect(Metrics.uptime(service(.idle), now: Date()) == .notRunning)
    }

    @Test func portsAreDeduplicatedAndSorted() {
        guard case .ports(let chips) = PortCell.make(stats.services["many"]?.listening, active: true) else {
            Issue.record("expected ports")
            return
        }
        #expect(chips.map(\.port) == [5005, 7000, 8081, 9000])
        #expect(chips.map(\.lan) == [true, false, false, true])
        #expect(chips[2].addresses == ["127.0.0.1", "::1"])
        #expect(chips[0].url.absoluteString == "http://localhost:5005")
        #expect(chips[2].help.contains("[::1]:8081"))
        #expect(chips[0].help.contains("局域网") || chips[0].help.contains("所有网卡"))
    }

    @Test func portCellStates() {
        #expect(PortCell.make(stats.services["notyet"]?.listening, active: true) == .unknown)
        #expect(PortCell.make(stats.services["none"]?.listening, active: true) == .none)
        #expect(PortCell.make(stats.services["many"]?.listening, active: false) == .notRunning)
        #expect(PortCell.unknown.help == "端口读取中 / 不可用")
    }
}

@Suite("Param chips")
struct ParamChipTests {
    let project: ProjectView
    let config: Project

    init() throws {
        let snap = try snapshot()
        project = snap.projects[0]
        config = try Fixture.decode(Project.self, "recorded/project-order-service.json")
    }

    @Test func displayValues() throws {
        let chips = ParamChips.make(try #require(config.config.params), project: project)
        #expect(chips.map(\.label) == ["后端配置", "后端端口", "监听地址"])
        #expect(chips.map(\.value) == ["本地开发", "8081", "局域网可访问"])
        #expect(chips.map(\.byAgent) == [true, true, false])
        let secret = try Fixture.decode(Project.self, "recorded/project-ml-api-secret-param.json")
        let values = (secret.config.params ?? []).map(\.displayValue)
        #expect(values.contains("••••"))
        #expect(values.contains("开"))
        #expect(ParamConfig(key: "k", label: "K", type: .string).displayValue == "未设置")
    }

    @Test func pendingOnlyWhenChangedAfterTheRunStarted() throws {
        let chips = ParamChips.make(try #require(config.config.params), project: project)
        // host was changed by the user after the backend started; the others predate the run.
        #expect(chips.map(\.pending) == [false, false, true])
        #expect(chips[2].help.hasPrefix("已修改，下次启动生效"))
        let params = config.config.params ?? []
        #expect(ParamChips.serviceHasPendingParam("backend", params: params, project: project))
        #expect(!ParamChips.serviceHasPendingParam("frontend", params: params, project: project))
    }

    @Test func projectLevelReferenceCoversEveryService() {
        let p = ParamConfig(
            key: "x", label: "X", type: .string, value: .string("1"),
            usedBy: [ParamReference(serviceId: "*", where: .env, envKey: "X")])
        #expect(p.referencingServices(in: project) == ["backend", "frontend"])
        var stopped = project
        stopped.services = stopped.services.map { var s = $0; s.configChangedSinceStart = false; return s }
        #expect(!p.isPending(in: stopped))
    }
}

@Suite("Operation results")
struct OperationTextTests {
    @Test func succeeded() throws {
        let op = try Fixture.decode(Operation.self, "recorded/operation-finished.json")
        let s = op.summary { $0 == "api" ? "ml-api" : $0 }
        #expect(s.title == "已启动")
        #expect(s.tone == .ok)
        #expect(s.items.map { "\($0.name) \($0.text)" } == ["ml-api 已启动"])
        #expect(s.sourceNote == nil)
    }

    @Test func stopTimeoutUsesDetails() throws {
        let op = try Fixture.decode(Operation.self, "handwritten/error-stop-timeout-operation.json")
        let s = op.summary { $0 }
        #expect(s.title == "重启未完成")
        #expect(s.tone == .warn)
        #expect(s.items[0].text == "失败：已发送 SIGTERM，10 秒内未全部退出（仍有 3 个受管进程）")
        #expect(s.items[1].text == "已发送 SIGTERM，10 秒内未全部退出（仍有 1 个受管进程）")
        #expect(s.hint == "可继续等待，或强制停止。")
    }

    @Test func otherShapes() {
        func op(_ action: ActionKind, _ state: OperationState, _ results: [OperationTargetResult], source: ClientKind = .ui) -> DevPanelKit.Operation {
            Operation(id: "op", projectId: "p", action: action, serviceIds: results.map(\.serviceId), source: source,
                      state: state, createdAt: "", finishedAt: "x", results: results)
        }
        let already = op(.start, .succeeded, [OperationTargetResult(serviceId: "a", outcome: .alreadyRunning)])
        #expect(already.summary { $0 }.title == "已在运行")
        let notFound = ApiError(code: .commandNotFound, message: "", details: ["program": .string("pnpm")])
        let partial = op(.start, .partial, [
            OperationTargetResult(serviceId: "a", outcome: .started),
            OperationTargetResult(serviceId: "b", outcome: .failed, error: notFound),
        ], source: .cli)
        let s = partial.summary { $0 }
        #expect(s.title == "部分运行")
        #expect(s.items[1].text == "失败：命令不存在 pnpm（PATH 中未找到）")
        #expect(s.items[1].tone == .bad)
        #expect(s.sourceNote == "来源 cli")
        #expect(op(.stop, .failed, [OperationTargetResult(serviceId: "a", outcome: TargetOutcome.failed)]).summary { $0 }.title == "停止失败")
        #expect(op(.start, .cancelled, [OperationTargetResult(serviceId: "a", outcome: .cancelled)]).summary { $0 }.items[0].text
            == "已取消（被停止操作取代）")
        #expect(op(.other("pause"), .other("weird"), [OperationTargetResult(serviceId: "a", outcome: .other("x"))]).summary { $0 }.title
            == "pause进行中")
        #expect(OperationSummary.rejected(ApiError(code: .stateUnverifiable, message: "")).items[0].text == "状态无法核验，已阻止启动")
    }

    @Test func forceStopConfirmation() {
        #expect(ForceStopText.message(names: ["后端"], processCount: 3, multiServiceProject: true)
            == "将向「后端」本次运行的 3 个受管进程发送 SIGKILL，可能丢失未保存的数据。")
        #expect(ForceStopText.message(names: ["web"], processCount: nil, multiServiceProject: false)
            == "将向本次运行的 全部受管进程发送 SIGKILL，可能丢失未保存的数据。")
    }
}

@Suite("Overview layout")
struct OverviewLayoutTests {
    @Test func columnsFillTheTable() {
        let wide = ColumnLayout.make(tableWidth: 1118, compact: false)
        #expect(wide.columns == OverviewColumn.allCases)
        #expect(abs(wide.totalWidth - 1118) < 0.001)
        #expect(wide.width(.actions) == 96)
        let compact = ColumnLayout.make(tableWidth: 648, compact: true)
        #expect(compact.columns == [.service, .status, .ports, .cpu, .memory, .actions])
        #expect(compact.width(.command) == nil)
        #expect(compact.width(.uptime) == nil)
        #expect(abs(compact.totalWidth - 648) < 0.001)
        // Same width → same layout for every card.
        #expect(ColumnLayout.make(tableWidth: 900, compact: false) == ColumnLayout.make(tableWidth: 900, compact: false))
        for width in stride(from: 456.0, through: 1200.0, by: 1) {
            let narrow = ColumnLayout.make(tableWidth: width, compact: true)
            #expect(abs(narrow.totalWidth - width) < 0.001)
            #expect(narrow.width(.cpu)! >= 80)
            #expect(narrow.width(.memory)! >= 116)
        }
    }

    @Test func searchFiltersWithoutReordering() throws {
        let projects = try snapshot().projects
        #expect(OverviewFilter.apply(projects, query: "  ").count == projects.count)
        let byProject = OverviewFilter.apply(projects, query: "ORDER")
        #expect(byProject.map(\.project.name) == ["order-service", "order-service"])
        #expect(byProject[0].services.count == 2)
        let byService = OverviewFilter.apply(projects, query: "前端")
        #expect(byService.map(\.project.name) == ["order-service", "shop-portal"])
        #expect(byService.allSatisfy { $0.services.map(\.name) == ["前端"] })
        #expect(OverviewFilter.apply(projects, query: "nothing-matches").isEmpty)
    }

    @Test func paletteByPosition() throws {
        let p = try snapshot().projects[0]
        #expect(ProcessPalette.index(of: "backend", in: p) == 0)
        #expect(ProcessPalette.index(of: "frontend", in: p) == 1)
        #expect(ProcessPalette.colors.count == 8)
        var many = p
        many.services = (0..<10).map { ServiceView(id: "s\($0)", name: "s", state: .idle) }
        #expect(ProcessPalette.index(of: "s9", in: many) == 1)
    }

    @Test func commandPreview() {
        let params = [
            ParamConfig(key: "profile", label: "P", type: .enum, value: .string("dev")),
            ParamConfig(key: "port", label: "Port", type: .number, value: .number(8081)),
            ParamConfig(key: "tok", label: "T", type: .string, secret: true),
            ParamConfig(key: "name", label: "N", type: .string, value: .string("it's")),
        ]
        let argv = ["mvn", "-Dp=${profile}", "--port=${port}", "$${literal}", "${HOME}", "${}", "${tok}"]
        #expect(CommandText.substitute(argv, params: params)
            == ["mvn", "-Dp=dev", "--port=8081", "${literal}", "${HOME}", "${}", "••••"])
        #expect(CommandText.hasPlaceholders(argv))
        #expect(!CommandText.hasPlaceholders(["pnpm", "dev", "$${x}"]))
        #expect(CommandText.substitute(["/bin/zsh", "-lc", "echo ${name}", "${name}"], params: params)
            == ["/bin/zsh", "-lc", "echo 'it'\\''s'", "it's"])
        #expect(CommandText.join(["pnpm", "--dir", "my app", ""]) == "pnpm --dir 'my app' ''")
    }
}

@MainActor
@Suite("View preferences")
struct ViewPreferencesTests {
    @Test func optionsDefaultClosedAndPersistIndependentlyOfCards() throws {
        let suite = "devpanel.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = ViewPreferences(defaults: defaults)
        #expect(!prefs.optionsExpanded("p1"))
        prefs.toggleOptionsExpanded("p1")
        prefs.setCollapsed("p1", true)
        prefs.setCollapsed("p1", false)
        #expect(prefs.optionsExpanded("p1"))
        let restored = ViewPreferences(defaults: defaults)
        #expect(restored.optionsExpanded("p1"))
        #expect(!restored.optionsExpanded("p2"))
        restored.toggleOptionsExpanded("p1")
        #expect(!ViewPreferences(defaults: defaults).optionsExpanded("p1"))
        #expect(ViewPreferences(defaults: nil).expandedOptions.isEmpty)
    }

    @Test func inMemoryDefaults() {
        let prefs = ViewPreferences(defaults: nil)
        #expect(prefs.inspectorWidth == 470)
        prefs.setInspectorWidth(1000)
        #expect(prefs.inspectorWidth == 640)
        prefs.setInspectorWidth(100)
        #expect(prefs.inspectorWidth == 380)
        prefs.setInspectorWidth(600)
        #expect(prefs.effectiveInspectorWidth(total: 1180) == 600)
        #expect(prefs.effectiveInspectorWidth(total: 1000) == 480)
        #expect(prefs.effectiveInspectorWidth(total: 800) == 380)
    }

    @Test func persistsCollapsedAndWidth() throws {
        let suite = "devpanel.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = ViewPreferences(defaults: defaults)
        a.toggleCollapsed("p1")
        a.setCollapsed("p2", true)
        a.setCollapsed("p2", false)
        a.setInspectorWidth(512)
        a.commitInspectorWidth()
        let b = ViewPreferences(defaults: defaults)
        #expect(b.collapsed == ["p1"])
        #expect(b.isCollapsed("p1"))
        #expect(b.inspectorWidth == 512)
    }
}

@Suite("Copy")
struct CopyTests {
    @Test func staleBanner() {
        #expect(StaleCopy.banner(syncedAt: date("2026-10-20T10:46:12.000Z"), calendar: utc)
            == "下面是 10:46:12 的状态，可能已过期；操作暂时不可用。")
        #expect(StaleCopy.banner(syncedAt: nil).contains("—"))
    }

    @Test func noForbiddenWords() throws {
        let texts = [EmptyStateCopy.title, EmptyStateCopy.body, StaleCopy.banner(syncedAt: nil)]
            + ServiceState.known.map { service($0).status(now: Date()).text }
            + ProjectAggregate.known.map { $0.label(running: 1, total: 2) }
        for t in texts {
            for word in ["健康", "就绪", "验证通过", "正常"] {
                #expect(!t.contains(word), "\(t) contains \(word)")
            }
        }
    }
}
