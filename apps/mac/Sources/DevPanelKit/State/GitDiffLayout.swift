import Foundation

public struct GitInlineText: Equatable, Sendable {
    public var prefix: String
    public var changed: String
    public var suffix: String
    public static func pair(_ old: String, _ new: String) -> (GitInlineText, GitInlineText) {
        let a = Array(old), b = Array(new)
        var head = 0, tail = 0
        while head < min(a.count, b.count), a[head] == b[head] { head += 1 }
        while tail < min(a.count, b.count) - head, a[a.count - tail - 1] == b[b.count - tail - 1] { tail += 1 }
        func split(_ chars: [Character]) -> GitInlineText {
            GitInlineText(prefix: String(chars.prefix(head)), changed: String(chars[head..<(chars.count - tail)]), suffix: String(chars.suffix(tail)))
        }
        return (split(a), split(b))
    }
}
public struct GitDiffRow: Identifiable, Sendable {
    public var id: Int
    public var old: GitDiffLine?
    public var new: GitDiffLine?
    public var changed: Bool { old?.kind == .del || new?.kind == .add }
}
public struct GitDiffChunk: Identifiable, Sendable {
    public var id: Int
    public var rows: [GitDiffRow]
    public var folded: Bool
}
public struct GitDiffLayout: Sendable {
    public var rows: [GitDiffRow]
    public var changes: [Int]
    public var chunks: [GitDiffChunk]
    public init(_ diff: GitDiff) {
        var result: [GitDiffRow] = []
        for hunk in diff.hunks {
            let lines = hunk.lines
            var index = 0
            while index < lines.count {
                let line = lines[index]
                if line.kind == .del || line.kind == .add {
                    var old: [GitDiffLine] = [], new: [GitDiffLine] = []
                    while index < lines.count, lines[index].kind == .del || lines[index].kind == .add {
                        if lines[index].kind == .del { old.append(lines[index]) } else { new.append(lines[index]) }; index += 1
                    }
                    for offset in 0..<max(old.count, new.count) { result.append(GitDiffRow(id: result.count, old: offset < old.count ? old[offset] : nil, new: offset < new.count ? new[offset] : nil)) }
                } else {
                    result.append(GitDiffRow(id: result.count, old: line, new: line)); index += 1
                }
            }
        }
        rows = result
        changes = result.indices.filter { result[$0].changed && ($0 == 0 || !result[$0 - 1].changed) }
        var parts: [GitDiffChunk] = [], index = 0
        while index < result.count {
            let start = index, unchanged = !result[index].changed
            while index < result.count, !result[index].changed == unchanged { index += 1 }
            let block = Array(result[start..<index])
            if unchanged && block.count > 12 {
                parts.append(GitDiffChunk(id: start, rows: Array(block.prefix(3)), folded: false))
                parts.append(GitDiffChunk(id: start + 3, rows: Array(block.dropFirst(3).dropLast(3)), folded: true))
                parts.append(GitDiffChunk(id: index - 3, rows: Array(block.suffix(3)), folded: false))
            } else { parts.append(GitDiffChunk(id: start, rows: block, folded: false)) }
        }
        chunks = parts
    }
}
