import Foundation
import Testing

@testable import DevPanelKit

/// A connected `AppModel` over a fake transport that serves the recorded snapshot; HTTP routes
/// are answered by `routes` (method + path → status + body) and every request is recorded.
@MainActor
final class EditorHarness {
    let transport: FakeTransport
    let model: AppModel
    let routes: Locked<[String: (Int, Data)]>

    init() throws {
        let stream = FakeStream()
        try stream.sendEvent(fixture: "recorded/event-snapshot.json")
        let order = try Fixture.data("recorded/project-order-service.json")
        let routes = Locked<[String: (Int, Data)]>(["GET /api/v1/projects/p_ordersvc2a": (200, order)])
        let transport = FakeTransport()
        transport.setHandler { request in
            let key = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
            return routes.withLock { $0[key] } ?? (404, Data(#"{"error":{"code":"PROJECT_NOT_FOUND","message":"no"}}"#.utf8))
        }
        transport.setStream { _ in stream }
        self.routes = routes
        self.transport = transport
        model = AppModel(environment: AppModel.Environment(
            discover: { testDiscovery },
            makeClient: { DaemonClient(discovery: $0, transport: transport) },
            sleep: { _ in try await Task.sleep(for: .milliseconds(2)) }))
    }

    func connect() async {
        model.start()
        await eventually { self.model.isConnected && self.model.configs["p_ordersvc2a"] != nil }
    }

    func route(_ method: String, _ path: String, _ status: Int, fixture: String) throws {
        let data = try Fixture.data(fixture)
        routes.withLock { $0["\(method) /api/v1\(path)"] = (status, data) }
    }

    func route(_ method: String, _ path: String, _ status: Int, body: String) {
        routes.withLock { $0["\(method) /api/v1\(path)"] = (status, Data(body.utf8)) }
    }

    /// JSON bodies of the requests sent to `method path`.
    func bodies(_ method: String, _ path: String) throws -> [[String: Any]] {
        try transport.requests.current
            .filter { $0.httpMethod == method && $0.url?.path == "/api/v1\(path)" }
            .map { try #require(JSONSerialization.jsonObject(with: $0.httpBody ?? Data()) as? [String: Any]) }
    }
}

@MainActor
@Suite("ProjectEditor", .serialized)
struct ProjectEditorTests {
    @Test("edit loads the cached config; running project shows the next-start note")
    func loadEdit() async throws {
        let h = try EditorHarness()
        await h.connect()
        let editor = ProjectEditor(model: h.model, mode: .edit("p_ordersvc2a"))
        #expect(editor.loadState == .loading)
        await editor.load()
        #expect(editor.loadState == .loaded)
        #expect(editor.draft.name == "order-service")
        #expect(editor.draft.services.map(\.serviceId) == ["backend", "frontend"])
        #expect(editor.isRunning)
        #expect(!editor.isDirty)
        #expect(editor.params.map(\.key) == ["profile", "apiPort", "host"])
        let backend = editor.draft.services[0]
        #expect(editor.deleteBlockedReason(backend) == "运行中的服务不能删除，请先停止")
        var renamed = backend
        renamed.setServiceId("api")
        #expect(editor.idChangeNeedsConfirm(renamed), "backend has runs")
        editor.draft.name = "order-service 2"
        #expect(editor.isDirty)
    }

    @Test("save (edit): PUT with ifRevision and params unchanged; keptUserValues returned")
    func saveEdit() async throws {
        let h = try EditorHarness()
        await h.connect()
        try h.route("PUT", "/projects/p_ordersvc2a", 200, fixture: "recorded/update-response-kept.json")
        let editor = ProjectEditor(model: h.model, mode: .edit("p_ordersvc2a"))
        await editor.load()
        editor.draft.services[1].commandText = "pnpm exec next dev -p 3001"
        let outcome = await editor.save()
        guard case .updated(let project, let kept) = outcome else {
            Issue.record("expected .updated, got \(String(describing: outcome))")
            return
        }
        #expect(kept == ["port"])
        #expect(editor.keptValuesText(kept, project: project) == "端口（port）")
        let body = try #require(try h.bodies("PUT", "/projects/p_ordersvc2a").first)
        #expect(body["ifRevision"] as? Int == 3)
        #expect(body["overrideUserValues"] == nil, "never overrides user-set option values")
        let config = try #require(body["config"] as? [String: Any])
        let params = try #require(config["params"] as? [[String: Any]])
        #expect(params.map { $0["key"] as? String } == ["profile", "apiPort", "host"])
        #expect(params.allSatisfy { $0["usedBy"] == nil && $0["setBy"] == nil })
        let services = try #require(config["services"] as? [[String: Any]])
        #expect(services[1]["command"] as? [String] == ["pnpm", "exec", "next", "dev", "-p", "3001"])
        let env = try #require(services[0]["env"] as? [String: Any])
        #expect(env["DB_PASSWORD"] as? [String: Bool] == ["secret": true])
        #expect(editor.notice == nil)
        #expect(h.model.configs[project.id]?.revision == project.revision, "stored in the cache")
    }

    @Test("REVISION_MISMATCH → banner with the current revision; reload replaces the draft")
    func revisionMismatch() async throws {
        let h = try EditorHarness()
        await h.connect()
        try h.route("PUT", "/projects/p_ordersvc2a", 409, fixture: "recorded/error-revision-mismatch.json")
        let editor = ProjectEditor(model: h.model, mode: .edit("p_ordersvc2a"))
        await editor.load()
        editor.draft.name = "changed"
        #expect(await editor.save() == nil)
        #expect(editor.notice == .revisionMismatch(currentRevision: 5))
        #expect(editor.notice?.title == "配置已被其他客户端（可能是 AI）修改")
        #expect(editor.draft.name == "changed", "local edits are kept until the user reloads")
        await editor.reloadLatest()
        #expect(editor.draft.name == "order-service")
        #expect(editor.notice == nil)
        #expect(!editor.isDirty)
        #expect(try h.bodies("PUT", "/projects/p_ordersvc2a").count == 1)
    }

    @Test("CONFIG_INVALID → issues mapped onto the cards that were sent")
    func configInvalid() async throws {
        let h = try EditorHarness()
        await h.connect()
        h.route("PUT", "/projects/p_ordersvc2a", 422, body: """
            {"error":{"code":"CONFIG_INVALID","message":"配置校验未通过","details":{"issues":[
              {"path":"services[1].command[0]","severity":"error","code":"COMMAND_NOT_FOUND","message":"在 PATH 中找不到 pnpx"},
              {"path":"params[2]","severity":"warning","code":"WARN_PARAM_UNUSED","message":"选项 host 没有被引用"}]}}}
            """)
        let editor = ProjectEditor(model: h.model, mode: .edit("p_ordersvc2a"))
        await editor.load()
        editor.draft.services[1].commandText = "pnpx next dev"
        #expect(await editor.save() == nil)
        #expect(editor.notice == .invalid(message: "配置校验未通过", issueCount: 1))
        let v = try #require(editor.validation)
        let frontend = editor.draft.services[1].id
        #expect(v.issues(row: frontend, field: "command").map(\.code) == [.error(.commandNotFound)])
        #expect(v.issues(row: editor.draft.services[0].id, field: "command").isEmpty)
        #expect(v.otherIssues.map(\.path) == ["params[2]"])
        // Moving the card keeps its issues.
        editor.moveService(frontend, by: -1)
        #expect(editor.validation?.issues(row: frontend, field: "command").count == 1)
    }

    @Test("PROJECT_RUNNING when a removed service still runs is reported as is")
    func projectRunning() async throws {
        let h = try EditorHarness()
        await h.connect()
        h.route("PUT", "/projects/p_ordersvc2a", 409, body: #"{"error":{"code":"PROJECT_RUNNING","message":"服务 frontend 正在运行，不能删除；请先停止","details":{"serviceId":"frontend"}}}"#)
        let editor = ProjectEditor(model: h.model, mode: .edit("p_ordersvc2a"))
        await editor.load()
        editor.draft.name = "x"
        _ = await editor.save()
        #expect(editor.notice == .projectRunning(message: "服务 frontend 正在运行，不能删除；请先停止", serviceId: "frontend"))
    }

    @Test("running services cannot be removed from the draft")
    func removeRunningService() async throws {
        let h = try EditorHarness()
        await h.connect()
        let editor = ProjectEditor(model: h.model, mode: .edit("p_ordersvc2a"))
        await editor.load()
        editor.removeService(editor.draft.services[0].id)
        #expect(editor.draft.services.count == 2)
        editor.addService()
        #expect(editor.draft.services.count == 3)
        #expect(editor.deleteBlockedReason(editor.draft.services[2]) == nil)
        editor.removeService(editor.draft.services[2].id)
        #expect(editor.draft.services.count == 2)
    }

    @Test("create: 201 → created, 200 created:false → alreadyRegistered, CONFIG_CONFLICT → banner")
    func create() async throws {
        let h = try EditorHarness()
        await h.connect()
        let editor = ProjectEditor(model: h.model, mode: .create)
        #expect(editor.loadState == .loaded)
        #expect(await editor.save() == nil)
        #expect(editor.notice == .fixFields)
        #expect(editor.localError("name") == "项目名称不能为空")
        #expect(try h.bodies("POST", "/projects").isEmpty, "nothing sent while local checks fail")

        editor.draft.name = "demo"
        editor.draft.root = "/tmp/devpanel-fixture/proj1"
        editor.draft.services[0].rename("应用", taken: [])
        editor.draft.services[0].setServiceId("app")
        editor.draft.services[0].commandText = "sleep 1000"
        try h.route("POST", "/projects", 201, fixture: "recorded/register-response.json")
        guard case .created(let p) = await editor.save() else {
            Issue.record("expected created")
            return
        }
        #expect(p.id == "p_fayl6lvpih")
        let body = try #require(try h.bodies("POST", "/projects").last)
        #expect(body["schemaVersion"] as? Int == 1)
        #expect(body["params"] == nil)
        #expect((body["services"] as? [[String: Any]])?.first?["command"] as? [String] == ["sleep", "1000"])

        var existing = try Fixture.decode(RegisterResponse.self, "recorded/register-response.json")
        existing.created = false
        let data = try ContractCoding.encoder().encode(existing)
        h.routes.withLock { $0["POST /api/v1/projects"] = (200, data) }
        #expect(await editor.save() == .alreadyRegistered(existing.project))

        try h.route("POST", "/projects", 409, fixture: "recorded/error-config-conflict.json")
        #expect(await editor.save() == nil)
        guard case .conflict(let projectId, let diff, _) = editor.notice else {
            Issue.record("expected conflict, got \(String(describing: editor.notice))")
            return
        }
        #expect(projectId == "p_fayl6lvpih")
        #expect(diff.first?.summary == #"name："demo" → "other""#)
    }

    @Test("validate on blur: skipped without a root, de-duplicated, result mapped to cards")
    func validate() async throws {
        let h = try EditorHarness()
        await h.connect()
        h.route("POST", "/config/validate", 200, body: """
            {"ok":false,"issues":[
              {"path":"services[0].command","severity":"warning","code":"WARN_BACKGROUND_COMMAND","message":"检测到 &"},
              {"path":"services[0].command[0]","severity":"error","code":"COMMAND_NOT_FOUND","message":"在 PATH 中找不到 mvnx"}],
             "services":[{"serviceId":"api","cwdAbs":"/tmp/x","cwdExists":true,"program":"mvnx","programResolved":null,"pathUsed":"/usr/bin:/bin"}]}
            """)
        let editor = ProjectEditor(model: h.model, mode: .create)
        await editor.validate()
        #expect(try h.bodies("POST", "/config/validate").isEmpty, "no root yet")
        editor.draft.root = "/tmp/x"
        editor.draft.services[0].setServiceId("api")
        editor.draft.services[0].commandText = "mvnx run &"
        editor.draft.services[0].env = [EnvRow(name: "API_TOKEN", value: "typed", secret: true)]
        await editor.validate()
        await editor.validate()
        let sent = try h.bodies("POST", "/config/validate")
        #expect(sent.count == 1)
        let env = (sent[0]["services"] as? [[String: Any]])?.first?["env"] as? [String: Any]
        #expect(env?["API_TOKEN"] as? [String: Bool] == ["secret": true], "typed secrets never go to validate")
        let row = editor.draft.services[0].id
        let resolution = try #require(editor.validation?.resolution(for: row))
        #expect(ResolutionLine(resolution) == .notFound(program: "mvnx", path: "/usr/bin:/bin"))
        #expect(ResolutionLine(resolution).text == "在 PATH 中找不到 mvnx（当前 PATH：/usr/bin:/bin）")
        #expect(editor.draft.services[0].backgroundHint == "&")
    }

    @Test("model actions: remove project calls DELETE and clears a selection in it")
    func removeProject() async throws {
        let h = try EditorHarness()
        await h.connect()
        h.route("DELETE", "/projects/p_mlapi22222", 204, body: "")
        h.model.select(ServiceRef("p_mlapi22222", "api"))
        try await h.model.removeProject("p_mlapi22222")
        #expect(h.model.selection == nil)
        try h.route("DELETE", "/projects/p_ordersvc2a", 409, fixture: "recorded/error-project-running.json")
        await #expect(throws: ApiError.self) { try await h.model.removeProject("p_ordersvc2a") }
        do {
            try await h.model.removeProject("p_ordersvc2a")
        } catch let e as ApiError {
            #expect(e.code == .projectRunning)
        }
    }
}

@Suite("Editor support")
struct EditorSupportTests {
    static func issue(_ path: String, _ code: String = "CONFIG_INVALID", _ severity: IssueSeverity = .error) -> ValidationIssue {
        ValidationIssue(path: path, severity: severity, code: IssueCode(rawValue: code), message: path)
    }

    @Test("issue paths map to the cards in the order they were sent")
    func mapping() {
        let a = UUID(), b = UUID(), c = UUID()
        let result = ValidateResult(ok: false, issues: [
            Self.issue("name"), Self.issue("root", "CWD_UNAVAILABLE"), Self.issue("env.PATH"),
            Self.issue("services[0].cwd", "CWD_UNAVAILABLE"), Self.issue("services[1].command[0]", "COMMAND_NOT_FOUND"),
            Self.issue("services[1].env.API_KEY", "WARN_SECRET_LIKE_PLAIN", .warning),
            Self.issue("params[0]", "WARN_PARAM_UNUSED", .warning), Self.issue("schemaVersion"),
            Self.issue("services[5].id"),
        ], services: [])
        let v = EditorValidation(result: result, sentRows: [a, b], sentServiceIds: ["x", "y"])
        #expect(v.prefix(for: b) == "services[1]")
        #expect(v.prefix(for: c) == nil)
        #expect(v.issues(row: a, field: "cwd").count == 1)
        #expect(v.issues(row: b, field: "command").count == 1)
        #expect(v.issues(row: b, field: "env").count == 1)
        #expect(v.issues(row: c, field: "command").isEmpty)
        #expect(v.issues(under: "root").count == 1)
        #expect(v.otherIssues.map(\.path) == ["params[0]", "schemaVersion", "services[5].id"])
    }

    @Test("resolution line wording")
    func resolution() {
        func r(_ cwd: Bool, _ resolved: String?, _ program: String = "mvn", path: String = "/usr/bin") -> ResolutionLine {
            ResolutionLine(ServiceResolution(
                serviceId: "a", cwdAbs: "/p/backend", cwdExists: cwd, program: program, programResolved: resolved, pathUsed: path))
        }
        #expect(r(true, "/opt/homebrew/bin/mvn").text == "将执行 /opt/homebrew/bin/mvn · 目录存在")
        #expect(r(false, nil).text == "工作目录不存在：/p/backend")
        #expect(r(true, nil, "./mvnw").text == "找不到文件 ./mvnw")
        #expect(r(true, nil).isProblem)
        #expect(r(true, nil, path: "") == .unresolved(program: "mvn"))
        #expect(!r(true, nil, path: "").isProblem)
    }

    @Test("error codes → banners")
    func notices() throws {
        let conflict = try Fixture.decode(ErrorBody.self, "recorded/error-config-conflict.json").error
        guard case .conflict(let id, let diff, _) = EditorNotice.from(conflict) else {
            Issue.record("conflict")
            return
        }
        #expect(id == "p_fayl6lvpih")
        #expect(diff.count == 14)
        let mismatch = try Fixture.decode(ErrorBody.self, "recorded/error-revision-mismatch.json").error
        #expect(EditorNotice.from(mismatch) == .revisionMismatch(currentRevision: 5))
        #expect(EditorNotice.from(mismatch).detail.hasPrefix("当前版本 r5。"))
        let invalid = try Fixture.decode(ErrorBody.self, "recorded/error-config-invalid.json").error
        #expect(EditorNotice.from(invalid) == .invalid(message: "配置校验未通过", issueCount: 2))
        let running = try Fixture.decode(ErrorBody.self, "recorded/error-project-running.json").error
        #expect(EditorNotice.from(running) == .projectRunning(message: running.message, serviceId: nil))
        let unknown = ApiError(code: .other("NEW_THING"), message: "新错误")
        #expect(EditorNotice.from(unknown) == .failed(code: "NEW_THING", message: "新错误"))
        #expect(EditorNotice.from(.unreachable()).detail.contains("DAEMON_UNREACHABLE"))
        let nullDiff = ConfigDiffEntry(path: "params[0].min", existing: nil, incoming: .number(1024))
        #expect(nullDiff.summary == "params[0].min：（无） → 1024")
    }

    @Test("removal is blocked by starting / running / stopping / unknown services")
    func removal() throws {
        let snap = try Fixture.decode(DaemonEvent.self, "recorded/event-snapshot.json")
        guard case .snapshot(let s) = snap else { return }
        let order = try #require(s.projects.first { $0.id == "p_ordersvc2a" })
        let check = RemovalCheck(order)
        #expect(!check.allowed)
        #expect(check.blocking.map(\.id) == ["backend", "frontend"])
        #expect(check.blockedReason == "后端（运行中）、前端（运行中） 尚未停止。请先停止项目的所有服务再移除。")
        let ml = try #require(s.projects.first { $0.id == "p_mlapi22222" })
        #expect(RemovalCheck(ml).allowed)
        let failed = try #require(s.projects.first { $0.id == "p_archorder2" })
        #expect(RemovalCheck(failed).allowed, "failed / exited / stopped do not block")
        var unknown = ml
        unknown.services[0].state = .unknown
        #expect(RemovalCheck(unknown).blockedReason?.contains("状态未知") == true)
        #expect(RemovalCheck.message(root: "/Users/x/p") == "只从 DevPanel 移除配置和日志，不会删除 /Users/x/p 下的任何文件。")
    }
}
