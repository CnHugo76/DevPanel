import Foundation
import Observation

public struct GitScope: Hashable, Sendable, Identifiable {
    public var id: String { key }
    public let projectId: ProjectID
    public let repositoryId: String?
    public var key: String { repositoryId.map { projectId + "#" + $0 } ?? projectId }
    public init(projectId: ProjectID, repositoryId: String? = nil) { self.projectId = projectId; self.repositoryId = repositoryId }
}

public struct GitFailure: Equatable, Sendable {
    public var title: String
    public var output: String?
    public var code: String
    public init(_ error: any Error) {
        let api = error as? ApiError
        code = api?.code.rawValue ?? "GIT_FAILED"
        let explanation: String = switch code {
        case "GIT_HEAD_MOVED": "HEAD 已变化。已刷新仓库状态，请检查后重新提交。"
        case "GIT_LOCKED": "Git 索引正被锁定。请等待其他 Git 操作结束；DevPanel 不会删除锁文件。"
        case "GIT_HOOK_FAILED": "提交钩子失败，提交未完成。"
        case "GIT_CONFLICT": "恢复储藏产生冲突，储藏仍然保留。请先处理冲突。"
        case "GIT_UNAVAILABLE": "找不到 Git，请安装 Git 并检查管理服务的 PATH。"
        default: "Git 操作失败。"
        }
        title = explanation + "\n" + error.localizedDescription
        output = api?.details?["output"]?.stringValue ?? api?.details?["stderr"]?.stringValue
    }
}
public struct GitCommitConfirmation: Identifiable, Sendable {
    public var projectId: ProjectID
    public var request: GitCommitRequest
    public var scope: GitScope? = nil
    public var sensitivePaths: [String]
    public var id: String { projectId }
}
@Observable @MainActor public final class GitState {
    public var statuses: [ProjectID: GitStatus] = [:]
    public var stashes: [ProjectID: [GitStash]] = [:]
    public var counts: [ProjectID: [GitFileKey: GitDiff]] = [:]
    public var selections: [ProjectID: Set<GitFileKey>] = [:]
    public var messages: [ProjectID: String] = [:]
    public var amend: [ProjectID: Bool] = [:]
    public var failures: [ProjectID: GitFailure] = [:]
    public var output: [ProjectID: String] = [:]
    public var busy: Set<ProjectID> = []
    public var loading: Set<ProjectID> = []
    public var changeGeneration: [ProjectID: Int] = [:]
    public var confirmation: GitCommitConfirmation?
    public var repositorySelections: [ProjectID: String] = [:]
    public var fileLayout: GitFileListLayout = .tree
    public var changeFilter: GitChangeKind?
    public init() {}
    public func orderedFiles(_ id: ProjectID) -> [GitFileKey] {
        let entries = statuses[id]?.entries ?? []
        return GitGroup.allCases.flatMap { group in entries.filter(group.contains).map { GitFileKey(path: $0.path, staged: group == .staged) } }
    }
    public func select(_ file: GitFileKey, projectId: ProjectID, additive: Bool, rangeFrom anchor: GitFileKey? = nil, order displayedOrder: [GitFileKey]? = nil) {
        let order = displayedOrder ?? orderedFiles(projectId)
        if let anchor, let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: file) {
            selections[projectId] = Set(order[min(from, to)...max(from, to)])
        } else if additive {
            var chosen = selections[projectId, default: []]
            if chosen.contains(file) { chosen.remove(file) } else { chosen.insert(file) }
            selections[projectId] = chosen
        } else { selections[projectId] = [file] }
    }
}
extension AppModel {
    public func gitScope(_ id: ProjectID) -> GitScope {
        let targets = project(id)?.repositories
        let chosen = git.repositorySelections[id]
        // A removed target must never silently select a different repository.
        return GitScope(projectId: id, repositoryId: chosen ?? targets?.first?.id)
    }

    private func targetKey(_ scope: GitScope) -> String { scope.key }

    /// Shared entry for independent diff windows; connection ownership stays in AppModel.
    public func loadGitDiff(_ id: ProjectID, file: GitFileKey, scope: GitScope? = nil) async throws -> GitDiff {
        let target = scope ?? gitScope(id)
        guard isConnected, let client else { throw URLError(.notConnectedToInternet) }
        return try await client.gitDiff(id, file: file, context: "all", repositoryId: target.repositoryId)
    }

    public func refreshGit(_ id: ProjectID, includeStashes: Bool = true, force: Bool = false, scope: GitScope? = nil) async {
        let target = scope ?? gitScope(id), key = targetKey(scope ?? gitScope(id))
        guard project(id)?.repositories?.isEmpty != true else { return }
        guard isConnected, let client, force || !git.loading.contains(key) else { return }
        let generation = git.changeGeneration[key, default: 0]
        git.loading.insert(key)
        defer { git.loading.remove(key) }
        do {
            let status = try await client.gitStatus(id, repositoryId: target.repositoryId)
            guard !Task.isCancelled, generation == git.changeGeneration[key, default: 0] else { return }
            git.statuses[key] = status
            git.selections[key]?.formIntersection(Set(git.orderedFiles(key)))
            if includeStashes, status.repo != nil {
                let stashes = try await client.gitStashes(id, repositoryId: target.repositoryId)
                guard !Task.isCancelled, generation == git.changeGeneration[key, default: 0] else { return }
                git.stashes[key] = stashes
            }
            // Mutation failures stay visible until explicitly dismissed.
            if git.failures[key]?.code == "GIT_UNAVAILABLE" { git.failures[key] = nil }
        } catch is CancellationError {} catch { git.failures[key] = GitFailure(error) }
    }
    public func refreshGitCounts(_ id: ProjectID, files: Set<GitFileKey>, scope: GitScope? = nil) async {
        let target = scope ?? gitScope(id), key = targetKey(scope ?? gitScope(id))
        guard isConnected, let client, git.statuses[key]?.repo != nil else { return }
        let generation = git.changeGeneration[key, default: 0]
        let ordered = git.orderedFiles(key).filter { files.contains($0) }
        // Only visible rows are requested. Batch four to keep large worktrees inexpensive.
        for start in stride(from: 0, to: ordered.count, by: 4) {
            guard !Task.isCancelled, isConnected else { return }
            let batch = Array(ordered[start..<min(start + 4, ordered.count)])
            let results = await withTaskGroup(of: (GitFileKey, GitDiff?).self) { group in
                for file in batch { group.addTask { (file, try? await client.gitDiff(id, file: file, context: "0", repositoryId: target.repositoryId)) } }
                var results: [(GitFileKey, GitDiff?)] = []
                for await result in group { results.append(result) }
                return results
            }
            guard !Task.isCancelled, generation == git.changeGeneration[key, default: 0] else { return }
            for (file, diff) in results { if let diff { git.counts[key, default: [:]][file] = diff } }
        }
    }
    @discardableResult public func stageGit(_ id: ProjectID, files: [GitFileKey], staged: Bool, scope: GitScope? = nil) async -> Bool {
        let target = scope ?? gitScope(id), key = targetKey(scope ?? gitScope(id))
        guard isConnected, let client, !git.busy.contains(key), !files.isEmpty else { return false }
        git.busy.insert(key); defer { git.busy.remove(key) }
        var succeeded = false
        do { git.statuses[key] = try await client.gitStage(id, paths: Array(Set(files.map(\.path))).sorted(), staged: staged, repositoryId: target.repositoryId); git.failures[key] = nil; succeeded = true }
        catch { git.failures[key] = GitFailure(error) }
        await afterGitWrite(id, scope: target)
        return succeeded
    }
    public func requestGitCommit(_ id: ProjectID) {
        let target = gitScope(id), key = targetKey(gitScope(id))
        guard isConnected, !git.busy.contains(key), let status = git.statuses[key], let repo = status.repo else { return }
        guard !status.entries.contains(where: \.conflicted), status.entries.contains(where: { $0.index != nil }) || (git.amend[key] == true && repo.headSha != nil) else { return }
        let message = git.messages[key, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        let request = GitCommitRequest(message: message, amend: git.amend[key, default: false], expectedHead: repo.headSha)
        let sensitive = status.entries.filter { $0.index != nil && $0.sensitiveName }.map(\.path)
        if !sensitive.isEmpty { git.confirmation = GitCommitConfirmation(projectId: id, request: request, scope: target, sensitivePaths: sensitive) }
        else { Task { await commitGit(id, request: request, scope: target) } }
    }
    public func commitGit(_ id: ProjectID, request: GitCommitRequest, scope: GitScope? = nil) async {
        let target = scope ?? gitScope(id), key = targetKey(scope ?? gitScope(id))
        guard isConnected, let client, !git.busy.contains(key) else { return }
        git.busy.insert(key); git.output[key] = nil; defer { git.busy.remove(key) }
        do {
            let result = try await client.gitCommit(id, request: request, repositoryId: target.repositoryId)
            git.output[key] = result.output; git.messages[key] = ""; git.amend[key] = false; git.failures[key] = nil
        } catch { let failure = GitFailure(error); git.failures[key] = failure; git.output[key] = failure.output }
        await afterGitWrite(id, scope: target)
    }
    public func stashGit(_ id: ProjectID, message: String, includeUntracked: Bool, scope: GitScope? = nil) async {
        let target = scope ?? gitScope(id), key = targetKey(scope ?? gitScope(id))
        guard isConnected, let client, !git.busy.contains(key) else { return }
        git.busy.insert(key); defer { git.busy.remove(key) }
        do { git.statuses[key] = try await client.gitStash(id, message: message, includeUntracked: includeUntracked, repositoryId: target.repositoryId); git.failures[key] = nil }
        catch { git.failures[key] = GitFailure(error) }
        await afterGitWrite(id, scope: target)
    }
    public func applyGitStash(_ id: ProjectID, ref: String, drop: Bool, scope: GitScope? = nil) async {
        let target = scope ?? gitScope(id), key = targetKey(scope ?? gitScope(id))
        guard isConnected, let client, !git.busy.contains(key) else { return }
        git.busy.insert(key); defer { git.busy.remove(key) }
        do { git.statuses[key] = try await client.gitApplyStash(id, ref: ref, drop: drop, repositoryId: target.repositoryId); git.failures[key] = nil }
        catch { let failure = GitFailure(error); git.failures[key] = failure; git.output[key] = failure.output }
        await afterGitWrite(id, scope: target)
    }
    private func afterGitWrite(_ id: ProjectID, scope target: GitScope) async {
        let key = target.key
        git.counts[key] = [:]
        git.changeGeneration[key, default: 0] += 1
        await refreshGit(id, force: true, scope: target)
    }
}
