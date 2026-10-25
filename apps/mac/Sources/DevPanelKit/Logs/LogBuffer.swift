import Foundation

/// One log line with its ANSI styles parsed once (on arrival, off the main thread).
public struct LogEntry: Hashable, Sendable {
    public let line: LogLine
    public let text: AnsiText
    public let presentation: LogPresentation

    public init(_ line: LogLine) {
        self.line = line
        self.text = Ansi.parse(line.text)
        self.presentation = LogPresentation(self.text.plain)
    }

    private init(line: LogLine, text: AnsiText) {
        self.line = line; self.text = text; self.presentation = LogPresentation(text.plain)
    }
    public var compacted: LogEntry {
        guard line.stream != .sys, !presentation.retained.isEmpty else { return self }
        return LogEntry(line: line, text: presentation.compact(text))
    }

    public var seq: Int { line.seq }

    /// Shown before `sys` lines (ui-design v1 §5.4).
    public static let sysPrefix = "devpanel › "

    /// "devpanel › " for `sys` lines, else "".
    public var prefix: String { line.stream == .sys ? Self.sysPrefix : "" }

    /// What the view shows and copies: prefix + text without escape sequences.
    public var displayText: String { prefix + text.plain }

    /// Parses lines off the caller's actor.
    public static func parse(_ lines: [LogLine]) async -> [LogEntry] {
        if lines.count < 64 { return lines.map(LogEntry.init) }
        return await Task.detached(priority: .userInitiated) { lines.map(LogEntry.init) }.value
    }
}

/// Bounded, seq-ordered window over one run's lines (ported from apps/ui/src/logs/buffer.ts).
///
/// - Live lines are appended (deduplicated by seq); beyond `cap` the oldest are dropped from
///   memory (still on the daemon → `hasMoreBefore`, reloadable with `before=` pages).
/// - Older pages can be prepended; if that overflows `cap`, the newest lines are dropped and the
///   window becomes `detached` from the live tail until newer pages are loaded again.
public struct LogBuffer: Sendable {
    /// ui-design v2 §1: each run keeps at most 50 000 lines in memory.
    public static let defaultCap = 50_000

    public let cap: Int
    /// `storage[head...]` is the window; dropping from the front only moves `head`.
    private var storage: [LogEntry] = []
    private var head = 0

    /// Older lines exist on the daemon before `firstSeq`.
    public private(set) var hasMoreBefore = false
    /// Newer lines exist on the daemon after `lastSeq` (the window is not at the live tail).
    public private(set) var detached = false
    /// Lines dropped from the front because of `cap` (not daemon-side truncation), in total.
    public private(set) var droppedFront = 0
    /// Live appends whose first new seq skipped ahead of `lastSeq + 1`.
    public private(set) var discontinuities = 0

    public init(cap: Int = LogBuffer.defaultCap) {
        self.cap = max(cap, 1)
    }

    public var count: Int { storage.count - head }
    public var isEmpty: Bool { count == 0 }
    /// The window, oldest first. Indices are `storage` indices: use `entry(at:)` for 0-based access.
    public var entries: ArraySlice<LogEntry> { storage[head...] }
    public var firstSeq: Int? { isEmpty ? nil : storage[head].seq }
    public var lastSeq: Int? { isEmpty ? nil : storage[storage.count - 1].seq }
    /// Lines were dropped from memory because of `cap`.
    public var localTrimmed: Bool { droppedFront > 0 }

    /// 0-based within the window.
    public func entry(at index: Int) -> LogEntry { storage[head + index] }

    /// 0-based index of the first entry with `seq >= seq` (== count when none).
    public func firstIndex(seqAtLeast seq: Int) -> Int {
        var lo = head
        var hi = storage.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if storage[mid].seq < seq { lo = mid + 1 } else { hi = mid }
        }
        return lo - head
    }

    /// 0-based index of the entry with exactly this seq.
    public func index(ofSeq seq: Int) -> Int? {
        let i = firstIndex(seqAtLeast: seq)
        return i < count && entry(at: i).seq == seq ? i : nil
    }

    /// Entries from 0-based `from` to the end.
    public func suffix(from index: Int) -> ArraySlice<LogEntry> { storage[(head + index)...] }
    /// The first `n` entries.
    public func prefix(_ n: Int) -> ArraySlice<LogEntry> { storage[head..<(head + n)] }

    public mutating func reset(_ entries: [LogEntry] = [], hasMoreBefore: Bool = false) {
        storage = Self.normalize(entries)
        head = 0
        self.hasMoreBefore = hasMoreBefore
        detached = false
        droppedFront = 0
        discontinuities = 0
        trimFront()
    }

    /// Live append. Returns the number of lines added (0 while detached).
    @discardableResult
    public mutating func append(_ incoming: [LogEntry]) -> Int {
        guard !detached, !incoming.isEmpty else { return 0 }
        var last = lastSeq ?? 0
        let hadLines = !isEmpty
        var added = 0
        for e in incoming where e.seq > last {  // tolerate replays and out-of-order duplicates
            if added == 0, hadLines, e.seq > last + 1 { discontinuities += 1 }
            storage.append(e)
            last = e.seq
            added += 1
        }
        if added > 0 { trimFront() }
        return added
    }

    /// Inserts an older page (lines with seq < firstSeq). Returns the number of lines added.
    @discardableResult
    public mutating func prepend(_ page: [LogEntry], hasMoreBefore: Bool) -> Int {
        let first = firstSeq ?? Int.max
        let older = Self.normalize(page).filter { $0.seq < first }
        self.hasMoreBefore = hasMoreBefore
        guard !older.isEmpty else { return 0 }
        storage = older + storage[head...]
        head = 0
        if storage.count > cap {
            storage.removeLast(storage.count - cap)  // drop newest
            detached = true
        }
        return older.count
    }

    /// While detached: appends a newer page fetched with `after=lastSeq`.
    @discardableResult
    public mutating func appendPage(_ page: [LogEntry], hasMoreAfter: Bool) -> Int {
        let wasDetached = detached
        detached = false
        let added = append(Self.normalize(page))
        detached = wasDetached && hasMoreAfter
        return added
    }

    private mutating func trimFront() {
        let over = count - cap
        guard over > 0 else { return }
        head += over
        hasMoreBefore = true
        droppedFront += over
        // Compact once the dead prefix is large; amortized O(1) per line.
        if head > max(cap / 2, 1024) {
            storage.removeFirst(head)
            head = 0
        }
    }

    static func normalize(_ lines: [LogEntry]) -> [LogEntry] {
        var sorted = true
        var prev = Int.min
        for l in lines {
            if l.seq <= prev { sorted = false; break }
            prev = l.seq
        }
        if sorted { return lines }
        var out: [LogEntry] = []
        out.reserveCapacity(lines.count)
        prev = Int.min
        for l in lines.sorted(by: { $0.seq < $1.seq }) where l.seq != prev {
            out.append(l)
            prev = l.seq
        }
        return out
    }
}
