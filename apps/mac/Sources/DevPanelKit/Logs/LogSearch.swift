import Foundation
import Observation

/// A search hit, in UTF-16 units of the line's `displayText` (prefix included), so the view can
/// map it straight onto its text storage.
public struct LogMatch: Hashable, Sendable {
    public var seq: Int
    public var location: Int
    public var length: Int

    public init(seq: Int, location: Int, length: Int) {
        self.seq = seq
        self.location = location
        self.length = length
    }
}

public enum LogSearch {
    /// Beyond this many hits the count shows "100,000+" and the rest are not collected.
    public static let maxMatches = 100_000

    /// Case-insensitive substring search over the loaded lines (text without ANSI; the `sys`
    /// prefix is not searched).
    public static func find(
        _ entries: some Sequence<LogEntry>, query: String, max limit: Int = maxMatches
    ) -> [LogMatch] {
        guard !query.isEmpty else { return [] }
        var out: [LogMatch] = []
        let q = query as NSString
        let qLength = q.length
        // Fast path for ASCII queries: compare lowercased UTF-16 units directly.
        let asciiQuery = query.utf16.allSatisfy { $0 < 0x80 }
        let needle = asciiQuery ? Array(query.lowercased().utf16) : []
        for e in entries {
            let offset = e.line.stream == .sys ? LogEntry.sysPrefix.utf16.count : 0
            if asciiQuery {
                scanASCII(e.text.plain, needle: needle) { loc in
                    out.append(LogMatch(seq: e.seq, location: offset + loc, length: qLength))
                    return out.count < limit
                }
                if out.count >= limit { return out }
            } else {
                let s = e.text.plain as NSString
                var range = NSRange(location: 0, length: s.length)
                while range.length > 0 {
                    let r = s.range(of: query, options: [.caseInsensitive], range: range)
                    if r.location == NSNotFound { break }
                    out.append(LogMatch(seq: e.seq, location: offset + r.location, length: r.length))
                    if out.count >= limit { return out }
                    let next = r.location + max(r.length, 1)
                    range = NSRange(location: next, length: s.length - next)
                }
            }
        }
        return out
    }

    /// Non-overlapping occurrences of a lowercased ASCII needle in `haystack` (ASCII letters are
    /// folded; other units must match exactly, which is right because the needle is ASCII).
    private static func scanASCII(_ haystack: String, needle: [UInt16], _ hit: (Int) -> Bool) {
        let n = needle.count
        guard n > 0 else { return }
        let first = needle[0]
        var buf: [UInt16] = []
        buf.reserveCapacity(haystack.utf16.count)
        for c in haystack.utf16 { buf.append(c >= 0x41 && c <= 0x5A ? c + 0x20 : c) }
        let count = buf.count
        guard count >= n else { return }
        var i = 0
        let last = count - n
        while i <= last {
            if buf[i] == first {
                var j = 1
                while j < n, buf[i + j] == needle[j] { j += 1 }
                if j == n {
                    if !hit(i) { return }
                    i += n
                    continue
                }
            }
            i += 1
        }
    }

    /// "3 / 27", "0 / 0", "1 / 100,000+".
    public static func counter(current: Int?, total: Int, capped: Bool) -> String {
        guard total > 0, let current else { return "0 / 0" }
        return "\(current + 1) / \(Format.count(total))\(capped ? "+" : "")"
    }

    /// Where the selection goes after the matches were recomputed: the same hit if it still
    /// exists, else the first hit at or after the previous one's line, else the first.
    public static func resolveCurrent(previous: LogMatch?, in matches: [LogMatch]) -> Int {
        guard let previous, !matches.isEmpty else { return 0 }
        if let i = matches.firstIndex(of: previous) { return i }
        return matches.firstIndex { $0.seq >= previous.seq } ?? 0
    }
}

/// Search state of the log view: query, hits over the loaded lines, the current hit.
///
/// Recomputes off the main thread: debounced while typing, throttled (≤ every 300 ms) while
/// lines stream in.
@Observable
@MainActor
public final class LogSearchModel {
    public private(set) var query = ""
    public private(set) var matches: [LogMatch] = []
    public private(set) var currentIndex: Int?
    /// More than `LogSearch.maxMatches` hits.
    public private(set) var capped = false
    /// Bumps whenever `matches` or the current hit change.
    public private(set) var version = 0
    /// Time of the last search (diagnostics).
    public private(set) var lastDuration: Duration?

    @ObservationIgnored private var source: @MainActor () -> LogBuffer = { LogBuffer() }
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var lastRun: ContinuousClock.Instant?
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let throttle: Duration

    public init(debounce: Duration = .milliseconds(120), throttle: Duration = .milliseconds(300)) {
        self.debounce = debounce
        self.throttle = throttle
    }

    public var current: LogMatch? {
        guard let i = currentIndex, matches.indices.contains(i) else { return nil }
        return matches[i]
    }

    public var counterText: String {
        LogSearch.counter(current: currentIndex, total: matches.count, capped: capped)
    }

    /// Where the lines come from (the log session's buffer).
    public func bind(_ source: @escaping @MainActor () -> LogBuffer) {
        self.source = source
    }

    public func setQuery(_ q: String) {
        guard q != query else { return }
        query = q
        if q.isEmpty {
            task?.cancel()
            task = nil
            dirty = false
            matches = []
            currentIndex = nil
            capped = false
            version += 1
            return
        }
        schedule(after: debounce)
    }

    /// The loaded lines changed (appended, trimmed, replaced).
    public func linesChanged() {
        guard !query.isEmpty else { return }
        if task != nil {
            dirty = true
            return
        }
        let wait: Duration
        if let lastRun {
            let elapsed = ContinuousClock.now - lastRun
            wait = elapsed >= throttle ? .zero : throttle - elapsed
        } else {
            wait = .zero
        }
        schedule(after: wait)
    }

    /// Searches now and waits for the result (tests, `--snapshot`).
    public func searchNow() async {
        task?.cancel()
        task = nil
        await run()
    }

    @discardableResult
    public func next() -> LogMatch? { step(1) }

    @discardableResult
    public func previous() -> LogMatch? { step(-1) }

    private func step(_ delta: Int) -> LogMatch? {
        guard !matches.isEmpty else { return nil }
        let i = currentIndex ?? (delta > 0 ? -1 : 0)
        currentIndex = ((i + delta) % matches.count + matches.count) % matches.count
        version += 1
        return current
    }

    private func schedule(after delay: Duration) {
        task?.cancel()
        dirty = false
        task = Task { [weak self] in
            if delay > .zero {
                do { try await Task.sleep(for: delay) } catch { return }
            }
            guard let self, !Task.isCancelled else { return }
            await self.run()
            guard !Task.isCancelled else { return }
            self.task = nil
            if self.dirty {
                self.dirty = false
                self.linesChanged()
            }
        }
    }

    private func run() async {
        let q = query
        guard !q.isEmpty else { return }
        let buffer = source()
        let started = ContinuousClock.now
        let found = await Task.detached(priority: .userInitiated) {
            LogSearch.find(buffer.entries, query: q, max: LogSearch.maxMatches + 1)
        }.value
        guard q == query, !Task.isCancelled else { return }
        lastRun = ContinuousClock.now
        lastDuration = lastRun! - started
        let previous = current
        capped = found.count > LogSearch.maxMatches
        matches = capped ? Array(found.prefix(LogSearch.maxMatches)) : found
        currentIndex = matches.isEmpty ? nil : LogSearch.resolveCurrent(previous: previous, in: matches)
        version += 1
    }
}
