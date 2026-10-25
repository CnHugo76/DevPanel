import Foundation
import Testing
@testable import DevPanelKit

@Suite("Readable console prefixes") struct LogPresentationTests {
    let spring = "2026-10-23T12:34:56.789+08:00  INFO 1234 --- [order-service] [http-nio-8080-exec-1] com.example.OrderController : 已接收 😀 orderId=42"

    @Test func compactsSpringAndCopiesOriginalWithoutChangingMessage() {
        let entry = LogEntry(logLine(1, spring))
        let short = entry.compacted
        #expect(short.text.plain == "12:34:56.789 INFO OrderController : 已接收 😀 orderId=42")
        #expect(short.presentation.level == .info)
        var raw = LogBuffer(); raw.reset([entry])
        var display = LogBuffer(); display.reset([short])
        #expect(LogFolding.selectedText(range: NSRange(location: 0, length: short.displayText.utf16.count + 1), display: display, raw: raw, collapsed: []) == spring + "\n")
        let emoji = (short.displayText as NSString).range(of: "😀")
        #expect(LogFolding.selectedText(range: emoji, display: display, raw: raw, collapsed: []) == "😀")
        #expect(LogSearch.find(raw.entries, query: "http-nio").count == 1)
    }
    @Test func preservesAnsiOnRetainedText() {
        let text = "2026-10-23 12:34:56.789 [main] \u{1B}[33mWARN\u{1B}[0m com.example.App - \u{1B}[31m失败😀\u{1B}[0m"
        let short = LogEntry(logLine(1, text)).compacted
        #expect(short.text.plain == "12:34:56.789 WARN App : 失败😀")
        #expect(short.text.runs.count == 2)
        #expect(short.text.runs.last.map { (short.text.plain as NSString).substring(with: NSRange(location: $0.location, length: $0.length)) } == "失败😀")
    }
    @Test func doesNotTruncateUnknownFormatsOrMessageKeywords() {
        for text in ["request contains ERROR but succeeded", "{\"level\":\"INFO\"}", "    at com.example.App.main(App.java:1)", "INFORMATION", "ERRORS"] {
            let entry = LogEntry(logLine(1, text))
            #expect(entry.compacted.text == entry.text)
            #expect(entry.presentation.level == nil)
        }
        #expect(LogPresentation("[INFO] Building app").level == .info)
        #expect(LogPresentation("12:34:56 [worker] warning disk slow").level == .warn)
        #expect(LogPresentation("ERROR operation failed").level == .error)
    }
    @Test func acceptsLevelBeforeThreadAndCopiesBlankMessages() {
        let original = "2026-10-23 12:34:56.789 WARN [worker-2] com.example.Queue : "
        let entry = LogEntry(logLine(1, original))
        #expect(entry.compacted.text.plain == "12:34:56.789 WARN Queue : ")
        #expect(entry.presentation.selectedText(NSRange(location: 0, length: entry.compacted.text.plain.utf16.count), original: original) == original)
        let colon = (entry.compacted.text.plain as NSString).range(of: " : ")
        #expect(entry.presentation.selectedText(colon, original: original) == " : ")
    }
    @Test func systemMessagesStayVerbatim() {
        let entry = LogEntry(logLine(1, spring, stream: .sys))
        #expect(entry.compacted == entry)
    }
}
