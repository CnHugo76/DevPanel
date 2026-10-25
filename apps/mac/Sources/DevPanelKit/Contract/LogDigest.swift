import Foundation

public enum LogDigestBlockKind: OpenEnum {
    case error, tail, other(String)
    public static let known: [Self] = [.error, .tail]
    public var rawValue: String {
        switch self {
        case .error: "error"
        case .tail: "tail"
        case .other(let value): value
        }
    }
}

public struct DigestLine: Codable, Equatable, Sendable {
    public var seq: Int
    public var stream: LogStream
    public var text: String
    public var repeatCount: Int?
    public var folded: Folded?
    public struct Folded: Codable, Equatable, Sendable { public var lines: Int; public var lastSeq: Int }
    enum CodingKeys: String, CodingKey { case seq, stream, text, repeatCount = "repeat", folded }
}
public struct LogDigestBlock: Codable, Equatable, Sendable {
    public var kind: LogDigestBlockKind
    public var firstSeq: Int
    public var lastSeq: Int
    public var occurrences: Int
    public var lastOccurrenceSeq: Int
    public var lines: [DigestLine]
}
public struct LogDigest: Codable, Equatable, Sendable {
    public var runId: RunID
    public var afterSeq: Int?
    public var lastSeq: Int?
    public var scannedLines: Int
    public var errorBlocks: Int
    public var blocks: [LogDigestBlock]
    public var omitted: Omitted
    public var truncated: Bool
    public var runEnded: Bool
    public struct Omitted: Codable, Equatable, Sendable { public var errorBlocks: Int; public var bytes: Int }
    public var text: String {
        var result = ["[digest \(runId) · 行 \((lastSeq ?? 0) - scannedLines + 1)–\(lastSeq ?? 0) · 错误块 \(errorBlocks)，省略 \(omitted.errorBlocks) · 省略 \(omitted.bytes) 字节]"]
        if truncated { result.append("[较早的日志已被上限丢弃]") }
        for block in blocks {
            result.append(block.kind == .error ? "── ERROR ×\(block.occurrences) · 行 \(block.firstSeq)，最后 \(block.lastOccurrenceSeq) ──" : "── 末尾 \(block.lastSeq - block.firstSeq + 1) 行 ──")
            for line in block.lines {
                let stream = line.stream == .out ? "O" : line.stream == .err ? "E" : "S"
                let repeated = (line.repeatCount ?? 1) >= 2 ? "  ×\(line.repeatCount!)" : ""
                result.append("\(line.seq) \(stream) \(line.text)\(repeated)")
                if let folded = line.folded { result.append("      … 省略 \(folded.lines) 行堆栈") }
            }
        }
        return result.joined(separator: "\n")
    }
}
