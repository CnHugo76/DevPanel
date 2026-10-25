import Foundation

public struct GitSurfaceVisibility: Sendable {
    public var viewportVisible: Bool
    public var windowForeground: Bool
    public var applicationActive: Bool
    public var eligible: Bool { viewportVisible && windowForeground && applicationActive }
    public init(viewportVisible: Bool, windowForeground: Bool, applicationActive: Bool) {
        self.viewportVisible = viewportVisible; self.windowForeground = windowForeground; self.applicationActive = applicationActive
    }
    public static let hidden = GitSurfaceVisibility(viewportVisible: false, windowForeground: false, applicationActive: false)
}

/// One request loop per project, shared by visible summaries and the inspector.
@MainActor public final class GitRefreshCoordinator {
    struct Lease { var project: ProjectID; var page: Bool; var file: GitFileKey? }
    private let model: AppModel
    private let sleep: @Sendable () async throws -> Void
    public private(set) var refreshCount = 0
    private var leases: [UUID: Lease] = [:]
    private var tasks: [ProjectID: Task<Void, Never>] = [:]
    public init(model: AppModel, sleep: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(5)) }) { self.model = model; self.sleep = sleep }
    public func set(_ token: UUID, project: ProjectID, page: Bool, file: GitFileKey?, visibility: GitSurfaceVisibility) {
        leases[token] = visibility.eligible ? Lease(project: project, page: page, file: file) : nil
        reconcile()
    }
    public func reconcile() {
        let desired = model.isConnected && model.client != nil ? Set(leases.values.map(\.project)) : []
        for id in Array(tasks.keys) where !desired.contains(id) { tasks.removeValue(forKey: id)?.cancel() }
        for id in desired where tasks[id] == nil {
            tasks[id] = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    let active = self.leases.values.filter { $0.project == id }
                    self.refreshCount += 1
                    await self.model.refreshGit(id, includeStashes: active.contains { $0.page })
                    guard !Task.isCancelled else { return }
                    let visible = Set(self.leases.values.filter { $0.project == id }.compactMap(\.file))
                    await self.model.refreshGitCounts(id, files: visible)
                    do { try await self.sleep() } catch { return }
                }
            }
        }
    }
}

