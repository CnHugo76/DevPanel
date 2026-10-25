import Foundation
import Testing
@testable import DevPanelKit

@Suite("Explicit project targets") struct ProjectTargetsTests {
    @Test @MainActor func draftRoundtripPreservesExplicitAndEmptyLists() throws {
        var config = ProjectConfig(name: "Workspace", root: "/tmp/workspace", services: [])
        config.repositories = [RepositoryConfig(id: "front", name: "前端", path: "front"), RepositoryConfig(id: "back", name: "后端", path: "back")]
        config.mavenProjects = [MavenProjectConfig(id: "build", name: "后端构建", path: "back/server", executable: "wrapper")]
        let encoded = try ContractCoding.encoder().encode(config)
        let decoded = try ContractCoding.decoder().decode(ProjectConfig.self, from: encoded)
        #expect(decoded == config)
        let draft = ProjectDraft(config: config)
        #expect(draft.build().config.repositories == config.repositories)
        #expect(draft.build().config.mavenProjects == config.mavenProjects)
        config.repositories = []; config.mavenProjects = []
        let empty = try ContractCoding.decoder().decode(ProjectConfig.self, from: ContractCoding.encoder().encode(config))
        #expect(empty.repositories == [])
        #expect(empty.mavenProjects == [])
    }
    @Test @MainActor func repositoryAndBuildPreferencesAreIsolatedWithinOneProject() {
        let git = GitState(), a = GitScope(projectId: "p", repositoryId: "front"), b = GitScope(projectId: "p", repositoryId: "back")
        let file = GitFileKey(path: "same.txt", staged: false)
        git.select(file, projectId: a.key, additive: false)
        git.messages[a.key] = "front commit"
        #expect(git.selections[b.key] == nil)
        #expect(git.messages[b.key] == nil)
        #expect(a.key != b.key && a.key != GitScope(projectId: "p").key)
        let maven = MavenState()
        maven.targetSelections["p"] = "alpha"
        var selection = MavenSelection(); selection.select(module: ".", phase: "verify", additive: false)
        maven.selections[maven.key("p")] = selection
        #expect(maven.request("p").mavenProjectId == "alpha")
        #expect(maven.request("p").goals == ["verify"])
        maven.targetSelections["p"] = "beta"
        #expect(maven.request("p").goals.isEmpty)
        #expect(maven.request("p").mavenProjectId == "beta")
    }
    @Test func clientCapturesTargetOnReadsAndWrites() async throws {
        let transport = FakeTransport { request in
            if request.url?.path.hasSuffix("/maven") == true { return (200, try ContractCoding.encoder().encode(MavenTests().model())) }
            return (200, try ContractCoding.encoder().encode(GitTests().status()))
        }
        let client = testClient(transport)
        _ = try await client.gitStatus("p", repositoryId: "front")
        _ = try await client.gitStage("p", paths: ["same.txt"], staged: true, repositoryId: "back")
        _ = try await client.maven("p", mavenProjectId: "build")
        let requests = transport.requests.current
        #expect(requests[0].url?.query == "repositoryId=front")
        #expect(requests[1].url?.query == "repositoryId=back")
        #expect(requests[1].httpMethod == "POST")
        #expect(requests[2].url?.query == "mavenProjectId=build")
        let request = MavenRunRequest(goals: ["verify"], mavenProjectId: "build")
        #expect(try ContractCoding.decoder().decode(MavenRunRequest.self, from: ContractCoding.encoder().encode(request)).mavenProjectId == "build")
    }
}
