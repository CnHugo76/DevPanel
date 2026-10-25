import Foundation

/// Console-style folding: recognize contiguous stack frames, retain the raw buffer, and
/// project a clickable summary into the display. Exception headlines/cause chains stay visible.
public struct LogFold: Equatable, Sendable {
    public let first: Int
    public let last: Int
    public let count: Int
    public func contains(_ seq: Int) -> Bool { first <= seq && seq <= last }
}

public enum LogFolding {
    public static func regions(in buffer: LogBuffer) -> [LogFold] {
        var result: [LogFold] = []
        var hidden: [Int] = []
        var frames = 0, causeFrames = 0
        var active = false, python = false
        func matches(_ text: String, _ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
        func flush() {
            if let first = hidden.first, let last = hidden.last { result.append(LogFold(first: first, last: last, count: hidden.count)) }
            hidden.removeAll(keepingCapacity: true)
        }
        for entry in buffer.entries {
            let text = entry.text.plain
            let headline = matches(text, #"\b(ERROR|FATAL|SEVERE)\b|^\s*[A-Za-z_$][\w$.]*(Exception|Error)(: |$)|^(Traceback \(most recent call last\):|panic:)"#)
            // A Traceback consumes its final unindented exception line and ends there,
            // even when the exception itself looks like a new error headline.
            if active && python && matches(text, #"^\S"#) { flush(); active = false; python = false; continue }
            if headline { flush(); active = true; frames = 0; causeFrames = 0; python = text.hasPrefix("Traceback (most recent call last):"); continue }
            let frame = matches(text, #"^\s+at "#)
            let cause = matches(text, #"^\s*(Caused by|Suppressed): "#)
            let omitted = matches(text, #"^\s+\.\.\. \d+ (more|common frames omitted)"#)
            let stack = frame || cause || omitted || matches(text, #"^\s+File \""#) || (python && matches(text, #"^\s+\S"#))
            if !stack { flush(); active = false; continue }
            guard active else { continue }
            if cause { flush(); causeFrames = 2; continue }
            if frame {
                frames += 1
                let keep = frames <= 5 || causeFrames > 0
                if causeFrames > 0 { causeFrames -= 1 }
                if keep { flush() } else { hidden.append(entry.seq) }
            } else if omitted { hidden.append(entry.seq) }
            else { flush() }
        }
        flush()
        return result
    }

    public static func project(_ buffer: LogBuffer, collapsed: [LogFold]) -> LogBuffer {
        guard !collapsed.isEmpty else { return buffer }
        var entries: [LogEntry] = []
        var region = 0
        for entry in buffer.entries {
            while region < collapsed.count && collapsed[region].last < entry.seq { region += 1 }
            if region < collapsed.count, collapsed[region].contains(entry.seq) {
                if entry.seq == collapsed[region].first {
                    var line = entry.line
                    line.text = "  ▸ \(collapsed[region].count) 行堆栈 · 点击展开"
                    entries.append(LogEntry(line))
                }
            } else { entries.append(entry) }
        }
        var display = LogBuffer(cap: buffer.cap)
        display.reset(entries)
        return display
    }

    /// Selection copy includes original lines covered by a fold placeholder, never the label.
    public static func selectedText(range: NSRange, display: LogBuffer, raw: LogBuffer, collapsed: [LogFold]) -> String {
        let folds = Dictionary(uniqueKeysWithValues: collapsed.map { ($0.first, $0) })
        var offset = 0
        var result = ""
        for entry in display.entries {
            let line = entry.displayText + "\n"
            let length = line.utf16.count
            let overlap = NSIntersectionRange(range, NSRange(location: offset, length: length))
            if overlap.length > 0 {
                if let fold = folds[entry.seq] {
                    let start = raw.firstIndex(seqAtLeast: fold.first)
                    result += raw.suffix(from: start).prefix(while: { $0.seq <= fold.last }).map { $0.displayText + "\n" }.joined()
                } else if let index = raw.index(ofSeq: entry.seq), raw.entry(at: index).text != entry.text {
                    let original = raw.entry(at: index)
                    let local = NSRange(location: overlap.location - offset, length: overlap.length)
                    let textRange = NSIntersectionRange(local, NSRange(location: 0, length: entry.text.plain.utf16.count))
                    if textRange.length > 0 { result += original.presentation.selectedText(textRange, original: original.text.plain) }
                    if NSMaxRange(local) > entry.text.plain.utf16.count { result += "\n" }
                } else {
                    result += (line as NSString).substring(with: NSRange(location: overlap.location - offset, length: overlap.length))
                }
            }
            offset += length
            if offset >= NSMaxRange(range) { break }
        }
        return result
    }
}
