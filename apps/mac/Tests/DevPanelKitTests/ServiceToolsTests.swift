import Foundation
import Testing
@testable import DevPanelKit

@Suite("Engineering tool ownership") struct ServiceToolsTests {
    @Test func matchesClosestAncestorWithPathBoundaries() {
        let paths = [".", "back", "back/server", "front"]
        #expect(ServiceTools.closest(cwd: "back/server/module", paths: paths, root: "/tmp/work") == 2)
        #expect(ServiceTools.closest(cwd: "back-old", paths: ["back"], root: "/tmp/work") == nil)
        #expect(ServiceTools.closest(cwd: "front/../back", paths: paths, root: "/tmp/work") == 1)
        #expect(ServiceTools.closest(cwd: "/tmp/work/front", paths: paths, root: "/tmp/work") == 3)
    }
    @Test @MainActor func switchingServicesSwitchesRepositoryAndMavenLogOwner() throws {
        let model = AppModel(environment: .init(discover: { nil }, makeClient: { DaemonClient(discovery: $0) }))
        var project = TaskTests().project(TaskTests().task())
        project.services = [.init(id: "front", name: "Frontend", state: .idle), .init(id: "back", name: "Java", state: .idle)]
        project.repositories = [.init(id: "frontend", name: "UI repo", path: "front"), .init(id: "backend", name: "API repo", path: "back")]
        project.mavenProjects = [try ContractCoding.decoder().decode(MavenProjectView.self, from: Data(#"{"id":"java","name":"Java build","path":"back","currentRun":null,"lastRun":null}"#.utf8))]
        var build = TaskTests().task(.running)
        build.kind = .maven; build.actionId = nil
        build.maven = MavenRunRequest(goals: ["verify"], mavenProjectId: "java")
        project.mavenProjects?[0].currentRun = build
        project.maven = MavenView(currentRun: build, lastRun: nil)
        defer { model.stop() }
        model.apply(.projectUpsert(project))
        let config = ProjectConfig(name: project.name, root: project.root, services: [
            .init(id: "front", name: "Frontend", cwd: "front", command: ["pnpm", "dev"]),
            .init(id: "back", name: "Java", cwd: "back", command: ["./mvnw", "spring-boot:run"])
        ])
        model.storeConfig(Project(id: project.id, revision: project.revision, createdAt: "now", updatedAt: "now", config: config))
        let front = ServiceRef(project.id, "front"), back = ServiceRef(project.id, "back")
        model.selectServiceTab(.maven, for: back)
        #expect(model.selection == back)
        #expect(model.maven.request(project.id).mavenProjectId == "java")
        #expect(model.selectedTaskRef == TaskRef(project.id, .maven))
        #expect(model.inspector.logs.target?.owner == .task(TaskRef(project.id, .maven)))
        #expect(model.inspector.logs.target?.runId == build.id)
        #expect(model.gitScope(project.id).repositoryId == "backend")
        model.select(front)
        #expect(model.inspector.tab == .logs)
        #expect(model.selectedTaskRef == nil)
        #expect(model.inspector.logs.target == nil)
        #expect(model.gitScope(project.id).repositoryId == "frontend")
        #expect(!model.serviceTabs(front).contains(.maven))
        #expect(!model.projectTabs(project.id).contains(.git))
        #expect(!model.projectTabs(project.id).contains(.maven))
        model.selectProject(project.id, tab: .git)
        #expect(model.selection == front)
        #expect(model.inspector.tab == .git)
        model.selectProject(project.id)
        #expect(model.selection == nil)
        #expect(model.projectInspector.tabs[project.id] == .actions)
    }
}
