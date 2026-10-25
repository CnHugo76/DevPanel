import AppKit
import DevPanelKit
import Foundation

/// `--snapshot` options for the inspector (F3):
///
///   --tab logs|options|runs|cmd   select an inspector tab (needs --select)
///   --log-run <n>                 log view shows the n-th newest run (0 = newest; ≥ 1 = history)
///   --log-search <text>           search the loaded lines (highlights + "3 / 27"), jump to hit 1
///   --log-scroll-up <points>      scroll the log up by this much (stops following; new lines
///                                 arriving during --delay show the "↓ N 条新日志" pill)
///   --log-bench <text>            after --delay: print line count, memory footprint, search /
///                                 rebuild / scroll timings (for the 100k-line flood check)
///   --second <png> --second-delay <sec>
///                                 draw a second PNG this many seconds after the first (same
///                                 process, e.g. to show timers frozen while disconnected)
@MainActor
enum InspectorSnapshot {
    struct Options {
        var tab: InspectorTab?
        var runIndex: Int?
        var search: String?
        var scrollUp: CGFloat?
        var bench: String?
        var second: URL?
        var secondDelay: TimeInterval = 3
    }

    static func parse(_ args: [String]) throws -> Options {
        func value(_ flag: String) throws -> String? {
            guard let i = args.firstIndex(of: flag) else { return nil }
            guard i + 1 < args.count else { throw SnapshotError("\(flag) 缺少参数") }
            return args[i + 1]
        }
        var o = Options()
        if let t = try value("--tab") {
            guard let tab = InspectorTab(argument: t) else { throw SnapshotError("--tab 只能是 logs、options、runs、cmd、git、maven") }
            o.tab = tab
        }
        if let n = try value("--log-run") {
            guard let i = Int(n), i >= 0 else { throw SnapshotError("--log-run 需要非负整数") }
            o.runIndex = i
        }
        o.search = try value("--log-search")
        if let s = try value("--log-scroll-up") {
            guard let p = Double(s), p > 0 else { throw SnapshotError("--log-scroll-up 需要正数") }
            o.scrollUp = CGFloat(p)
        }
        o.bench = try value("--log-bench")
        if let p = try value("--second") { o.second = URL(fileURLWithPath: p) }
        if let d = try value("--second-delay") {
            guard let t = TimeInterval(d), t >= 0 else { throw SnapshotError("--second-delay 需要秒数") }
            o.secondDelay = t
        }
        return o
    }

    /// After `--select`, before `--delay`.
    static func apply(_ o: Options, model: AppModel, timeout: TimeInterval) async {
        guard let ref = model.selection.map(LogOwner.service) ?? model.selectedTaskRef.map(LogOwner.task) else { return }
        if let tab = o.tab { model.inspector.tab = tab }
        let deadline = Date().addingTimeInterval(timeout)
        // Runs list (for --log-run) and the first page of the viewed run.
        await model.refreshRuns(ref)
        if let i = o.runIndex {
            let runs = model.runs(for: ref)
            if runs.indices.contains(i) {
                model.chooseRun(runs[i].id, for: ref)
            } else {
                err("snapshot: --log-run \(i) 超出范围（共 \(runs.count) 次运行）")
            }
        }
        model.syncLogSession()
        await waitUntil(deadline) {
            let s = model.inspector.logs
            return s.target == nil || (!s.status.loading && (s.status.streaming || s.status.ended || s.status.error != nil))
        }
        if model.inspector.tab == .runs, ref.service != nil {
            for run in model.runs(for: ref) { await model.loadRunDetail(run.id) }
        }
        // Let the text view build before searching / scrolling.
        try? await Task.sleep(for: .milliseconds(300))
        if let q = o.search {
            model.inspector.search.setQuery(q)
            await model.inspector.search.searchNow()
            if let m = model.inspector.search.current {
                try? await Task.sleep(for: .milliseconds(100))
                LogTextController.active?.reveal(m)
            }
        }
        if let up = o.scrollUp, let c = LogTextController.active?.coordinatorForBench {
            c.scrollUp(by: up)
        }
        let s = model.inspector.logs
        out("logs:    \(s.target.map { Format.shortRunId($0.runId) } ?? "无") · \(Format.count(s.buffer.count)) 行 · \(s.status.ended ? "已结束" : s.status.streaming ? "流已打开" : "未打开")")
    }

    /// After `--delay`, before drawing.
    static func beforeRender(_ o: Options, model: AppModel) async {
        if o.search != nil { await model.inspector.search.searchNow() }
        guard let q = o.bench else { return }
        let s = model.inspector.logs
        let search = model.inspector.search
        search.setQuery(q)
        let t0 = ContinuousClock.now
        await search.searchNow()
        let searchTime = ContinuousClock.now - t0
        var line = "bench:   \(Format.count(s.buffer.count)) 行在内存（上限 \(Format.count(s.buffer.cap))）"
        line += " · 已移出 \(Format.count(s.buffer.droppedFront)) 行"
        line += " · 物理内存 \(Format.bytes(footprint()))"
        line += " · 搜索「\(q)」\(Format.count(search.matches.count)) 处 \(ms(searchTime))"
        if let c = LogTextController.active?.coordinatorForBench {
            try? await Task.sleep(for: .milliseconds(200))
            line += " · 增量同步 \(c.syncCount) 次，最慢 \(ms(c.slowestSync))"
            if let r = c.benchRebuild(s.buffer) { line += " · 全量重建 \(ms(r))" }
            line += " · 高亮 \(ms(c.benchHighlights(search.matches, current: search.current)))"
            line += " · 屏上 \(Format.count(c.seqs.count)) 行"
            let steps = 40
            let scroll = c.benchScroll(steps: steps)
            line += " · 滚动 \(steps) 屏 \(ms(scroll))（每屏 \(ms(scroll / steps))）"
            if let m = search.next() {
                let t1 = ContinuousClock.now
                c.reveal(m)
                line += " · 跳到匹配 \(ms(ContinuousClock.now - t1))"
            }
            c.scrollToBottom()
        }
        out(line)
    }

    private static func ms(_ d: Duration) -> String {
        let (s, atto) = d.components
        let v = Double(s) * 1000 + Double(atto) / 1e15
        return String(format: "%.1f ms", v)
    }

    /// `phys_footprint` of this process (what Activity Monitor shows as Memory).
    static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    private static func waitUntil(_ deadline: Date, _ condition: () -> Bool) async {
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private static func out(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    private static func err(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
