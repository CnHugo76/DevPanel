import Foundation

/// Expansion follows user choices; changing the selected module never closes another branch.
public struct MavenTreeExpansion: Equatable, Sendable {
    public var collapsed: Set<String> = []
    public var closedLifecycle: Set<String> = []
    private var seen: Set<String> = []
    public init() {}
    public mutating func synchronize(_ modules: [MavenModule]) {
        for module in modules where !seen.contains(module.id) {
            if module.parentId != nil { collapsed.insert(module.id); closedLifecycle.insert(module.id) }
        }
        seen = Set(modules.map(\.id))
        collapsed.formIntersection(seen); closedLifecycle.formIntersection(seen)
    }
    public mutating func reveal(_ id: String, modules: [MavenModule]) {
        closedLifecycle.remove(id); collapsed.remove(id)
        var current = modules.first { $0.id == id }?.parentId
        var visited: Set<String> = []
        while let parent = current, visited.insert(parent).inserted {
            collapsed.remove(parent); current = modules.first { $0.id == parent }?.parentId
        }
    }
}
