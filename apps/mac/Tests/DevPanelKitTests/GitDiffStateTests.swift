import Foundation
import Testing
@testable import DevPanelKit

@Suite("Diff window state") @MainActor struct GitDiffStateTests {
    func diff(_ file: GitFileKey, oid: String = "new") -> GitDiff {
        GitDiff(baseOid: "base", newOid: oid, path: file.path, staged: file.staged, binary: false, oldSize: 4, newSize: 4, truncated: false, additions: 1, deletions: 1, hunks: [GitHunk(header: "@@", lines: [GitDiffLine(kind: .add, text: "new", oldNo: nil, newNo: 1)])])
    }
    @Test(arguments: ["modified", "untracked", "deleted", "renamed", "both-sides"])
    func stagingAndUnstagingShowDestinationDiff(_ path: String) async {
        let state = GitDiffState(file: GitFileKey(path: path, staged: false))
        await state.load(replace: true) { diff($0) }
        var reads: [Bool] = []
        for expected in [true, false] {
            await state.toggleStage(write: { file in
                #expect(file.staged == !expected)
                return true
            }, fetch: { file in reads.append(file.staged); return diff(file) })
            #expect(state.file.staged == expected)
            #expect(state.diff?.staged == expected)
            #expect(state.diff?.hunks.isEmpty == false)
            #expect(state.pending == nil)
        }
        #expect(reads == [true, false])
    }
    @Test func reusingDestinationAdoptsReloadAndDiscardsItsStaleFocusResponse() async {
        let source = GitDiffState(file: GitFileKey(path: "f", staged: false))
        let destination = GitDiffState(file: GitFileKey(path: "f", staged: true))
        await destination.load(replace: true) { diff($0, oid: "old staged content") }
        await destination.load(replace: false) { diff($0, oid: "old pending content") }
        var continuation: CheckedContinuation<GitDiff, Never>?
        let old = Task { await destination.load(replace: false) { _ in await withCheckedContinuation { continuation = $0 } } }
        await eventually { continuation != nil }
        await source.toggleStage(write: { _ in true }, fetch: { diff($0, oid: "new staged content") })
        destination.adoptReplacement(from: source)
        continuation?.resume(returning: diff(destination.file, oid: "stale focus content"))
        await old.value
        #expect(destination.file.staged && destination.diff?.newOid == "new staged content")
        #expect(destination.pending == nil && !destination.loading)
        await destination.load(replace: false) { diff($0, oid: "new staged content") }
        #expect(destination.pending == nil)
    }
    @Test func failedStageRetainsSideAndContent() async {
        let state = GitDiffState(file: GitFileKey(path: "f", staged: false))
        await state.load(replace: true) { diff($0) }
        await state.toggleStage(write: { _ in false }, fetch: { _ in Issue.record("Must not reload after failed write"); throw URLError(.badServerResponse) })
        #expect(!state.file.staged && state.diff?.staged == false && state.pending == nil)
    }
    @Test func staleFocusResponseCannotUndoStageAndFocusChecksAreSuppressedDuringWrite() async {
        let state = GitDiffState(file: GitFileKey(path: "f", staged: false))
        await state.load(replace: true) { diff($0) }
        var continuation: CheckedContinuation<GitDiff, Never>?
        let old = Task { await state.load(replace: false) { _ in await withCheckedContinuation { continuation = $0 } } }
        await eventually { continuation != nil }
        await state.toggleStage(write: { _ in
            await state.load(replace: false) { _ in Issue.record("No focus check while writing"); throw URLError(.cancelled) }
            return true
        }, fetch: { diff($0, oid: "staged") })
        continuation?.resume(returning: diff(GitFileKey(path: "f", staged: false), oid: "stale"))
        await old.value
        #expect(state.diff?.newOid == "staged" && state.file.staged && state.pending == nil && !state.loading)
    }
    @Test func fullContentFingerprintsDetectChangesWithoutFalseBanner() async {
        let state = GitDiffState(file: GitFileKey(path: "f", staged: false))
        await state.load(replace: true) { diff($0) }
        await state.load(replace: false) { diff($0) }
        #expect(state.pending == nil)
        await state.load(replace: false) { diff($0, oid: "changed binary or truncated tail") }
        #expect(state.pending != nil)
        await state.load(replace: true) { diff($0, oid: "changed binary or truncated tail") }
        #expect(state.pending == nil)
    }
    @Test func appModelOwnsDiffReadAndWriteRequests() async throws {
        let fixture = AppModelTests()
        fixture.daemon.enqueue(.stream(try fixture.daemon.connectedStream()))
        let statusData = try JSONEncoder().encode(GitTests().status())
        let file = GitFileKey(path: "中文 空格.txt", staged: false)
        let initial = try JSONEncoder().encode(diff(file))
        let staged = try JSONEncoder().encode(diff(GitFileKey(path: file.path, staged: true)))
        fixture.daemon.transport.setHandler { request in
            if request.url?.path.hasSuffix("/diff") == true {
                return (200, request.url?.query?.contains("staged=true") == true ? staged : initial)
            }
            if request.url?.path.hasSuffix("/stashes") == true { return (200, Data("[]".utf8)) }
            return (200, statusData)
        }
        let model = fixture.makeModel(); model.start(); defer { model.stop() }
        await eventually { model.isConnected }
        let state = GitDiffState(file: file)
        await state.load(replace: true) { try await model.loadGitDiff("p", file: $0) }
        await state.toggleStage(write: { await model.stageGit("p", files: [$0], staged: !$0.staged) }, fetch: { try await model.loadGitDiff("p", file: $0) })
        #expect(state.file.staged && state.diff?.staged == true && state.pending == nil)
        let reads = fixture.daemon.transport.requests.current.filter { $0.url?.path.hasSuffix("/diff") == true }
        #expect(reads.count == 2)
        for read in reads {
            let items = URLComponents(url: read.url!, resolvingAgainstBaseURL: false)?.queryItems
            #expect(items?.first { $0.name == "context" }?.value == "all")
            #expect(items?.first { $0.name == "path" }?.value == file.path)
        }
        model.stop()
        let count = fixture.daemon.transport.requests.current.count
        await state.load(replace: false) { try await model.loadGitDiff("p", file: $0) }
        #expect(state.failure != nil && fixture.daemon.transport.requests.current.count == count)
    }

}
