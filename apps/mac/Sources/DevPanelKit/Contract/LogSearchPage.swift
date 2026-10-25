import Foundation

/// Contract v1.5-A: a bounded page from one retained-log snapshot.
public struct LogSearchMatch: Codable, Hashable, Sendable, Identifiable {
    public var line: LogLine
    public var before: [LogLine]
    public var after: [LogLine]
    public var id: Int { line.seq }
}

public struct LogSearchPage: Codable, Hashable, Sendable {
    public var runId: RunID
    public var throughSeq: Int
    public var scannedThroughSeq: Int
    public var hasMore: Bool
    public var truncated: Bool
    public var matches: [LogSearchMatch]
}
