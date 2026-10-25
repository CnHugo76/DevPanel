import Foundation
import Testing
@testable import DevPanelKit

@Suite("Maven view and requests") struct MavenTests {
    func model() -> MavenModel {
        MavenModel(executable: .wrapper, modules: [MavenModule(id: ".", pomPath: "/tmp/project/pom.xml", parentId: nil, groupId: "org.example", artifactId: "root", name: "Root", packaging: "pom", profiles: ["dev"], parentOutside: false, error: nil), MavenModule(id: "backend", pomPath: "/tmp/project/backend/pom.xml", parentId: ".", groupId: "org.example", artifactId: "backend", name: nil, packaging: "jar", profiles: ["integration"], parentOutside: true, error: nil)], profiles: ["dev", "integration"], scannedAt: "2026-10-21T00:00:00Z")
    }
    @Test func lifecycleMultiselectionRespectsModuleAndCanonicalOrder() {
        var selection = MavenSelection()
        selection.select(module: "backend", phase: "install", additive: false)
        selection.select(module: "backend", phase: "clean", additive: true)
        #expect(selection.goals == ["clean", "install"])
        selection.select(module: "backend", phase: "clean", additive: true)
        #expect(selection.goals == ["install"])
        selection.select(module: ".", phase: "test", additive: true)
        #expect(selection.goals == ["test"])
        #expect(selection.moduleId == ".")
    }
    @Test @MainActor func profilesAreTristateAndRequestIsStructured() {
        let state = MavenState(); state.models["p"] = model()
        state.cycleProfile("dev", projectId: "p")
        state.cycleProfile("integration", projectId: "p"); state.cycleProfile("integration", projectId: "p")
        var selection = MavenSelection(); selection.select(module: "backend", phase: "install", additive: false)
        state.selections["p"] = selection
        var options = MavenOptions(); options.skipTests = true; options.alsoMake = true; options.offline = true
        state.setOptions(options, for: "p")
        let request = state.request("p")
        #expect(request.profiles == ["dev", "!integration"])
        #expect(request.previewCommand(executable: .wrapper) == ["./mvnw", "-pl", "backend", "-am", "-DskipTests", "-o", "-Pdev,!integration", "install"])
        state.cycleProfile("integration", projectId: "p")
        #expect(state.request("p").profiles == ["dev"])
    }
    @Test func rootCommandIgnoresAlsoMakeAndGoalValidationRejectsFlags() {
        let request = MavenRunRequest(goals: ["dependency:tree", "org.apache.maven.plugins:maven-help-plugin:3.4.0:effective-pom@inspect"], alsoMake: true)
        #expect(request.localError == nil)
        #expect(request.previewCommand(executable: .mvn) == ["mvn"] + request.goals)
        for goals in [[], ["--version"], ["-Dexec.args=bad"], ["clean;rm"], ["test", "&&"], ["a:b:c:d:e"]] {
            #expect(MavenRunRequest(goals: goals).localError != nil)
        }
    }
    @Test @MainActor func preferencesArePerProjectAndTabsPersist() throws {
        let suite = "devpanel.maven.test.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let state = MavenState(defaults: defaults)
        var options = MavenOptions(); options.skipTests = true; options.offline = true
        state.setOptions(options, for: "p_one")
        let reopened = MavenState(defaults: defaults); reopened.loadOptions("p_one"); reopened.loadOptions("p_two")
        #expect(reopened.options["p_one"]?.skipTests == true)
        #expect(reopened.options["p_one"]?.offline == true)
        #expect(reopened.options["p_two"]?.skipTests == false)
        let inspector = ProjectInspectorState(defaults: defaults); inspector.tabs["p_one"] = .maven
        #expect(ProjectInspectorState(defaults: defaults).tabs["p_one"] == .maven)
    }
    @Test func endpointsUseStructuredBodyAndUIHeader() async throws {
        let maven = model()
        let run = TaskTests().task(.running)
        let transport = FakeTransport { request in
            if request.url?.path.hasSuffix("/maven") == true { return (200, try ContractCoding.encoder().encode(maven)) }
            if request.httpMethod == "GET" { return (200, try ContractCoding.encoder().encode([run])) }
            return (202, try ContractCoding.encoder().encode(StartTaskRunResponse(created: true, run: run)))
        }
        let client = testClient(transport)
        #expect(try await client.maven("p", reload: true).modules.count == 2)
        _ = try await client.mavenRuns("p")
        let input = MavenRunRequest(moduleId: "backend", goals: ["clean", "install"], profiles: ["!integration"], skipTests: true)
        _ = try await client.startMaven("p", request: input)
        let requests = transport.requests.current
        #expect(requests[0].url?.query == "reload=1")
        #expect(requests[1].url?.path == "/api/v1/projects/p/maven/runs")
        #expect(requests[2].value(forHTTPHeaderField: "X-DevPanel-Client") == "ui")
        #expect(try ContractCoding.decoder().decode(MavenRunRequest.self, from: requests[2].httpBody!) == input)
    }
    @Test @MainActor func cleanConfirmationAndBusyProjectDoNotPostCommands() async throws {
        let fixture = AppModelTests()
        fixture.daemon.enqueue(.stream(try fixture.daemon.connectedStream()))
        let app = fixture.makeModel(); app.start(); defer { app.stop() }
        await eventually { app.isConnected }
        var p = TaskTests().project(TaskTests().task(.running)); p.runningCount = 1
        p.maven = MavenView(currentRun: nil, lastRun: nil)
        app.apply(.projectUpsert(p)); app.maven.models[p.id] = model()
        let before = fixture.daemon.transport.requests.current.filter { $0.httpMethod == "POST" }.count
        app.requestMaven(p.id, request: MavenRunRequest(goals: ["clean", "install"]))
        #expect(app.maven.confirmation?.request.goals == ["clean", "install"])
        #expect(app.maven.confirmation?.message.contains("target/") == true)
        #expect(fixture.daemon.transport.requests.current.filter { $0.httpMethod == "POST" }.count == before)
        app.maven.confirmation = nil
        p.maven?.currentRun = TaskTests().task(.running); app.apply(.projectUpsert(p))
        app.requestMaven(p.id, request: MavenRunRequest(goals: ["install"]))
        #expect(app.maven.errors[p.id]?.contains("已有 Maven 运行") == true)
        #expect(app.maven.confirmation == nil)
        #expect(fixture.daemon.transport.requests.current.filter { $0.httpMethod == "POST" }.count == before)
    }
    @Test @MainActor func mavenTaskDoesNotCollideWithServiceNamedMaven() {
        let app = AppModel(environment: .init(discover: { nil }, makeClient: { DaemonClient(discovery: $0) }))
        var run = TaskTests().task(.running); run.kind = .maven; run.actionId = nil; run.maven = MavenRunRequest(goals: ["install"])
        var project = TaskTests().project(run)
        project.maven = MavenView(currentRun: run, lastRun: run)
        project.services = [ServiceView(id: "maven", name: "Normal service", state: .idle)]
        app.apply(.projectUpsert(project)); app.selectProject(project.id, tab: .maven)
        #expect(app.selectedTaskRef == TaskRef(project.id, .maven))
        #expect(app.latestRunId(for: TaskRef(project.id, .maven)) == run.id)
        #expect(app.latestRunId(for: ServiceRef(project.id, "maven")) == nil)
        #expect(app.selectedTaskRef?.target == .maven)
        app.selectProject(project.id, tab: .options)
        #expect(app.selectedTaskRef == nil)
        #expect(app.inspector.logs.target == nil)
    }
    @Test func rootExpansionAndIndependentLifecycleChoicesSurviveSelectionAndReload() {
        let modules = model().modules
        var expansion = MavenTreeExpansion(); expansion.synchronize(modules)
        #expect(!expansion.collapsed.contains(".") && !expansion.closedLifecycle.contains("."))
        #expect(expansion.collapsed.contains("backend"))
        expansion.reveal("backend", modules: modules)
        #expect(!expansion.closedLifecycle.contains(".") && !expansion.closedLifecycle.contains("backend"))
        expansion.closedLifecycle.insert("backend")
        expansion.reveal(".", modules: modules)
        expansion.synchronize(modules)
        #expect(expansion.closedLifecycle.contains("backend"))
        #expect(!expansion.collapsed.contains("backend"))
    }
    @Test func unresolvedModuleNamesFallBackToArtifactId() {
        var module = model().modules[0]
        module.name = "${project.parent.artifactId} :: API"
        #expect(module.displayTitle == "root" && module.displayName == "root")
        module.name = "Root API"
        #expect(module.displayTitle == "root · Root API")
    }

}
