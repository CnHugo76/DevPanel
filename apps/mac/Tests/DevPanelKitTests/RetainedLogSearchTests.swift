import Foundation
import Testing
@testable import DevPanelKit

private func searchPage(_ run: RunID = "r_1", through: Int = 100, scanned: Int = 100,
                        more: Bool = false, seq: Int? = nil, truncated: Bool = false) -> LogSearchPage {
    LogSearchPage(runId: run, throughSeq: through, scannedThroughSeq: scanned, hasMore: more, truncated: truncated,
                  matches: seq.map { [LogSearchMatch(line: LogLine(seq: $0, ts: "now", stream: .err, text: "ERROR"), before: [], after: [])] } ?? [])
}

private actor DeferredSearch {
    private var continuations: [CheckedContinuation<LogSearchPage, any Error>] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func receive(_ request: RetainedLogSearch.Request) async throws -> LogSearchPage {
        try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
            let ready = waiters.filter { $0.0 <= continuations.count }
            waiters.removeAll { $0.0 <= continuations.count }
            for (_, waiter) in ready { waiter.resume() }
        }
    }
    func waitForRequests(_ count: Int) async {
        if continuations.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
    func finish(_ index: Int, with page: LogSearchPage) { continuations[index].resume(returning: page) }
}

@Suite("Retained log search") @MainActor
struct RetainedLogSearchTests {
    @Test func freezesSnapshotAndPaginatesEmptyPagesWithoutAccumulatingLiveLogs() async {
        let search = RetainedLogSearch()
        let requests = Locked<[RetainedLogSearch.Request]>([])
        let fetch: RetainedLogSearch.Fetch = { request in
            requests.withLock { $0.append(request) }
            if request.after == 0 { return searchPage(scanned: 25, more: true, seq: 10, truncated: true) }
            if request.after == 25 { return searchPage(scanned: 60, more: true) }
            return searchPage(seq: 90)
        }
        await search.search(runId: "r_1", query: "ERROR", caseSensitive: true, fetch: fetch)
        #expect(search.page?.matches.map(\.line.seq) == [10])
        #expect(search.page?.truncated == true)
        await search.next(fetch: fetch)
        #expect(search.page?.matches.isEmpty == true)
        #expect(search.canGoForward)
        await search.next(fetch: fetch)
        #expect(search.page?.matches.map(\.line.seq) == [90])
        #expect(search.pageNumber == 3)
        #expect(!search.canGoForward)
        await search.previous(fetch: fetch)
        #expect(search.pageNumber == 2)
        #expect(requests.current.map(\.after) == [0, 25, 60, 25])
        #expect(requests.current.map(\.through) == [nil, 100, 100, 100])
        #expect(requests.current.allSatisfy { $0.query == "ERROR" && $0.caseSensitive })
    }

    @Test func runChangeAndLateResponseNeverReplaceNewResults() async {
        let search = RetainedLogSearch()
        let gate = DeferredSearch()
        let fetch: RetainedLogSearch.Fetch = { try await gate.receive($0) }
        let old = Task { await search.search(runId: "old", query: "before", caseSensitive: false, fetch: fetch) }
        await gate.waitForRequests(1)
        let new = Task { await search.search(runId: "new", query: "after", caseSensitive: false, fetch: fetch) }
        await gate.waitForRequests(2)
        await gate.finish(1, with: searchPage("new", seq: 88))
        await new.value
        await gate.finish(0, with: searchPage("old", seq: 11))
        await old.value
        #expect(search.page?.runId == "new")
        #expect(search.page?.matches.map(\.line.seq) == [88])
        #expect(search.request?.query == "after")
        #expect(!search.loading)
    }

    @Test func dismissalInvalidatesUncooperativeTransport() async {
        let search = RetainedLogSearch()
        let gate = DeferredSearch()
        let pending = Task { await search.search(runId: "r_1", query: "x", caseSensitive: false) { try await gate.receive($0) } }
        await gate.waitForRequests(1)
        search.cancel()
        await gate.finish(0, with: searchPage(seq: 55))
        await pending.value
        #expect(search.page == nil)
        #expect(search.request == nil)
        #expect(!search.loading && !search.hasSearched)
    }

    @Test func retryUsesFailedPageCursorAndFrozenUpperBound() async {
        let search = RetainedLogSearch()
        let requests = Locked<[RetainedLogSearch.Request]>([])
        let fetch: RetainedLogSearch.Fetch = { request in
            let count = requests.withLock { $0.append(request); return $0.count }
            if count == 2 { throw ApiError(code: .daemonUnreachable, message: "offline") }
            return request.after == 0 ? searchPage(scanned: 30, more: true) : searchPage(seq: 80)
        }
        await search.search(runId: "r_1", query: "x", caseSensitive: false, fetch: fetch)
        await search.next(fetch: fetch)
        #expect(search.error != nil)
        #expect(search.pageNumber == 1)
        await search.retry(fetch: fetch)
        #expect(search.error == nil)
        #expect(search.pageNumber == 2)
        #expect(requests.current.map(\.after) == [0, 30, 30])
        #expect(requests.current.map(\.through) == [nil, 100, 100])
    }

    @Test func rejectsMismatchedRunAndNonAdvancingCursor() async {
        let search = RetainedLogSearch()
        await search.search(runId: "r_1", query: "x", caseSensitive: false) { _ in searchPage("wrong") }
        #expect(search.error != nil && search.page == nil)
        await search.search(runId: "r_1", query: "x", caseSensitive: false) { _ in searchPage(scanned: 0, more: true) }
        #expect(search.error != nil && search.page == nil)
        await search.search(runId: "r_1", query: "", caseSensitive: false) { _ in Issue.record("invalid input reached fetch"); return searchPage() }
        #expect(search.error != nil)
    }

    @Test func queryLimitCountsUnicodeScalars() async {
        let search = RetainedLogSearch()
        let requests = Locked<[RetainedLogSearch.Request]>([])
        let fetch: RetainedLogSearch.Fetch = { request in requests.withLock { $0.append(request) }; return searchPage() }
        await search.search(runId: "r_1", query: String(repeating: "🚀", count: 200), caseSensitive: false, fetch: fetch)
        #expect(search.error == nil && requests.current.count == 1)
        await search.search(runId: "r_1", query: String(repeating: "🚀", count: 201), caseSensitive: false, fetch: fetch)
        #expect(search.error != nil && requests.current.count == 1)
    }

    @Test func routePreservesLiteralQueryAndAllPaginationOptions() async throws {
        let transport = FakeTransport { _ in (200, try JSONEncoder().encode(searchPage())) }
        let query = "ERROR & #${token} /中文"
        _ = try await testClient(transport).searchLogs("r_1", query: query, caseSensitive: true, after: 2, through: 100, limit: 10, context: 3)
        let url = try #require(transport.requests.current.first?.url)
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(parts.path == "/api/v1/runs/r_1/logs/search")
        let items = Dictionary((parts.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        #expect(items == ["q": query, "caseSensitive": "true", "after": "2", "through": "100", "limit": "10", "context": "3"])
    }
}
