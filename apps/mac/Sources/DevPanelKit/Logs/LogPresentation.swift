import Foundation

public enum LogSeverity: String, Sendable {
    case trace, debug, info, warn, error
}

/// Conservative recognition of Java console layouts. Unknown layouts remain verbatim.
/// Ranges are UTF-16 so ANSI, selection and TextKit use the same coordinates.
public struct LogPresentation: Hashable, Sendable {
    public let level: LogSeverity?
    public let levelRange: NSRange?
    public let retained: [NSRange]

    private static let patterns: [NSRegularExpression] = [
        // Spring Boot: date time LEVEL pid --- [application] [thread] logger : message
        #"^\d{4}-\d{2}-\d{2}[T ](\d{2}:\d{2}:\d{2}(?:[.,]\d+)?)(?:Z|[+-]\d{2}:?\d{2})?\s+(TRACE|DEBUG|INFO|WARN|WARNING|ERROR|FATAL|SEVERE)\s+\d+\s+---\s+(?:\[[^\]\r\n]*\]\s*)+([\w.$]+)\s*:\s?(.*)$"#,
        // Logback / Log4j: date time [thread] LEVEL logger - message
        #"^(?:\d{4}-\d{2}-\d{2}[T ])?(\d{2}:\d{2}:\d{2}(?:[.,]\d+)?)\s+(?:\[[^\]\r\n]*\]\s*)?(TRACE|DEBUG|INFO|WARN|WARNING|ERROR|FATAL|SEVERE)\s+([\w.$]+)\s*(?:-|:)\s?(.*)$"#,
        // Logback variants place the thread after the level.
        #"^(?:\d{4}-\d{2}-\d{2}[T ])?(\d{2}:\d{2}:\d{2}(?:[.,]\d+)?)\s+(TRACE|DEBUG|INFO|WARN|WARNING|ERROR|FATAL|SEVERE)\s+\[[^\]\r\n]*\]\s+([\w.$]+)\s*(?:-|:)\s?(.*)$"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    private static let severity = try! NSRegularExpression(
        pattern: #"^\s*(?:(?:\d{4}-\d{2}-\d{2}[T ])?\d{2}:\d{2}:\d{2}(?:[.,]\d+)?(?:Z|[+-]\d{2}:?\d{2})?\s+)?(?:\[[^\]\r\n]*\]\s+)?\[?(TRACE|DEBUG|INFO|WARN|WARNING|ERROR|FATAL|SEVERE)\b\]?"#,
        options: [.caseInsensitive])

    public init(_ text: String) {
        let source = text as NSString
        let range = NSRange(location: 0, length: source.length)
        let match = Self.patterns.lazy.compactMap { $0.firstMatch(in: text, range: range) }.first
        let levelRange = match?.range(at: 2) ?? Self.severity.firstMatch(in: text, range: range)?.range(at: 1)
        self.levelRange = levelRange
        switch levelRange.map({ source.substring(with: $0).uppercased() }) {
        case "TRACE": level = .trace
        case "DEBUG": level = .debug
        case "INFO": level = .info
        case "WARN", "WARNING": level = .warn
        case "ERROR", "FATAL", "SEVERE": level = .error
        default: level = nil
        }
        if let match {
            let logger = match.range(at: 3)
            let name = source.substring(with: logger) as NSString
            let dot = name.range(of: ".", options: .backwards)
            let start = dot.location == NSNotFound ? 0 : NSMaxRange(dot)
            retained = [match.range(at: 1), match.range(at: 2),
                        NSRange(location: logger.location + start, length: logger.length - start), match.range(at: 4)]
        } else { retained = [] }
    }

    public func compact(_ text: AnsiText) -> AnsiText {
        guard !retained.isEmpty else { return text }
        let source = text.plain as NSString
        var plain = "", runs: [AnsiRun] = []
        for (index, range) in retained.enumerated() {
            if index > 0 { plain += index == 3 ? " : " : " " }
            let offset = plain.utf16.count
            plain += source.substring(with: range)
            for run in text.runs {
                let overlap = NSIntersectionRange(range, NSRange(location: run.location, length: run.length))
                if overlap.length > 0 {
                    runs.append(AnsiRun(location: offset + overlap.location - range.location, length: overlap.length, style: run.style))
                }
            }
        }
        return AnsiText(plain: plain, runs: runs)
    }

    /// Copy a compact selection using its original coordinates, including hidden prefixes
    /// when the selection includes the start of the line.
    public func selectedText(_ range: NSRange, original: String) -> String {
        guard !retained.isEmpty else { return (original as NSString).substring(with: range) }
        let compactLength = retained.reduce(0) { $0 + $1.length } + 5
        if range.location == 0, NSMaxRange(range) >= compactLength { return original }
        var offset = 0
        var start: Int?, end: Int?
        for (index, source) in retained.enumerated() {
            let separator = index == 0 ? 0 : index == 3 ? 3 : 1
            offset += separator
            let overlap = NSIntersectionRange(range, NSRange(location: offset, length: source.length))
            if overlap.length > 0 {
                if start == nil { start = source.location + overlap.location - offset }
                end = source.location + NSMaxRange(overlap) - offset
            }
            offset += source.length
        }
        guard let first = start, let last = end else {
            return (compact(AnsiText(plain: original)).plain as NSString).substring(with: range)
        }
        let lower = range.location == 0 ? 0 : first
        return (original as NSString).substring(with: NSRange(location: lower, length: last - lower))
    }
}
