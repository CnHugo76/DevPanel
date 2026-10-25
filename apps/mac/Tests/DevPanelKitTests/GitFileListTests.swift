import Foundation
import Testing
@testable import DevPanelKit

@Suite("Git change browser") struct GitFileListTests {
    private func entry(_ path: String, index: String? = nil, worktree: String? = "modified", untracked: Bool = false, conflicted: Bool = false) -> GitEntry {
        GitEntry(path: path, origPath: nil, index: index, worktree: worktree, untracked: untracked, conflicted: conflicted, sensitiveName: false)
    }

    @Test func statusDescribesEachSideRatherThanStagingColor() {
        let addedThenModified = entry("new.java", index: "added", worktree: "modified")
        #expect(addedThenModified.changeKind(staged: true) == .added)
        #expect(addedThenModified.changeKind(staged: false) == .modified)
        let modifiedThenDeleted = entry("old.java", index: "modified", worktree: "deleted")
        #expect(modifiedThenDeleted.changeKind(staged: true) == .modified)
        #expect(modifiedThenDeleted.changeKind(staged: false) == .deleted)
        #expect(entry("conflict", index: "added", conflicted: true).changeKind(staged: true) == .conflicted)
        #expect(entry("new", untracked: true).changeKind(staged: false) == .untracked)
    }

    @Test func treePreservesExactPathsAndCountsWhileCollapsingOnlyItsDescendants() {
        let entries = [entry("backend/src/a.java"), entry("backend/test/a.java"), entry("frontend/src/a.ts"), entry("notes ü\n.md")]
        let rows = GitFileList.rows(entries, layout: .tree, collapsed: ["backend/src"])
        #expect(rows.filter { $0.directory != nil }.map(\.directory) == ["backend", "backend/src", "backend/test", "frontend", "frontend/src"])
        #expect(rows.first?.count == 2)
        #expect(rows.compactMap(\.entry).map(\.path) == ["backend/test/a.java", "frontend/src/a.ts", "notes ü\n.md"])
        #expect(rows.first(where: { $0.entry?.path == "backend/test/a.java" })?.depth == 2)
        #expect(Set(rows.map(\.id)).count == rows.count)
        let open = GitFileList.rows(entries, layout: .tree)
        #expect(Set(open.compactMap(\.entry)) == Set(entries))
    }

    @Test func topLevelGroupsArePathGroupsWithoutInventingBusinessModules() {
        let entries = [entry("backend/src/A.java"), entry("backend/tests/A.java"), entry("frontend/A.ts"), entry("README.md")]
        let rows = GitFileList.rows(entries, layout: .directories, collapsed: ["backend"])
        #expect(rows.filter { $0.directory != nil }.map(\.title) == ["仓库根目录", "backend", "frontend"])
        #expect(rows.first(where: { $0.directory == "backend" })?.count == 2)
        #expect(rows.compactMap(\.entry).map(\.path) == ["README.md", "frontend/A.ts"])
        #expect(rows.compactMap(\.entry).allSatisfy { !$0.path.hasPrefix("backend/") })
    }

    @Test func compactTreeKeepsTopLevelAndHonorsCollapsedAncestors() {
        let entries = [entry("backend/src/main/java/Order.java")]
        let rows = GitFileList.rows(entries, layout: .tree)
        #expect(rows.filter { $0.directory != nil }.map(\.title) == ["backend", "src/main/java"])
        #expect(rows.last?.entry?.path == entries[0].path)
        let collapsed = GitFileList.rows(entries, layout: .tree, collapsed: ["backend/src/main"])
        #expect(collapsed.map(\.title) == ["backend", "src/main"])
        #expect(collapsed.last?.count == 1)
        #expect(collapsed.compactMap(\.entry).isEmpty)
    }

    @Test @MainActor func shiftSelectFollowsVisibleTreeOrderAndKeepsIndexDistinct() {
        let state = GitState()
        let index = GitFileKey(path: "backend/A.java", staged: true)
        let work = GitFileKey(path: "backend/A.java", staged: false)
        let front = GitFileKey(path: "frontend/B.ts", staged: false)
        let visible = [index, front, work]
        state.select(index, projectId: "p", additive: false)
        state.select(front, projectId: "p", additive: false, rangeFrom: index, order: visible)
        #expect(state.selections["p"] == [index, front])
        state.select(work, projectId: "p", additive: true, order: visible)
        #expect(state.selections["p"] == Set(visible))
        state.select(work, projectId: "p", additive: false, rangeFrom: index, order: [front, work])
        #expect(state.selections["p"] == [work])
    }

    @Test func largeTreeDoesNotDropFilesOrMixSameBasenames() {
        let entries = (0..<5_000).map { entry("module\($0 % 20)/src/file\($0).java") }
        let rows = GitFileList.rows(entries.reversed(), layout: .tree)
        #expect(rows.compactMap(\.entry).count == 5_000)
        #expect(rows.filter { $0.depth == 0 && $0.directory != nil }.allSatisfy { $0.count == 250 })
        #expect(Set(rows.map(\.id)).count == rows.count)
    }
}
