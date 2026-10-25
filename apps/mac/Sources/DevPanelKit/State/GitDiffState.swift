import Foundation
import Observation

/// One diff window's versioned state. Superseded focus checks never replace a newer side.
@Observable @MainActor public final class GitDiffState {
    public private(set) var file: GitFileKey
    public private(set) var diff: GitDiff?
    public private(set) var pending: GitDiff?
    public private(set) var failure: String?
    public private(set) var loading = false
    public private(set) var mutating = false
    public private(set) var contentGeneration = 0
    @ObservationIgnored private var generation = 0
    public init(file: GitFileKey) { self.file = file }
    public func invalidate() { generation += 1; loading = false }
    public func select(_ file: GitFileKey) {
        invalidate(); self.file = file; diff = nil; pending = nil; failure = nil
    }
    /// Reuse a destination window after a successful write without treating that write as an external edit.
    public func adoptReplacement(from source: GitDiffState) {
        invalidate(); file = source.file; diff = source.diff; pending = nil; failure = source.failure
        contentGeneration += 1
    }
    public func load(replace: Bool, fetch: (GitFileKey) async throws -> GitDiff) async {
        guard !mutating else { return }
        await read(replace: replace, fetch: fetch)
    }
    private func read(replace: Bool, fetch: (GitFileKey) async throws -> GitDiff) async {
        generation += 1; let requestedGeneration = generation, requested = file
        loading = true
        defer { if generation == requestedGeneration { loading = false } }
        do {
            let value = try await fetch(requested)
            guard generation == requestedGeneration, requested == file else { return }
            if replace || diff == nil {
                diff = value; pending = nil; contentGeneration += 1
            } else if value.baseOid != diff?.baseOid || value.newOid != diff?.newOid {
                pending = value
            } else { pending = nil }
            failure = nil
        } catch { if generation == requestedGeneration { failure = error.localizedDescription } }
    }
    public func toggleStage(write: (GitFileKey) async -> Bool, fetch: (GitFileKey) async throws -> GitDiff) async {
        guard !mutating else { return }
        let requested = file
        mutating = true; invalidate()
        defer { mutating = false }
        guard await write(requested), requested == file else { return }
        select(GitFileKey(path: requested.path, staged: !requested.staged))
        await read(replace: true, fetch: fetch)
    }
}
