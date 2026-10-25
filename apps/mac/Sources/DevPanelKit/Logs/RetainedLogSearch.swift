import Foundation
import Observation

/// Explicit, paginated search. Keeps only one result page and never touches the live buffer.
@Observable @MainActor
public final class RetainedLogSearch {
    public struct Request: Sendable, Equatable {
        public var runId: RunID
        public var query: String
        public var caseSensitive: Bool
        public var after: Int
        public var through: Int?
    }
    public typealias Fetch = @Sendable (Request) async throws -> LogSearchPage

    public private(set) var request: Request?
    public private(set) var page: LogSearchPage?
    public private(set) var loading = false
    public private(set) var error: String?
    public private(set) var pageNumber = 1
    public private(set) var hasSearched = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var task: Task<LogSearchPage, any Error>?
    @ObservationIgnored private var cursors: [Int] = [0]
    @ObservationIgnored private var retryTarget: (after: Int, page: Int)?

    public init() {}
    public var canGoBack: Bool { pageNumber > 1 && !loading }
    public var canGoForward: Bool { page?.hasMore == true && !loading }

    public func search(runId: RunID, query: String, caseSensitive: Bool, fetch: @escaping Fetch) async {
        cancel()
        hasSearched = true
        guard !query.isEmpty, query.unicodeScalars.count <= 200 else {
            error = "请输入 1–200 个字符；按原文匹配，不使用正则表达式。"
            return
        }
        request = Request(runId: runId, query: query, caseSensitive: caseSensitive, after: 0, through: nil)
        await load(after: 0, pageNumber: 1, fetch: fetch)
    }

    public func next(fetch: @escaping Fetch) async {
        guard canGoForward, let page else { return }
        await load(after: page.scannedThroughSeq, pageNumber: pageNumber + 1, fetch: fetch)
    }

    public func previous(fetch: @escaping Fetch) async {
        guard canGoBack else { return }
        await load(after: cursors[pageNumber - 2], pageNumber: pageNumber - 1, fetch: fetch)
    }

    public func retry(fetch: @escaping Fetch) async {
        guard let retryTarget, !loading else { return }
        await load(after: retryTarget.after, pageNumber: retryTarget.page, fetch: fetch)
    }

    /// Invalidates even transports that ignore cancellation. Used on run change and dismissal.
    public func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        request = nil
        page = nil
        loading = false
        error = nil
        hasSearched = false
        pageNumber = 1
        cursors = [0]
        retryTarget = nil
    }

    private func load(after: Int, pageNumber: Int, fetch: @escaping Fetch) async {
        guard var next = request, !loading else { return }
        next.after = after
        next.through = page?.throughSeq ?? next.through
        generation += 1
        let token = generation
        loading = true
        error = nil
        retryTarget = (after, pageNumber)
        defer { if generation == token { loading = false; task = nil } }
        let pending = Task { try await fetch(next) }
        task = pending
        do {
            let result = try await pending.value
            guard generation == token, !Task.isCancelled else { return }
            guard result.runId == next.runId,
                  next.through == nil || result.throughSeq == next.through,
                  result.scannedThroughSeq >= next.after,
                  result.scannedThroughSeq <= result.throughSeq,
                  !result.hasMore || result.scannedThroughSeq > next.after else {
                throw ApiError(code: .internal, message: "搜索结果与当前运行或日志范围不一致，请重新搜索。")
            }
            request = next
            page = result
            self.pageNumber = pageNumber
            retryTarget = nil
            if cursors.count < pageNumber { cursors.append(after) }
            else { cursors[pageNumber - 1] = after }
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
    }
}
