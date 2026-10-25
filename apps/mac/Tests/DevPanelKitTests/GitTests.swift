import Foundation
import Testing
@testable import DevPanelKit

@Suite("Git state and diff") struct GitTests {
    func entry(_ path: String, index: String? = nil, worktree: String? = nil, untracked: Bool = false, conflicted: Bool = false) -> GitEntry {
        GitEntry(path: path, origPath: nil, index: index, worktree: worktree, untracked: untracked, conflicted: conflicted, sensitiveName: path == ".env")
    }
    func status() -> GitStatus {
        GitStatus(repo: GitRepository(root: "/tmp/repo", branch: "main", headSha: "abc", upstream: "origin/main", ahead: 2, behind: 1), entries: [entry("both", index: "modified", worktree: "modified"), entry("new", untracked: true), entry("conflict", index: "unmerged", worktree: "unmerged", conflicted: true)], truncated: false, checkedAt: "2026-10-21T00:00:00Z")
    }
    @Test func groupingIncludesBothSidesButIsolatesConflicts() {
        let data = status()
        #expect(GitGroup.allCases.map { group in data.entries.filter(group.contains).map(\.path) } == [["both"], ["both"], ["new"], ["conflict"]])
    }
    @Test @MainActor func commandAndShiftSelectionHaveStableDistinctSides() {
        let state = GitState(); state.statuses["p"] = status()
        let files = state.orderedFiles("p")
        state.select(files[0], projectId: "p", additive: false)
        state.select(files[1], projectId: "p", additive: true)
        #expect(state.selections["p"]?.count == 2)
        state.select(files[0], projectId: "p", additive: true)
        #expect(state.selections["p"] == [files[1]])
        state.select(files[3], projectId: "p", additive: false, rangeFrom: files[1])
        #expect(state.selections["p"] == Set(files[1...3]))
    }
    @Test func expectedHeadNullIsRequiredAndEncoded() throws {
        let value = GitCommitRequest(message: "Initial", amend: false, expectedHead: nil)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        #expect(json["expectedHead"] is NSNull)
    }
    @Test func inlineHighlightsUseCharactersAndDoNotOverlap() {
        let change = GitInlineText.pair("你好 👨‍👩‍👧 a尾", "你好 👨‍👩‍👧 b尾")
        #expect(change.0.prefix == "你好 👨‍👩‍👧 ")
        #expect(change.0.changed == "a" && change.1.changed == "b")
        #expect(change.0.suffix == "尾")
        let inserted = GitInlineText.pair("abc", "abcd")
        #expect(inserted.0.changed == "" && inserted.1.changed == "d")
        let same = GitInlineText.pair("a", "a")
        #expect(same.0.changed.isEmpty && same.0.prefix == "a" && same.0.suffix.isEmpty)
    }
    @Test func layoutPairsUnequalBlocksFoldsContextAndPreservesEveryLine() {
        let context = (1...30).map { (number: Int) in GitDiffLine(kind: .context, text: "line \(number)", oldNo: number, newNo: number) }
        let lines = [GitDiffLine(kind: .del, text: "old", oldNo: 1, newNo: nil), GitDiffLine(kind: .add, text: "new", oldNo: nil, newNo: 1), GitDiffLine(kind: .add, text: "extra", oldNo: nil, newNo: 2)] + context + [GitDiffLine(kind: .del, text: "end", oldNo: 40, newNo: nil)]
        let diff = GitDiff(path: "f", staged: false, binary: false, oldSize: nil, newSize: nil, truncated: false, additions: 2, deletions: 2, hunks: [GitHunk(header: "@@", lines: lines)])
        let layout = GitDiffLayout(diff)
        #expect(layout.rows.count == 33)
        #expect(layout.rows[0].old?.text == "old" && layout.rows[0].new?.text == "new")
        #expect(layout.rows[1].old == nil && layout.rows[1].new?.text == "extra")
        #expect(layout.changes == [0, 32])
        #expect(layout.chunks.filter(\.folded).first?.rows.count == 24)
        #expect(layout.chunks.flatMap(\.rows).map(\.id) == layout.rows.map(\.id))
    }
    @Test func errorsPreserveHookAndLockEvidence() {
        let hook = GitFailure(ApiError(code: .other("GIT_HOOK_FAILED"), message: "Hook failed", details: ["output": .string("pre-commit rejected")]))
        #expect(hook.output == "pre-commit rejected")
        #expect(hook.title.contains("钩子"))
        let lock = GitFailure(ApiError(code: .other("GIT_LOCKED"), message: "index.lock"))
        #expect(lock.title.contains("不会删除锁文件"))
    }
    @Test @MainActor func sensitiveConfirmationCapturesDisplayedHeadAndConflictBlocksShortcut() async throws {
        let fixture = AppModelTests()
        fixture.daemon.enqueue(.stream(try fixture.daemon.connectedStream()))
        let app = fixture.makeModel(); app.start(); defer { app.stop() }
        await eventually { app.isConnected }
        var value = status(); value.entries = [entry(".env", index: "added")]
        app.git.statuses["p"] = value; app.git.messages["p"] = "save"
        app.requestGitCommit("p")
        #expect(app.git.confirmation?.sensitivePaths == [".env"])
        #expect(app.git.confirmation?.request.expectedHead == "abc")
        value.repo?.headSha = "new-head"; app.git.statuses["p"] = value
        #expect(app.git.confirmation?.request.expectedHead == "abc")
        app.git.confirmation = nil; app.git.statuses["p"] = status()
        let before = fixture.daemon.transport.requests.current.filter { $0.httpMethod == "POST" }.count
        app.requestGitCommit("p")
        #expect(app.git.confirmation == nil)
        #expect(fixture.daemon.transport.requests.current.filter { $0.httpMethod == "POST" }.count == before)
    }
    @Test @MainActor func pollingSharesVisibleLeasesAndStopsHiddenBackgroundDisconnected() async throws {
        let fixture = AppModelTests()
        let stream = try fixture.daemon.connectedStream()
        fixture.daemon.enqueue(.stream(stream))
        let payload = try JSONEncoder().encode(status())
        fixture.daemon.transport.setHandler { request in
            if request.url?.path.hasSuffix("/git/status") == true { return (200, payload) }
            return (200, Data("[]".utf8))
        }
        let app = fixture.makeModel(); app.start(); defer { app.stop() }
        await eventually { app.isConnected }
        let poller = GitRefreshCoordinator(model: app, sleep: { try await Task.sleep(for: .milliseconds(25)) })
        let token = UUID()
        let states = [GitSurfaceVisibility(viewportVisible: false, windowForeground: true, applicationActive: true), GitSurfaceVisibility(viewportVisible: true, windowForeground: false, applicationActive: true), GitSurfaceVisibility(viewportVisible: true, windowForeground: true, applicationActive: false)]
        for state in states {
            poller.set(token, project: "p", page: false, file: nil, visibility: state)
            try await Task.sleep(for: .milliseconds(40))
            #expect(poller.refreshCount == 0)
        }
        let visible = GitSurfaceVisibility(viewportVisible: true, windowForeground: true, applicationActive: true)
        poller.set(token, project: "p", page: false, file: nil, visibility: visible)
        // Wait for the second request to settle before asserting no further hidden polling.
        await eventually { poller.refreshCount >= 2 && !app.git.loading.contains("p") }
        poller.set(token, project: "p", page: false, file: nil, visibility: .hidden)
        let stopped = poller.refreshCount
        let requests = fixture.daemon.transport.requests.current.filter { $0.url?.path.hasSuffix("/git/status") == true }.count
        #expect(requests > 0)
        try await Task.sleep(for: .milliseconds(80))
        #expect(poller.refreshCount == stopped)
        fixture.discovery.withLock { $0 = nil }; stream.finish(throwing: URLError(.networkConnectionLost))
        await eventually { !app.isConnected }
        poller.reconcile()
        poller.set(token, project: "p", page: true, file: nil, visibility: visible)
        try await Task.sleep(for: .milliseconds(80))
        #expect(poller.refreshCount == stopped)
        #expect(fixture.daemon.transport.requests.current.filter { $0.url?.path.hasSuffix("/git/status") == true }.count == requests)
    }
    @Test func gitRoutesEncodeUnicodeAndMutationsCarryUIHeader() async throws {
        let statusData = try JSONEncoder().encode(status())
        let diff = GitDiff(path: "中文 空格?.txt", staged: true, binary: false, oldSize: nil, newSize: nil, truncated: false, additions: 0, deletions: 0, hunks: [])
        let diffData = try JSONEncoder().encode(diff)
        let transport = FakeTransport { request in
            if request.url!.path.hasSuffix("/diff") { return (200, diffData) }
            if request.url!.path.hasSuffix("/commit") { return (200, Data(#"{"sha":"abc","output":"done"}"#.utf8)) }
            if request.url!.path.hasSuffix("/stashes") { return (200, Data("[]".utf8)) }
            return (200, statusData)
        }
        let client = testClient(transport)
        _ = try await client.gitStatus("p")
        _ = try await client.gitDiff("p", file: GitFileKey(path: diff.path, staged: true))
        _ = try await client.gitStage("p", paths: ["a"], staged: true)
        _ = try await client.gitStage("p", paths: ["a"], staged: false)
        _ = try await client.gitCommit("p", request: GitCommitRequest(message: "test", amend: false, expectedHead: "abc"))
        _ = try await client.gitStash("p", message: "save", includeUntracked: true)
        _ = try await client.gitApplyStash("p", ref: "stash@{0}", drop: false)
        _ = try await client.gitStashes("p")
        let requests = transport.requests.current
        let query = URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)?.queryItems
        #expect(query?.first { $0.name == "path" }?.value == diff.path)
        #expect(query?.first { $0.name == "context" }?.value == "all")
        #expect(requests[4].timeoutInterval > 120)
        for request in requests where request.httpMethod == "POST" { #expect(request.value(forHTTPHeaderField: "X-DevPanel-Client") == "ui") }
        #expect(requests.map { $0.url!.lastPathComponent } == ["status", "diff", "stage", "unstage", "commit", "stash", "apply", "stashes"])
    }
    @Test func summaryHidesNonrepositoriesAndZeroDivergenceSides() {
        var value = status(); value.repo = nil
        #expect(value.summary == nil)
        value = status(); value.entries = []; value.repo?.ahead = 0; value.repo?.behind = 0
        #expect(value.summary == "⎇ main · 无改动")
        value.repo?.ahead = 2
        #expect(value.summary == "⎇ main · 无改动 · ↑2")
        value.repo?.ahead = 0; value.repo?.behind = 3
        #expect(value.summary == "⎇ main · 无改动 · ↓3")
    }

}
