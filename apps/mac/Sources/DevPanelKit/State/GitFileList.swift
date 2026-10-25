import Foundation

/// Presentation only: a file can have different changes in the index and worktree.
public enum GitChangeKind: String, CaseIterable, Identifiable, Sendable {
    case modified, added, deleted, renamed, copied, typechange, untracked, conflicted
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .modified: "修改"
        case .added: "新增"
        case .deleted: "删除"
        case .renamed: "重命名"
        case .copied: "复制"
        case .typechange: "类型变化"
        case .untracked: "未跟踪"
        case .conflicted: "冲突"
        }
    }
}

extension GitEntry {
    public func changeKind(staged: Bool) -> GitChangeKind {
        if conflicted { return .conflicted }
        if untracked { return .untracked }
        return GitChangeKind(rawValue: (staged ? index : worktree) ?? "modified") ?? .modified
    }
}

public enum GitFileListLayout: String, CaseIterable, Identifiable, Sendable {
    case flat, tree, directories
    public var id: String { rawValue }
    public var title: String {
        switch self { case .flat: "平铺"; case .tree: "目录树"; case .directories: "目录分组" }
    }
}

public struct GitFileListRow: Identifiable, Sendable {
    public var id: String
    public var title: String
    public var depth: Int
    /// nil for files; empty string denotes the repository root group.
    public var directory: String?
    public var entry: GitEntry?
    public var count: Int
}

/// Groups existing Git paths only. It never discovers repositories or infers business modules.
public enum GitFileList {
    public static func rows(
        _ entries: [GitEntry], layout: GitFileListLayout, collapsed: Set<String> = []
    ) -> [GitFileListRow] {
        let sorted = entries.sorted { $0.path < $1.path }
        func file(_ entry: GitEntry, depth: Int) -> GitFileListRow {
            GitFileListRow(id: "file:" + entry.path, title: entry.path.components(separatedBy: "/").last ?? entry.path,
                           depth: depth, directory: nil, entry: entry, count: 1)
        }
        func folder(_ path: String, title: String, depth: Int, count: Int) -> GitFileListRow {
            GitFileListRow(id: "dir:" + path, title: title, depth: depth, directory: path, entry: nil, count: count)
        }
        switch layout {
        case .flat:
            return sorted.map { file($0, depth: 0) }
        case .directories:
            let groups = Dictionary(grouping: sorted) { entry in
                entry.path.contains("/") ? String(entry.path.prefix { $0 != "/" }) : ""
            }
            return groups.keys.sorted().flatMap { path -> [GitFileListRow] in
                let children = groups[path] ?? []
                let header = folder(path, title: path.isEmpty ? "仓库根目录" : path, depth: 0, count: children.count)
                return [header] + (collapsed.contains(path) ? [] : children.map { file($0, depth: 1) })
            }
        case .tree:
            let root = Directory()
            for entry in sorted {
                let parts = entry.path.split(separator: "/").map(String.init)
                var node = root
                node.count += 1
                for part in parts.dropLast() {
                    if node.children[part] == nil { node.children[part] = Directory() }
                    node = node.children[part]!
                    node.count += 1
                }
                node.files.append(entry)
            }
            var result: [GitFileListRow] = []
            func visit(_ node: Directory, path: String, depth: Int) {
                for name in node.children.keys.sorted() {
                    guard var child = node.children[name] else { continue }
                    var childPath = path.isEmpty ? name : path + "/" + name
                    var title = name
                    // Keep the top-level directory visible, compact single-child paths below it.
                    while depth > 0, child.files.isEmpty, child.children.count == 1,
                          !collapsed.contains(childPath), let next = child.children.keys.first, let descendant = child.children[next] {
                        childPath += "/" + next
                        title += "/" + next
                        child = descendant
                    }
                    result.append(folder(childPath, title: title, depth: depth, count: child.count))
                    if !collapsed.contains(childPath) { visit(child, path: childPath, depth: depth + 1) }
                }
                result.append(contentsOf: node.files.map { file($0, depth: depth) })
            }
            visit(root, path: "", depth: 0)
            return result
        }
    }

    private final class Directory {
        var children: [String: Directory] = [:]
        var files: [GitEntry] = []
        var count = 0
    }
}
