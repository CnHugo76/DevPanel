import Foundation
import Observation

public struct ProjectGroup: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
}

public struct ProjectSection: Identifiable, Sendable {
    public var id: String
    public var group: ProjectGroup? = nil
    public var projects: [FilteredProject]
    /// Includes hidden services when searching.
    public var members: [ProjectView]
    public var runningCount: Int { members.reduce(0) { $0 + $1.runningCount } }
    public var problemCount: Int {
        members.flatMap(\.services).filter {
            $0.state == .failed || $0.state == .unknown || $0.stopTimedOut
                || $0.currentRun?.ready?.state == .timedOut
        }.count
    }
}

/// Local display organization. Never changes daemon/config order or sends API writes.
@Observable @MainActor
public final class ProjectOrganization {
    private struct Saved: Codable {
        var groups: [ProjectGroup] = []
        // An empty assignment explicitly opts out of an instance's default group.
        var assignments: [ProjectID: String] = [:]
        var sections: [String] = []
        var projects: [ProjectID] = []
        var services: [ProjectID: [ServiceID]] = [:]
        var collapsed: Set<String> = []
    }
    private static let key = "overview.organization.v1"
    private var saved: Saved
    public private(set) var revealGroup: String?
    public private(set) var revealGeneration = 0
    @ObservationIgnored private let defaults: UserDefaults?

    public init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        saved = defaults?.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } ?? Saved()
    }

    public func groups(in projects: [ProjectView]) -> [ProjectGroup] {
        var groups = saved.groups
        for project in projects {
            if let name = project.instance?.group {
                let id = "instance:" + name
                if !groups.contains(where: { $0.id == id }) {
                    groups.append(ProjectGroup(id: id, name: name))
                }
            }
        }
        return ordered(groups, ids: saved.sections, id: \.id)
    }

    public func groupID(for project: ProjectView) -> String? {
        if let assignment = saved.assignments[project.id] { return assignment.isEmpty ? nil : assignment }
        return project.instance.map { "instance:" + $0.group }
    }

    public static func projectSectionID(_ id: ProjectID) -> String { "project:" + id }

    public func sections(_ projects: [ProjectView], query: String = "") -> [ProjectSection] {
        let groups = groups(in: projects)
        let names = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.name) })
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered: [FilteredProject]
        if q.lowercased().hasPrefix("group:") {
            let expected = String(q.dropFirst(6))
            filtered = projects.filter {
                guard let id = groupID(for: $0), let name = names[id] else { return false }
                return name.compare(expected, options: [.caseInsensitive, .widthInsensitive]) == .orderedSame
            }.map { FilteredProject(project: $0, services: $0.services) }
        } else {
            let groupMatches = Set(groups.filter {
                !q.isEmpty && $0.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
            }.map(\.id))
            let matches = Dictionary(uniqueKeysWithValues: OverviewFilter.apply(projects, query: q).map { ($0.id, $0) })
            filtered = projects.compactMap { p in
                if let id = groupID(for: p), groupMatches.contains(id) { return FilteredProject(project: p, services: p.services) }
                return matches[p.id]
            }
        }
        let items = ordered(filtered, ids: saved.projects, id: \.id).map { item in
            FilteredProject(project: item.project, services: services(item.services, in: item.id))
        }
        var sections: [ProjectSection] = []
        var seen: Set<String> = []
        // Preserve registration order until the user arranges things.
        for project in projects {
            if let id = groupID(for: project), let group = groups.first(where: { $0.id == id }) {
                if seen.insert(id).inserted {
                    sections.append(ProjectSection(id: id, group: group,
                        projects: items.filter { groupID(for: $0.project) == id },
                        members: projects.filter { groupID(for: $0) == id }))
                }
            } else if let item = items.first(where: { $0.id == project.id }) {
                sections.append(ProjectSection(id: Self.projectSectionID(project.id), projects: [item], members: [project]))
            }
        }
        for group in saved.groups where !seen.contains(group.id) {
            sections.append(ProjectSection(id: group.id, group: group, projects: [], members: []))
        }
        sections = sections.filter { q.isEmpty || !$0.projects.isEmpty }
        return ordered(sections, ids: saved.sections, id: \.id)
    }

    public func services(_ services: [ServiceView], in project: ProjectID) -> [ServiceView] {
        ordered(services, ids: saved.services[project] ?? [], id: \.id)
    }

    public func isCollapsed(_ group: String) -> Bool { saved.collapsed.contains(group) }
    public func reveal(_ group: String) {
        saved.collapsed.remove(group)
        revealGroup = group
        revealGeneration += 1
        persist()
    }
    public func toggleCollapsed(_ group: String) {
        if saved.collapsed.contains(group) { saved.collapsed.remove(group) } else { saved.collapsed.insert(group) }
        persist()
    }

    public func nameError(_ name: String, excluding id: String? = nil, projects: [ProjectView]) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return "请输入 1–80 字符的单行分组名称。" }
        if groups(in: projects).contains(where: { $0.id != id && $0.name.compare(name, options: [.caseInsensitive, .widthInsensitive]) == .orderedSame }) {
            return "已有同名分组。"
        }
        return nil
    }

    @discardableResult public func createGroup(_ name: String, projects: [ProjectView]) -> String? {
        guard nameError(name, projects: projects) == nil else { return nil }
        let id = "local:" + UUID().uuidString
        saved.groups.append(ProjectGroup(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines)))
        persist()
        return id
    }

    public func renameGroup(_ id: String, name: String, projects: [ProjectView]) {
        guard nameError(name, excluding: id, projects: projects) == nil else { return }
        saved.sections = sections(projects).map(\.id)
        saved.groups.removeAll { $0.id == id }
        saved.groups.append(ProjectGroup(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines)))
        persist()
    }

    public func removeGroup(_ id: String, projects: [ProjectView]) {
        let previous = sections(projects).map(\.id)
        let members = sections(projects).first { $0.id == id }?.projects.map(\.project) ?? []
        for p in members { saved.assignments[p.id] = "" }
        saved.groups.removeAll { $0.id == id }
        saved.collapsed.remove(id)
        saved.sections = previous.flatMap { $0 == id ? members.map { Self.projectSectionID($0.id) } : [$0] }
        persist()
    }

    public func moveProject(_ id: ProjectID, to group: String?, before target: ProjectID? = nil, projects: [ProjectView]) {
        guard projects.contains(where: { $0.id == id }),
              group == nil || groups(in: projects).contains(where: { $0.id == group }),
              target != id else { return }
        if let target, !projects.contains(where: { $0.id == target && groupID(for: $0) == group }) { return }
        let previous = sections(projects).map(\.id)
        // Take the complete order, even when a search hides other projects.
        var order = ordered(projects, ids: saved.projects, id: \.id).map(\.id)
        order.removeAll { $0 == id }
        order.insert(id, at: target.flatMap { order.firstIndex(of: $0) } ?? order.endIndex)
        saved.assignments[id] = group ?? ""
        saved.projects = order
        let sectionID = group ?? Self.projectSectionID(id)
        saved.sections = previous + (previous.contains(sectionID) ? [] : [sectionID])
        persist()
    }

    public func moveSection(_ id: String, before target: String?, projects: [ProjectView]) {
        var order = sections(projects).map(\.id)
        guard order.contains(id), target != id, target == nil || order.contains(target!) else { return }
        order.removeAll { $0 == id }
        order.insert(id, at: target.flatMap { order.firstIndex(of: $0) } ?? order.endIndex)
        saved.sections = order
        persist()
    }

    public func moveService(_ id: ServiceID, in project: ProjectView, before target: ServiceID?) {
        var order = services(project.services, in: project.id).map(\.id)
        guard order.contains(id), target != id, target == nil || order.contains(target!) else { return }
        order.removeAll { $0 == id }
        order.insert(id, at: target.flatMap { order.firstIndex(of: $0) } ?? order.endIndex)
        saved.services[project.id] = order
        persist()
    }

    public func placeProject(_ id: ProjectID, beside target: ProjectID, after: Bool, projects: [ProjectView]) {
        guard id != target, let p = projects.first(where: { $0.id == target }) else { return }
        let group = groupID(for: p)
        let siblings = ordered(projects.filter { groupID(for: $0) == group && $0.id != id }, ids: saved.projects, id: \.id).map(\.id)
        let next = siblings.firstIndex(of: target).flatMap { siblings.indices.contains($0 + 1) ? siblings[$0 + 1] : nil }
        moveProject(id, to: group, before: after ? next : target, projects: projects)
        if group == nil {
            placeSection(Self.projectSectionID(id), beside: Self.projectSectionID(target), after: after, projects: projects)
        }
    }

    public func placeSection(_ id: String, beside target: String, after: Bool, projects: [ProjectView]) {
        let order = sections(projects).map(\.id).filter { $0 != id }
        guard let index = order.firstIndex(of: target) else { return }
        moveSection(id, before: after ? (order.indices.contains(index + 1) ? order[index + 1] : nil) : target, projects: projects)
    }

    public func shiftProject(_ id: ProjectID, down: Bool, projects: [ProjectView]) {
        guard let p = projects.first(where: { $0.id == id }) else { return }
        if let group = groupID(for: p) {
            let siblings = sections(projects).first { $0.id == group }?.projects.map(\.id) ?? []
            guard let index = siblings.firstIndex(of: id), siblings.indices.contains(index + (down ? 1 : -1)) else { return }
            placeProject(id, beside: siblings[index + (down ? 1 : -1)], after: down, projects: projects)
        } else { shiftSection(Self.projectSectionID(id), down: down, projects: projects) }
    }

    public func shiftSection(_ id: String, down: Bool, projects: [ProjectView]) {
        let order = sections(projects).map(\.id)
        guard let index = order.firstIndex(of: id), order.indices.contains(index + (down ? 1 : -1)) else { return }
        placeSection(id, beside: order[index + (down ? 1 : -1)], after: down, projects: projects)
    }

    public func placeService(_ id: ServiceID, in project: ProjectView, beside target: ServiceID, after: Bool) {
        let order = services(project.services, in: project.id).map(\.id).filter { $0 != id }
        guard let index = order.firstIndex(of: target) else { return }
        moveService(id, in: project, before: after ? (order.indices.contains(index + 1) ? order[index + 1] : nil) : target)
    }

    public func shiftService(_ id: ServiceID, in project: ProjectView, down: Bool) {
        let order = services(project.services, in: project.id).map(\.id)
        guard let index = order.firstIndex(of: id), order.indices.contains(index + (down ? 1 : -1)) else { return }
        placeService(id, in: project, beside: order[index + (down ? 1 : -1)], after: down)
    }

    private func ordered<T>(_ values: [T], ids: [String], id: KeyPath<T, String>) -> [T] {
        let ranks = Dictionary(ids.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        return values.enumerated().sorted {
            let a = ranks[$0.element[keyPath: id]] ?? Int.max
            let b = ranks[$1.element[keyPath: id]] ?? Int.max
            return a == b ? $0.offset < $1.offset : a < b
        }.map(\.element)
    }

    private func persist() { if let data = try? JSONEncoder().encode(saved) { defaults?.set(data, forKey: Self.key) } }
}
