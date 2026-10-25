import Foundation
import Testing
@testable import DevPanelKit

@Suite("Console folding")
struct LogFoldingTests {
    private func buffer(_ texts: [String], cap: Int = 50_000) -> LogBuffer {
        var buffer = LogBuffer(cap: cap)
        buffer.reset(texts.enumerated().map { LogEntry(logLine($0.offset + 1, $0.element, stream: .err)) })
        return buffer
    }
    private let frames = ["\tat demo.A.run(A.java:1)", "\tat demo.B.run(B.java:2)", "\tat demo.C.run(C.java:3)"]

    @Test func retainsHeadlinesAndNestedCauses() {
        let raw = buffer(["ERROR 初始化失败"] + frames + ["Caused by: java.io.EOFException"] + frames + ["... 12 more", "Suppressed: other failure", "finished"])
        let regions = LogFolding.regions(in: raw)
        #expect(regions.map(\.count) == [1])
        let display = LogFolding.project(raw, collapsed: regions)
        #expect(display.count == 11)
        #expect(display.entries.contains { $0.displayText == "Caused by: java.io.EOFException" })
        #expect(display.entries.contains { $0.displayText == "Suppressed: other failure" })
        #expect(raw.count == 11)
    }

    @Test func doesNotHideShortTracesOrOrdinaryMessages() {
        let raw = buffer([" at the office", "  ERROR retry", "  Caused by: x"] + Array(frames.prefix(2)))
        #expect(LogFolding.regions(in: raw).isEmpty)
    }

    @Test func respectsGapsStreamsAndPartialLines() {
        var raw = LogBuffer()
        raw.reset([1, 2, 4, 5].map { LogEntry(logLine($0, frames[0], stream: .err)) })
        #expect(LogFolding.regions(in: raw).isEmpty)
        raw.reset([LogEntry(logLine(1, frames[0], stream: .out)), LogEntry(logLine(2, frames[1], stream: .err)), LogEntry(logLine(3, frames[2], stream: .err))])
        #expect(LogFolding.regions(in: raw).isEmpty)
        raw.reset([LogEntry(logLine(1, frames[0])), LogEntry(LogLine(seq: 2, ts: "now", stream: .out, text: frames[1], partial: true)), LogEntry(logLine(3, frames[2]))])
        #expect(LogFolding.regions(in: raw).isEmpty)
    }

    @Test func foldsANSIFramesAndKeepsRawSearchable() {
        let raw = buffer(["ERROR fail"] + (frames + frames + frames).map { "\u{1B}[31m" + $0 + "\u{1B}[0m" })
        let regions = LogFolding.regions(in: raw)
        #expect(regions.count == 1)
        #expect(raw.entry(at: 2).displayText.contains("demo.B"))
        #expect(LogFolding.project(raw, collapsed: []).entries == raw.entries)
    }

    @Test func copyAcrossFoldRetainsOriginalAndUTF16Selection() {
        let raw = buffer(["ERROR 错误 😀"] + frames + frames + frames + ["end"])
        let regions = LogFolding.regions(in: raw)
        let display = LogFolding.project(raw, collapsed: regions)
        let shown = display.entries.map { $0.displayText + "\n" }.joined()
        #expect(LogFolding.selectedText(range: NSRange(location: 0, length: shown.utf16.count), display: display, raw: raw, collapsed: regions) == raw.entries.map { $0.displayText + "\n" }.joined())
        #expect(LogFolding.selectedText(range: NSRange(location: 9, length: 2), display: display, raw: raw, collapsed: regions) == "😀")
    }

    @Test func appendTrimAndPrependRecomputeBoundaries() {
        var raw = buffer(["ERROR fail"] + frames + frames, cap: 10)
        #expect(LogFolding.regions(in: raw).first?.first == 7)
        raw.append([LogEntry(logLine(8, "Caused by: failure", stream: .err))])
        raw.append([LogEntry(logLine(9, frames[0], stream: .err)), LogEntry(logLine(10, frames[1], stream: .err)), LogEntry(logLine(11, frames[2], stream: .err))])
        #expect(LogFolding.regions(in: raw).isEmpty)
        raw.prepend([LogEntry(logLine(1, "ERROR fail", stream: .err))], hasMoreBefore: false)
        #expect(LogFolding.regions(in: raw).first?.first == 7)
    }

    @Test func narrowOverviewKeepsEssentialColumnsWithinPane() {
        let layout = ColumnLayout.make(tableWidth: 456, compact: true)
        #expect(layout.columns == [.service, .status, .cpu, .memory, .actions])
        #expect(layout.totalWidth == 456)
        #expect(layout.width(.service)! >= 92)
    }

    @Test @MainActor func remembersLayoutWithIsolatedDefaults() {
        let suite = "DevPanel.tests.layout.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = ViewPreferences(defaults: defaults)
        #expect(!prefs.detailed)
        prefs.detailed = true
        #expect(ViewPreferences(defaults: defaults).detailed)
        #expect(!ViewPreferences(defaults: nil).detailed)
    }
}

extension LogFoldingTests {
    @Test func pythonExceptionEndsBlockWithoutStartingNewStack() {
        let raw = buffer(["Traceback (most recent call last):", "  File \"x.py\", line 1", "    raise TypeError()", "TypeError: bad"] + Array(repeating: "    at unrelated", count: 10))
        #expect(LogFolding.regions(in: raw).isEmpty)
    }
}
