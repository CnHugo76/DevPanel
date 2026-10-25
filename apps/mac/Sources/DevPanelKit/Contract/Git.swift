import Foundation

public struct GitEntry: Codable, Hashable, Sendable, Identifiable {
    public var path: String
    public var origPath: String?
    public var index: String?
    public var worktree: String?
    public var untracked: Bool
    public var conflicted: Bool
    public var sensitiveName: Bool
    public var id: String { path }
}
public struct GitRepository: Codable, Hashable, Sendable {
    public var root: String
    public var branch: String?
    public var headSha: String?
    public var upstream: String?
    public var ahead: Int
    public var behind: Int
    public var displayBranch: String { branch ?? headSha.map { String($0.prefix(8)) + "（分离 HEAD）" } ?? "空仓库" }
}
public struct GitStatus: Codable, Hashable, Sendable {
    public var repo: GitRepository?
    public var entries: [GitEntry]
    public var truncated: Bool
    public var checkedAt: Timestamp
    public var summary: String? {
        guard let repo else { return nil }
        var parts = ["⎇ " + repo.displayBranch, entries.isEmpty ? "无改动" : "\(entries.count) 处改动"]
        if repo.ahead > 0 { parts.append("↑\(repo.ahead)") }
        if repo.behind > 0 { parts.append("↓\(repo.behind)") }
        return parts.joined(separator: " · ")
    }
}
public enum GitDiffLineKind: OpenEnum {
    case context, add, del, meta
    case other(String)
    public static let known: [Self] = [.context, .add, .del, .meta]
    public var rawValue: String { switch self { case .context: "context"; case .add: "add"; case .del: "del"; case .meta: "meta"; case .other(let s): s } }
}
public struct GitDiffLine: Codable, Hashable, Sendable {
    public var kind: GitDiffLineKind
    public var text: String
    public var oldNo: Int?
    public var newNo: Int?
}
public struct GitHunk: Codable, Hashable, Sendable { public var header: String; public var lines: [GitDiffLine] }
public struct GitDiff: Codable, Hashable, Sendable {
    public var baseOid: String? = nil
    public var newOid: String? = nil
    public var path: String
    public var staged: Bool
    public var binary: Bool
    public var oldSize: Int?
    public var newSize: Int?
    public var truncated: Bool
    public var additions: Int
    public var deletions: Int
    public var hunks: [GitHunk]
}
public struct GitStash: Codable, Hashable, Sendable, Identifiable {
    public var ref: String
    public var message: String
    public var branch: String?
    public var createdAt: Timestamp
    public var id: String { ref }
}
public struct GitPathsRequest: Encodable, Sendable { public var paths: [String] }
public struct GitCommitRequest: Encodable, Sendable {
    public var message: String
    public var amend: Bool
    public var expectedHead: String?
    public init(message: String, amend: Bool, expectedHead: String?) { self.message = message; self.amend = amend; self.expectedHead = expectedHead }
    private enum CodingKeys: String, CodingKey { case message, amend, expectedHead }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(message, forKey: .message); try c.encode(amend, forKey: .amend)
        if let expectedHead { try c.encode(expectedHead, forKey: .expectedHead) } else { try c.encodeNil(forKey: .expectedHead) }
    }
}
public struct GitCommitResult: Codable, Hashable, Sendable { public var sha: String; public var output: String }
public struct GitStashRequest: Encodable, Sendable { public var message: String; public var includeUntracked: Bool }
public struct GitStashApplyRequest: Encodable, Sendable { public var ref: String; public var drop: Bool }

public enum GitGroup: String, CaseIterable, Identifiable, Sendable {
    case staged, unstaged, untracked, conflicts
    public var id: String { rawValue }
    public var title: String { switch self { case .staged: "已暂存"; case .unstaged: "未暂存"; case .untracked: "未跟踪"; case .conflicts: "冲突" } }
    public func contains(_ entry: GitEntry) -> Bool {
        switch self {
        case .conflicts: entry.conflicted
        case .staged: entry.index != nil && !entry.conflicted
        case .unstaged: entry.worktree != nil && !entry.conflicted && !entry.untracked
        case .untracked: entry.untracked && !entry.conflicted
        }
    }
}
public struct GitFileKey: Hashable, Sendable, Identifiable {
    public var path: String
    public var staged: Bool
    public var id: String { (staged ? "index:" : "work:") + path }
    public init(path: String, staged: Bool) { self.path = path; self.staged = staged }
}
extension GitEntry {
    public func letter(staged: Bool) -> String {
        if conflicted { return "U" }; if untracked { return "?" }
        switch staged ? index : worktree {
        case "added": return "A"
        case "deleted": return "D"
        case "renamed": return "R"
        case "copied": return "C"
        case "typechange": return "T"
        default: return "M"
        }
    }
}
