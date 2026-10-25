import Foundation
import Testing

@testable import DevPanelKit

func logLine(_ seq: Int, _ text: String = "", stream: LogStream = .out, ts: String = "2026-10-20T10:00:00.000Z") -> LogLine {
    LogLine(seq: seq, ts: ts, stream: stream, text: text.isEmpty ? "line \(seq)" : text)
}

func entries(_ seqs: some Sequence<Int>, stream: LogStream = .out) -> [LogEntry] {
    seqs.map { LogEntry(logLine($0, stream: stream)) }
}

@Suite("ANSI")
struct AnsiTests {
    @Test func plainTextIsUntouched() {
        let t = Ansi.parse("hello\tworld 你好")
        #expect(t.plain == "hello\tworld 你好")
        #expect(t.runs.isEmpty)
    }

    @Test func sgrColorsBoldUnderlineAndReset() {
        let t = Ansi.parse("\u{1B}[32mINFO\u{1B}[0m \u{1B}[1;4mbold\u{1B}[22m under\u{1B}[m end")
        #expect(t.plain == "INFO bold under end")
        #expect(t.runs.count == 3)
        #expect(t.runs[0] == AnsiRun(location: 0, length: 4, style: AnsiStyle(foreground: .palette(2))))
        #expect(t.runs[1] == AnsiRun(location: 5, length: 4, style: AnsiStyle(bold: true, underline: true)))
        #expect(t.runs[2] == AnsiRun(location: 9, length: 6, style: AnsiStyle(underline: true)))
    }

    @Test func extendedColors() {
        let t = Ansi.parse("\u{1B}[38;5;208ma\u{1B}[48;2;1;2;3mb\u{1B}[38:2::10:20:30mc\u{1B}[91md")
        #expect(t.plain == "abcd")
        #expect(t.runs[0].style.foreground == .palette(208))
        #expect(t.runs[1].style.background == .rgb(1, 2, 3))
        #expect(t.runs[2].style.foreground == .rgb(10, 20, 30))
        #expect(t.runs[3].style.foreground == .palette(9))
        #expect(t.runs[3].style.background == .rgb(1, 2, 3))
    }

    @Test func otherControlSequencesAreDropped() {
        // cursor movement, erase line, OSC title, OSC 8 hyperlink, charset, CR, BS, BEL, C1 CSI
        let input = "\u{1B}[2K\u{1B}[1Gstart\u{1B}]0;title\u{07} \u{1B}]8;;http://x\u{1B}\\link\u{1B}]8;;\u{1B}\\ \u{1B}(Bx\r\u{08}\u{07}\u{9B}31my"
        let t = Ansi.parse(input)
        #expect(t.plain == "start link xy")
        #expect(t.runs.isEmpty)
    }

    @Test func unterminatedCSIDropsTheRest() {
        #expect(Ansi.parse("ok\u{1B}[31").plain == "ok")
        #expect(Ansi.parse("ok\u{1B}").plain == "ok")
    }

    @Test func nonSGRParametersDoNotChangeStyle() {
        let t = Ansi.parse("\u{1B}[?25l\u{1B}[31ma\u{1B}[?1hb")
        #expect(t.plain == "ab")
        #expect(t.runs == [AnsiRun(location: 0, length: 2, style: AnsiStyle(foreground: .palette(1)))])
    }

    @Test func offsetsAreUTF16() {
        let t = Ansi.parse("😀\u{1B}[31m红色\u{1B}[0m")
        #expect(t.plain == "😀红色")
        #expect(t.runs == [AnsiRun(location: 2, length: 2, style: AnsiStyle(foreground: .palette(1)))])
    }

    @Test func recordedSpringLine() throws {
        let page = try Fixture.decode(LogPage.self, "recorded/logs-page.json")
        let t = Ansi.parse(page.lines[0].text)
        #expect(!t.plain.contains("\u{1B}"))
        #expect(t.plain.contains("GET /api/orders?page=1 200 57ms"))
        #expect(t.runs.contains { $0.style.foreground == .palette(2) })
        #expect(Ansi.strip(page.lines[0].text) == t.plain)
    }
}

@Suite("LogBuffer")
struct LogBufferTests {
    @Test func appendDeduplicatesBySeq() {
        var b = LogBuffer(cap: 100)
        b.reset(entries(1...5))
        #expect(b.append(entries([4, 5, 6, 7])) == 2)
        #expect(b.append(entries([7])) == 0)
        #expect(b.firstSeq == 1)
        #expect(b.lastSeq == 7)
        #expect(b.discontinuities == 0)
    }

    @Test func seqJumpIsCounted() {
        var b = LogBuffer(cap: 100)
        b.reset(entries(1...3))
        b.append(entries([10, 11]))
        #expect(b.discontinuities == 1)
        #expect(b.entries.map(\.seq) == [1, 2, 3, 10, 11])
    }

    @Test func capDropsOldestAndMarksLocalTrim() {
        var b = LogBuffer(cap: 10)
        b.reset(entries(1...4))
        #expect(!b.localTrimmed)
        b.append(entries(5...25))
        #expect(b.count == 10)
        #expect(b.firstSeq == 16)
        #expect(b.lastSeq == 25)
        #expect(b.localTrimmed)
        #expect(b.droppedFront == 15)
        #expect(b.hasMoreBefore)
        #expect(b.entry(at: 0).seq == 16)
        #expect(b.index(ofSeq: 20) == 4)
        #expect(b.index(ofSeq: 3) == nil)
    }

    @Test func capWithManyAppendsKeepsOrder() {
        var b = LogBuffer(cap: 1500)
        var next = 1
        for _ in 0..<40 {
            b.append(entries(next..<(next + 500)))
            next += 500
        }
        #expect(b.count == 1500)
        #expect(b.entries.map(\.seq) == Array((next - 1500)..<next))
    }

    @Test func prependOlderPageMerges() {
        var b = LogBuffer(cap: 100)
        b.reset(entries(51...60), hasMoreBefore: true)
        // The page overlaps the window: only seq < firstSeq are inserted.
        #expect(b.prepend(entries(41...52), hasMoreBefore: true) == 10)
        #expect(b.entries.map(\.seq) == Array(41...60))
        #expect(b.hasMoreBefore)
        #expect(b.prepend(entries(1...40), hasMoreBefore: false) == 40)
        #expect(b.firstSeq == 1)
        #expect(!b.hasMoreBefore)
        #expect(!b.detached)
    }

    @Test func prependOverflowDetachesFromLiveTail() {
        var b = LogBuffer(cap: 20)
        b.reset(entries(31...45), hasMoreBefore: true)
        b.prepend(entries(21...30), hasMoreBefore: true)
        #expect(b.count == 20)
        #expect(b.entries.map(\.seq) == Array(21...40))
        #expect(b.detached)
        // Live lines are ignored while detached …
        #expect(b.append(entries([46])) == 0)
        // … newer pages bring the window back.
        #expect(b.appendPage(entries(41...45), hasMoreAfter: true) == 5)
        #expect(b.detached)
        #expect(b.appendPage(entries(46...46), hasMoreAfter: false) == 1)
        #expect(!b.detached)
        #expect(b.lastSeq == 46)
    }

    @Test func resetSortsAndDeduplicates() {
        var b = LogBuffer(cap: 100)
        b.reset(entries([3, 1, 2, 2, 5]))
        #expect(b.entries.map(\.seq) == [1, 2, 3, 5])
        #expect(b.firstIndex(seqAtLeast: 4) == 3)
    }

    @Test func entryDisplayText() {
        let sys = LogEntry(logLine(1, "已启动 · PID 1", stream: .sys))
        #expect(sys.displayText == "devpanel › 已启动 · PID 1")
        let out = LogEntry(logLine(2, "\u{1B}[31mboom\u{1B}[0m"))
        #expect(out.displayText == "boom")
    }
}

@Suite("Log search")
struct LogSearchTests {
    @Test func caseInsensitiveAllMatches() {
        let es = [
            LogEntry(logLine(1, "GET /a 200, get /b 200")),
            LogEntry(logLine(2, "nothing")),
            LogEntry(logLine(3, "\u{1B}[32mGet\u{1B}[0m it")),
        ]
        let m = LogSearch.find(es, query: "get")
        #expect(m == [
            LogMatch(seq: 1, location: 0, length: 3),
            LogMatch(seq: 1, location: 12, length: 3),
            LogMatch(seq: 3, location: 0, length: 3),
        ])
    }

    @Test func sysLinesAreOffsetByThePrefixButThePrefixIsNotSearched() {
        let es = [LogEntry(logLine(1, "已启动 devpanel", stream: .sys))]
        let m = LogSearch.find(es, query: "devpanel")
        let offset = LogEntry.sysPrefix.utf16.count
        #expect(m == [LogMatch(seq: 1, location: offset + 4, length: 8)])
    }

    @Test func nonASCIIQuery() {
        let es = [LogEntry(logLine(1, "连接超时，重试连接"))]
        #expect(LogSearch.find(es, query: "连接").map(\.location) == [0, 7])
        let mixed = [LogEntry(logLine(2, "ÄRGER ärger"))]
        #expect(LogSearch.find(mixed, query: "ärger").count == 2)
    }

    @Test func limitAndCounter() {
        let es = entries(1...10)
        #expect(LogSearch.find(es, query: "line", max: 4).count == 4)
        #expect(LogSearch.counter(current: 2, total: 27, capped: false) == "3 / 27")
        #expect(LogSearch.counter(current: nil, total: 0, capped: false) == "0 / 0")
        #expect(LogSearch.counter(current: 0, total: 100_000, capped: true) == "1 / 100,000+")
    }

    @Test func currentMatchSurvivesRecompute() {
        let a = LogMatch(seq: 5, location: 0, length: 2)
        let b = LogMatch(seq: 9, location: 3, length: 2)
        #expect(LogSearch.resolveCurrent(previous: b, in: [a, b]) == 1)
        // The previous hit was trimmed away: the next one at or after its line.
        #expect(LogSearch.resolveCurrent(previous: LogMatch(seq: 7, location: 0, length: 2), in: [a, b]) == 1)
        #expect(LogSearch.resolveCurrent(previous: nil, in: [a, b]) == 0)
    }

    @MainActor
    @Test func modelSearchesTheBoundBufferAndSteps() async {
        var buffer = LogBuffer(cap: 100)
        buffer.reset([LogEntry(logLine(1, "error one")), LogEntry(logLine(2, "ok")), LogEntry(logLine(3, "Error two"))])
        let model = LogSearchModel()
        model.bind { buffer }
        model.setQuery("error")
        await model.searchNow()
        #expect(model.matches.count == 2)
        #expect(model.counterText == "1 / 2")
        #expect(model.next()?.seq == 3)
        #expect(model.next()?.seq == 1)  // wraps
        #expect(model.previous()?.seq == 3)
        model.setQuery("")
        #expect(model.matches.isEmpty)
        #expect(model.counterText == "0 / 0")
    }
}

@Suite("Log footer and empty states")
struct LogFooterTests {
    let now = Timestamps.date("2026-10-20T10:05:00.000Z")!

    @Test func liveQuietRun() {
        var status = LogStatus()
        status.lastLineAt = Timestamps.date("2026-10-20T10:02:00.000Z")
        var buffer = LogBuffer(cap: 100)
        buffer.reset(entries(1...5))
        let items = LogFooter.items(status: status, buffer: buffer, live: true, stale: false, now: now, logBytesPerRun: nil)
        #expect(items.map(\.text).contains("暂无新输出 · 最后输出于 3 分钟前"))
        #expect(items.first?.text.hasPrefix("已加载 ") == true)
        #expect(!items.contains { $0.id == "ended" })
    }

    @Test func truncatedTrimmedGapAndDisconnected() {
        var status = LogStatus()
        status.truncated = true
        status.gap = "管道异常"
        var buffer = LogBuffer(cap: 10)
        buffer.reset(entries(1...30))
        let items = LogFooter.items(status: status, buffer: buffer, live: true, stale: true, now: now, logBytesPerRun: 32 * 1024 * 1024)
        let texts = items.map(\.text)
        #expect(texts.contains("较早内容已按上限截断（每次运行 32 MiB）"))
        #expect(texts.contains("界面最多保留 10 行，更早的已移出内存，向上滚动可重新加载"))
        #expect(texts.contains("采集中断：管道异常"))
        #expect(texts.contains("日志流已断开，重连后从第 30 行续接"))
    }

    @Test func endedRun() {
        var buffer = LogBuffer(cap: 10)
        buffer.reset(entries(1...3))
        let items = LogFooter.items(status: LogStatus(), buffer: buffer, live: false, stale: false, now: now, logBytesPerRun: nil)
        #expect(items.map(\.text) == ["已加载 3 行", "运行已结束"])
    }

    @Test func emptyStates() {
        var loading = LogStatus()
        loading.loading = true
        #expect(LogEmptyState.make(hasRun: false, status: LogStatus(), lineCount: 0, live: false) == .neverRun)
        #expect(LogEmptyState.make(hasRun: true, status: loading, lineCount: 0, live: true) == nil)
        #expect(LogEmptyState.make(hasRun: true, status: LogStatus(), lineCount: 0, live: true) == .waitingForOutput)
        #expect(LogEmptyState.make(hasRun: true, status: LogStatus(), lineCount: 0, live: false) == .noOutput)
        #expect(LogEmptyState.make(hasRun: true, status: LogStatus(), lineCount: 5, live: true) == nil)
        #expect(LogEmptyState.neverRun.text == "点击「启动」后，日志会显示在这里。注册项目不会自动启动。")
        #expect(LogEmptyState.waitingForOutput.text == "暂无输出。部分程序会缓冲输出，日志可能延迟出现。")
    }
}

@Suite("Frozen clock")
struct FrozenClockTests {
    let synced = Timestamps.date("2026-10-20T10:46:12.000Z")!

    func state(_ status: ConnectionStatus, synced: Date?) -> ConnectionState {
        var c = ConnectionState()
        c.status = status
        c.syncedAt = synced
        return c
    }

    @Test func freezesOnlyWhileStale() {
        let wall = synced.addingTimeInterval(37)
        #expect(state(.connected, synced: synced).displayNow(wall) == wall)
        #expect(state(.disconnected, synced: synced).displayNow(wall) == synced)
        #expect(state(.unauthorized, synced: synced).displayNow(wall) == synced)
        // never connected: nothing to freeze
        #expect(state(.disconnected, synced: nil).displayNow(wall) == wall)
        #expect(state(.notRunning, synced: synced).isStale, "a vanished daemon leaves the last snapshot stale")
    }

    @Test func timersDoNotAdvanceWhileStale() {
        let connection = state(.disconnected, synced: synced)
        let run = RunSummary(
            id: "r_1", projectId: "p", serviceId: "s", configRevision: 1,
            startedAt: "2026-10-20T10:00:00.000Z", endedAt: nil, pid: 1, state: .stopping, exit: nil)
        let service = ServiceView(
            id: "s", name: "后端", state: .stopping, stateSince: "2026-10-20T10:46:00.000Z",
            currentRun: run, lastRun: run, stopTimedOut: true)
        var texts: Set<String> = []
        var uptimes: Set<String> = []
        var footers: Set<String> = []
        var status = LogStatus()
        status.lastLineAt = Timestamps.date("2026-10-20T10:40:00.000Z")
        for offset in [0.0, 3, 9, 125] {
            let now = connection.displayNow(synced.addingTimeInterval(offset))
            texts.insert(service.status(now: now).text)
            uptimes.insert(Metrics.uptime(service, now: now).text)
            footers.insert(LogFooter.items(status: status, buffer: LogBuffer(), live: true, stale: true, now: now, logBytesPerRun: nil)
                .first { $0.id == "quiet" }?.text ?? "")
        }
        #expect(texts == ["尚未停止 · 12 秒"])
        #expect(uptimes == ["46m12s"])
        #expect(footers == ["暂无新输出 · 最后输出于 6 分钟前"])
        let d = run.duration(now: connection.displayNow(synced.addingTimeInterval(50)))
        #expect(d.map { Int($0.rounded()) } == 46 * 60 + 12, "\(String(describing: d))")
    }
}

@Suite("Run wording")
struct RunTextTests {
    func run(_ state: ServiceState, exit: ExitInfo?, start: String, end: String?) -> RunSummary {
        RunSummary(id: "r_" + start, projectId: "p", serviceId: "s", configRevision: 1, startedAt: start, endedAt: end, pid: 1, state: state, exit: exit)
    }

    @Test func stateAndExitText() {
        let stopped = run(.stopped, exit: ExitInfo(reason: .userStop, code: nil, signal: "SIGTERM", at: "x"), start: "a", end: "b")
        #expect(stopped.stateText == "已停止")
        #expect(stopped.exit?.summary == "手动停止 · 信号 SIGTERM")
        let failed = run(.failed, exit: ExitInfo(reason: .selfExit, code: 1, signal: nil, at: "x"), start: "a", end: "b")
        #expect(failed.stateText == "异常（1）")
        #expect(failed.exit?.summary == "自行退出 · 退出（1）")
        let forced = run(.stopped, exit: ExitInfo(reason: .forceStop, code: nil, signal: "SIGKILL", at: "x"), start: "a", end: "b")
        #expect(forced.stateText == "已强制停止")
        #expect(ExitInfo(reason: .daemonLost, code: nil, signal: nil, at: "x").summary == "管理服务中断，运行已丢失")
        #expect(ExitInfo(reason: .other("new-reason"), code: nil, signal: nil, at: "x").summary == "new-reason")
    }

    @Test func mergeAndLabels() throws {
        let snapshot = try Fixture.decode(DaemonEvent.self, "recorded/event-snapshot.json")
        guard case .snapshot(let s) = snapshot else { Issue.record("not a snapshot"); return }
        let service = try #require(s.projects.first { $0.id == "p_ordersvc2a" }?.service("backend"))
        let current = try #require(service.currentRun)
        let older = [
            run(.stopped, exit: nil, start: "2026-10-20T07:00:00.000Z", end: "2026-10-20T08:00:00.000Z"),
            run(.failed, exit: nil, start: "2026-10-19T17:00:00.000Z", end: "2026-10-19T18:00:00.000Z"),
            run(.stopped, exit: nil, start: "2026-10-18T17:00:00.000Z", end: "2026-10-18T18:00:00.000Z"),
        ].map { r -> RunSummary in var r = r; r.serviceId = "backend"; return r }
        var foreign = older[0]
        foreign.serviceId = "frontend"
        foreign.id = "r_foreign"
        let merged = RunLabels.merge(older + [foreign], service: service, serviceId: "backend", limit: 3)
        #expect(merged.map(\.id) == [current.id, older[0].id, older[1].id])
        #expect(RunLabels.title(index: 0, isCurrent: true) == "当前运行")
        #expect(RunLabels.title(index: 0, isCurrent: false) == "最近一次")
        #expect(RunLabels.title(index: 1, isCurrent: false) == "上一次")
        #expect(RunLabels.title(index: 2, isCurrent: false) == "更早")
    }

    @Test func runParamRows() throws {
        let detail = try Fixture.decode(RunDetail.self, "recorded/run-detail-secret-param.json")
        let project = try Fixture.decode(Project.self, "recorded/project-ml-api-secret-param.json")
        let rows = RunParamRow.make(detail.params, config: project.config.params ?? [])
        #expect(!rows.isEmpty)
        for row in rows where row.secret { #expect(row.value == "••••") }
        let enumParam = ParamConfig(
            key: "profile", label: "后端配置", type: .enum, value: .string("dev"),
            choices: [ParamChoice(value: "dev", label: "本地开发")])
        let r = RunParamRow.make(["profile": .value(.string("dev")), "zz": .value(.number(8081)), "tok": .secret], config: [enumParam])
        #expect(r.map(\.key) == ["profile", "tok", "zz"])
        #expect(r[0].value == "dev（本地开发）")
        #expect(r[0].label == "后端配置")
        #expect(r[1].value == "••••")
        #expect(r[2].value == "8081")
    }

    @Test func envRows() {
        let rows = EnvDisplayRow.make(
            project: ["A": .plain("1"), "B": .plain("proj")],
            service: ["B": .plain("http://localhost:${apiPort}"), "SECRET": .secret(value: nil)],
            params: [ParamConfig(key: "apiPort", label: "端口", type: .number, value: .number(8081))])
        #expect(rows.map(\.key) == ["A", "B", "SECRET"])
        #expect(rows[1].source == .service)
        #expect(rows[1].preview == "http://localhost:8081")
        #expect(rows[2].value == "••••")
        #expect(rows[2].secret)
    }

    @Test func formats() {
        #expect(Format.count(12_304) == "12,304")
        #expect(Format.count(999) == "999")
        #expect(Format.count(1_000_000) == "1,000,000")
        #expect(Format.ago(12) == "12 秒前")
        #expect(Format.ago(185) == "3 分钟前")
        #expect(Format.ago(7300) == "2 小时前")
    }

    @Test func inspectorTabs() {
        #expect(InspectorTab.visible.map(\.title) == ["日志", "选项", "运行记录", "命令与环境"])
        #expect(InspectorTab(argument: "cmd") == .command)
        #expect(InspectorTab(argument: "nope") == nil)
    }
}
