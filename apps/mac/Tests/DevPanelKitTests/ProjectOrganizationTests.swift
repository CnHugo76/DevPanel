import Foundation
import Testing
@testable import DevPanelKit

@Suite("Project groups and display order") @MainActor
struct ProjectOrganizationTests {
    private func project(_ id: String, _ name: String = "Project") -> ProjectView {
        ProjectView(id: id, name: name, root: "/tmp/\(id)", revision: 3, aggregate: .stopped,
                    runningCount: 0, serviceCount: 3,
                    services: ["backend", "frontend", "tunnel"].map { ServiceView(id: $0, name: $0, state: .stopped) })
    }

    @Test func changesOnlyDisplayOrderAndKeepsNewItems() throws {
        let organization = ProjectOrganization(defaults: nil)
        let a = project("a"), b = project("b"), c = project("c")
        let original = [a, b, c]
        organization.placeProject("c", beside: "a", after: false, projects: original)
        #expect(organization.sections(original).map(\.id) == ["project:c", "project:a", "project:b"])
        organization.placeService("tunnel", in: a, beside: "backend", after: false)
        #expect(organization.sections(original).flatMap(\.projects).first { $0.id == "a" }?.services.map(\.id) == ["tunnel", "backend", "frontend"])
        #expect(original == [a, b, c])
        #expect(a.services.map(\.id) == ["backend", "frontend", "tunnel"])
        #expect(a.revision == 3)
        var updated = a
        updated.services.append(ServiceView(id: "worker", name: "worker", state: .idle))
        #expect(organization.services(updated.services, in: "a").map(\.id) == ["tunnel", "backend", "frontend", "worker"])
        #expect(organization.sections(original + [project("d")]).last?.id == "project:d")
        // An SSE refresh with the original registration order cannot undo the user's arrangement.
        #expect(organization.sections(original).first?.id == "project:c")
    }

    @Test func groupsMoveAndDissolveWithoutLosingProjects() throws {
        let organization = ProjectOrganization(defaults: nil)
        let projects = [project("a"), project("b"), project("c")]
        let id = try #require(organization.createGroup("法规预警", projects: projects))
        organization.moveProject("b", to: id, projects: projects)
        organization.moveProject("c", to: id, projects: projects)
        #expect(organization.sections(projects).first?.id == "project:a")
        #expect(organization.sections(projects).first { $0.id == id }?.projects.map(\.id) == ["b", "c"])
        organization.placeProject("c", beside: "b", after: false, projects: projects)
        organization.placeSection(id, beside: "project:a", after: false, projects: projects)
        #expect(organization.sections(projects).first?.projects.map(\.id) == ["c", "b"])
        organization.toggleCollapsed(id)
        organization.renameGroup(id, name: "Demo", projects: projects)
        #expect(organization.sections(projects).first?.group?.name == "Demo")
        #expect(organization.isCollapsed(id))
        organization.removeGroup(id, projects: projects)
        #expect(organization.sections(projects).map(\.id) == ["project:c", "project:b", "project:a"])
        #expect(organization.sections(projects).flatMap(\.projects).count == 3)
        #expect(organization.groups(in: projects).isEmpty)
    }

    @Test func searchUsesLocalGroupAndPreservesHiddenOrder() throws {
        let organization = ProjectOrganization(defaults: nil)
        let projects = [project("a", "新版"), project("b", "旧版"), project("c", "无关项目")]
        let group = try #require(organization.createGroup("法规预警", projects: projects))
        organization.moveProject("a", to: group, projects: projects)
        organization.moveProject("b", to: group, projects: projects)
        organization.toggleCollapsed(group)
        #expect(organization.sections(projects, query: "group:法规预警").flatMap(\.projects).map(\.id) == ["a", "b"])
        #expect(organization.sections(projects, query: "法规").flatMap(\.projects).map(\.id) == ["a", "b"])
        #expect(organization.sections(projects, query: "不存在").isEmpty)
        organization.placeService("tunnel", in: projects[0], beside: "backend", after: false)
        let matches = organization.sections(projects, query: "front").flatMap(\.projects)
        #expect(matches.first { $0.id == "a" }?.services.map(\.id) == ["frontend"])
        #expect(organization.sections(projects).flatMap(\.projects).first { $0.id == "a" }?.services.map(\.id) == ["tunnel", "backend", "frontend"])
        #expect(organization.isCollapsed(group))
    }

    @Test func inheritsInstanceGroupAndAllowsLocalOptOut() throws {
        let organization = ProjectOrganization(defaults: nil)
        var a = project("a"), b = project("b")
        a.instance = ProjectInstance(group: "Demo", name: "main")
        b.instance = ProjectInstance(group: "Demo", name: "next")
        let projects = [a, b]
        #expect(organization.sections(projects).count == 1)
        #expect(organization.sections(projects).first?.projects.count == 2)
        organization.moveProject("b", to: nil, projects: projects)
        #expect(organization.groupID(for: b) == nil)
        #expect(organization.sections(projects).flatMap(\.projects).count == 2)
        #expect(b.instance?.group == "Demo")
    }

    @Test func groupNamesAndInvalidMoves() throws {
        let organization = ProjectOrganization(defaults: nil)
        let projects = [project("a"), project("b")]
        let group = try #require(organization.createGroup("  Demo  ", projects: projects))
        #expect(organization.createGroup("regtrack", projects: projects) == nil)
        #expect(organization.createGroup(" \n ", projects: projects) == nil)
        #expect(organization.createGroup("bad\nname", projects: projects) == nil)
        organization.moveProject("a", to: "missing-group", projects: projects)
        organization.placeProject("a", beside: "missing-project", after: false, projects: projects)
        organization.moveService("missing-service", in: projects[0], before: "backend")
        #expect(organization.groupID(for: projects[0]) == nil)
        #expect(organization.services(projects[0].services, in: "a") == projects[0].services)
        #expect(organization.groups(in: projects).first?.name == "Demo")
        organization.moveProject("a", to: group, projects: projects)
        organization.moveProject("b", to: group, projects: projects)
        organization.shiftProject("a", down: true, projects: projects)
        #expect(organization.sections(projects).first?.projects.map(\.id) == ["b", "a"])
    }

    @Test func persistsOrganizationAndCollapseAcrossReopen() throws {
        let suite = "devpanel-tests-organization-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let projects = [project("a"), project("b"), project("c")]
        let first = ViewPreferences(defaults: defaults).organization
        let group = try #require(first.createGroup("法规预警", projects: projects))
        first.moveProject("a", to: group, projects: projects)
        first.moveProject("b", to: group, projects: projects)
        first.placeProject("b", beside: "a", after: false, projects: projects)
        first.shiftService("backend", in: projects[1], down: true)
        first.toggleCollapsed(group)
        let reopened = ViewPreferences(defaults: UserDefaults(suiteName: suite)).organization
        #expect(reopened.sections(projects).map(\.id) == first.sections(projects).map(\.id))
        #expect(reopened.sections(projects).first { $0.id == group }?.projects.map(\.id) == ["b", "a"])
        #expect(reopened.services(projects[1].services, in: "b").map(\.id) == ["frontend", "backend", "tunnel"])
        #expect(reopened.isCollapsed(group))
    }

    @Test func revealOpensGroupWithoutChangingDisplayOrder() throws {
        let organization = ProjectOrganization(defaults: nil)
        let projects = [project("a"), project("b")]
        let group = try #require(organization.createGroup("法规预警", projects: projects))
        organization.moveProject("a", to: group, projects: projects)
        organization.toggleCollapsed(group)
        let order = organization.sections(projects).map(\.id)
        organization.reveal(group)
        #expect(!organization.isCollapsed(group))
        #expect(organization.revealGroup == group)
        #expect(organization.revealGeneration == 1)
        #expect(organization.sections(projects).map(\.id) == order)
    }
}
