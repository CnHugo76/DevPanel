import Foundation
import Testing
@testable import DevPanelKit

private func deploymentParameters() -> [ActionParamConfig] {
    [.init(key: "services", label: "部署服务", type: .multiselect, required: true,
           defaultValue: .strings(["frontend", "backend"]), choices: [
            .init(value: "frontend", label: "前端"), .init(value: "backend", label: "后端"), .init(value: "runtime", label: "Runtime")]),
     .init(key: "backup", label: "备份数据库", type: .boolean, defaultValue: .bool(true))]
}
private func deploymentView() -> ProjectView {
    var p = TaskTests().project(TaskTests().task())
    p.actions[0].name = "示例打包部署"; p.actions[0].params = deploymentParameters(); p.actions[0].runLabel = "开始部署"
    return p
}

@Suite("Action parameters") struct ActionParameterTests {
    @Test @MainActor func runDefaultsAreTransientAndFalseZeroEmptyArePreserved() throws {
        let p = deploymentView(), a = p.actions[0]
        let form = ActionRunSession(project: p, action: a)
        #expect(form.runLabel == "开始部署")
        #expect(form.fields[0].input.selections == ["frontend", "backend"])
        #expect(form.fields[1].input.boolean)
        form.fields[0].input.selections = ["backend", "runtime"]; form.fields[1].input.boolean = false
        let request = try #require(form.request())
        #expect(request.params == ["services": .strings(["backend", "runtime"]), "backup": .bool(false)])
        #expect(request.ifRevision == p.revision)
        let reopened = ActionRunSession(project: p, action: a)
        #expect(reopened.fields[0].input.selections == ["frontend", "backend"])
        #expect(reopened.fields[1].input.boolean)
        let number = ActionParamConfig(key: "n", label: "数量", type: .number, required: true, defaultValue: .number(0), min: 0)
        #expect(try ActionParameterInput(number).value(for: number) == .number(0))
        var multi = deploymentParameters()[0]; multi.required = false
        var input = ActionParameterInput(multi); input.selections = []
        #expect(try input.value(for: multi) == .strings([]))
    }
    @Test @MainActor func requiredAndChangedChoicesBlockRequestWithoutLosingDraft() throws {
        var p = deploymentView()
        p.actions[0].params?.append(.init(key: "tag", label: "版本", type: .string, required: true))
        let form = ActionRunSession(project: p, action: p.actions[0])
        #expect(form.request() == nil && form.errors["tag"] != nil)
        form.fields[2].input.text = "release 1"
        form.fields[0].input.selections = ["missing"]
        #expect(form.request() == nil && form.errors["services"] != nil)
        #expect(form.fields[2].input.text == "release 1")
        let pnum = ActionParamConfig(key: "n", label: "N", type: .number, min: 1, max: 3)
        var input = ActionParameterInput(pnum); input.enabled = true; input.text = "4"
        #expect(throws: ActionParameterError.self) { try input.value(for: pnum) }
    }
    @Test @MainActor func staleRebaseKeepsTypedValuesAndRevalidatesNewChoices() throws {
        let view = deploymentView(), form = ActionRunSession(project: view, action: view.actions[0])
        form.fields[0].input.selections = ["runtime"]; form.fields[1].input.boolean = false
        var action = ActionConfig(id: "build", name: "New deploy", command: ["echo", "${action.services}"])
        action.params = deploymentParameters(); action.params?[0].choices?.removeLast()
        let p = Project(id: view.id, revision: 2, createdAt: "now", updatedAt: "now", config: .init(name: "P", root: "/tmp/p", services: [], actions: [action]))
        form.stale = true; form.rebase(project: p, action: action)
        #expect(!form.stale && form.revision == 2 && form.fields[1].input.boolean == false)
        #expect(form.request() == nil && form.errors["services"] != nil)
    }
    @Test func defaultsDraftRoundtripAndSecretKeepRemove() throws {
        var action = ActionConfig(id: "deploy", name: "Deploy", command: ["echo", "${action.services}"])
        action.params = deploymentParameters() + [.init(key: "token", label: "令牌", type: .string, defaultValue: .secret, secret: true)]
        action.runLabel = "开始部署"
        let config = ProjectConfig(name: "P", root: "/tmp/p", services: [.init(id: "web", name: "Web", cwd: ".", command: ["node", "web.mjs"])], actions: [action])
        var draft = ProjectDraft(config: config)
        #expect(draft.build().errors.isEmpty)
        #expect(draft.build().config == config)
        draft.actions[0].params[2].hasDefault = false
        #expect(draft.build().config.actions?[0].params?[2].defaultValue == nil)
        var input = ActionParameterInput(action.params![2])
        #expect(try input.value(for: action.params![2]) == nil)
        input.useStoredDefault = false; input.text = "one-time-secret"
        #expect(try input.value(for: action.params![2]) == .string("one-time-secret"))
        var number = ActionParameterDraft(.init(key: "n", label: "N", type: .number))
        number.minText = "nan"
        #expect(throws: ActionParameterError.self) { try number.build() }
        number.minText = "2"; number.maxText = "1"
        #expect(throws: ActionParameterError.self) { try number.build() }
    }
    @Test func snapshotsRetainLabelsAndOldPayloadsDecode() throws {
        let data = Data(#"[{"key":"services","label":"部署服务","type":"multiselect","value":["backend","runtime"],"choices":[{"value":"backend","label":"后端"},{"value":"runtime","label":"Runtime"}]},{"key":"backup","label":"备份数据库","type":"boolean","value":false},{"key":"token","label":"令牌","type":"string","value":{"secret":true}},{"key":"empty","label":"空值","type":"string","value":null}]"#.utf8)
        let values = try ContractCoding.decoder().decode([ActionParamSnapshot].self, from: data)
        #expect(values.map(\.display) == ["后端、Runtime", "关闭", "••••", "未提供"])
        let old = try ContractCoding.decoder().decode(ActionConfig.self, from: Data(#"{"id":"old","name":"Old","cwd":".","command":["echo"]}"#.utf8))
        #expect(old.params == nil)
        #expect(try ContractCoding.decoder().decode(ActionParamType.self, from: Data(#""future""#.utf8)) == .other("future"))
    }
    @Test func capabilityGuardPreventsOldDaemonIgnoringValues() async throws {
        let info = try Fixture.data("recorded/daemon-info.json")
        let transport = FakeTransport { _ in (200, info) }
        let client = testClient(transport)
        do { _ = try await client.startAction("p", actionId: "build", request: .init(params: ["backup": .bool(false)])); Issue.record("Must reject old daemon") }
        catch { #expect(error.localizedDescription.contains("不支持操作参数")) }
        #expect(transport.requests.current.map { $0.httpMethod } == ["GET"])
        var action = ActionConfig(id: "deploy", name: "Deploy", command: ["echo"]); action.params = deploymentParameters()
        do { _ = try await client.register(.init(name: "P", root: "/tmp/p", services: [], actions: [action])); Issue.record("Must reject old daemon") }
        catch { #expect(error.localizedDescription.contains("不支持操作参数")) }
        #expect(transport.requests.current.allSatisfy { $0.httpMethod == "GET" })
    }
    @Test func clientSendsTypedBodyAndRevision() async throws {
        var info = try Fixture.decode(DaemonInfo.self, "recorded/daemon-info.json"); info.capabilities = ["action-params-v1"]
        let infoData = try ContractCoding.encoder().encode(info)
        let response = try ContractCoding.encoder().encode(StartTaskRunResponse(created: true, run: TaskTests().task(.running)))
        let transport = FakeTransport { r in r.httpMethod == "GET" ? (200, infoData) : (202, response) }
        let request = ActionRunRequest(params: ["services": .strings(["backend", "runtime"]), "backup": .bool(false)], ifRevision: 7)
        _ = try await testClient(transport).startAction("p", actionId: "build", request: request)
        let sent = try #require(transport.requests.current.last)
        #expect(try ContractCoding.decoder().decode(ActionRunRequest.self, from: #require(sent.httpBody)) == request)
        #expect(sent.value(forHTTPHeaderField: "X-DevPanel-Client") == "ui")
    }
    @Test func portableMultiselectDefaultsAreLocalTypedInputsAndSecretsStayMasked() throws {
        var action = ActionConfig(id: "deploy", name: "Deploy", command: ["node", "deploy.mjs", "${action.services}"])
        action.params = deploymentParameters() + [.init(key: "tokens", label: "令牌", type: .multiselect, defaultValue: .strings(["private-value"]), choices: [.init(value: "private-value")], secret: true)]
        // Choice metadata is public. The default must be masked and refilled, even when it matches a choice.
        let doc = try PortableConfiguration.export(.init(name: "P", root: "/tmp/p", services: [.init(id: "web", name: "Web", cwd: ".", command: ["node", "web.mjs"])], actions: [action]))
        let input = try #require(doc.inputs.first { $0.target == "/actions/0/params/2/default" })
        #expect(input.valueType == .multiselect)
        #expect(doc.project["actions"]?.arrayValue?[0]["params"]?.arrayValue?[2]["default"]?["secret"] == .bool(true))
        #expect(throws: PortableConfigError.self) { try PortableConfiguration.materialize(doc, root: "/tmp/new", values: [input.id: .string("wrong-type")]) }
        let config = try PortableConfiguration.materialize(doc, root: "/tmp/new", values: [input.id: .array([.string("private-value")])])
        #expect(config.actions?[0].params?[2].defaultValue == .strings(["private-value"]))
        var stripped = doc; stripped.inputs = []
        #expect(throws: PortableConfigError.self) { try PortableConfiguration.validate(stripped) }
    }
}

@Suite("Action run form requests") @MainActor struct ActionRunFormTests {
    @Test func cancelDoesNotPostAndReopenResetsDefaults() async throws {
        let daemon = FakeDaemon(), stream = try daemon.connectedStream()
        daemon.enqueue(.stream(stream))
        let model = AppModel(environment: .init(discover: { testDiscovery }, makeClient: { DaemonClient(discovery: $0, transport: daemon.transport) }))
        model.start(); defer { model.stop(); stream.finish() }
        await eventually { model.isConnected }
        var snapshot = try AppModelTests.snapshot(); snapshot.daemon.capabilities = ["action-params-v1"]; snapshot.projects = [deploymentView()]
        model.apply(.snapshot(snapshot))
        model.requestQuickAction("p_tasks", actionId: "build")
        let form = try #require(model.projectInspector.parameterForm)
        form.fields[1].input.boolean = false
        model.projectInspector.parameterForm = nil
        #expect(!daemon.transport.requests.current.contains { $0.httpMethod == "POST" })
        model.requestQuickAction("p_tasks", actionId: "build")
        #expect(model.projectInspector.parameterForm?.fields[1].input.boolean == true)
        let reopened = try #require(model.projectInspector.parameterForm)
        reopened.isSubmitting = true
        model.requestQuickAction("p_tasks", actionId: "build")
        #expect(model.projectInspector.parameterForm === reopened)
        reopened.isSubmitting = false
        form.stale = true
        await model.submitActionParameters(form)
        #expect(!daemon.transport.requests.current.contains { $0.httpMethod == "POST" })
    }
    @Test func staleSubmissionStaysInFormAndDoesNotRetry() async throws {
        let daemon = FakeDaemon(), stream = try daemon.connectedStream()
        daemon.enqueue(.stream(stream))
        var info = try Fixture.decode(DaemonInfo.self, "recorded/daemon-info.json"); info.capabilities = ["action-params-v1"]
        let infoData = try ContractCoding.encoder().encode(info)
        daemon.transport.setHandler { request in
            if request.url?.path.hasSuffix("/daemon") == true { return (200, infoData) }
            if request.httpMethod == "POST" { return (409, Data(#"{"error":{"code":"REVISION_MISMATCH","message":"配置已变更"}}"#.utf8)) }
            return (200, Data("[]".utf8))
        }
        let model = AppModel(environment: .init(discover: { testDiscovery }, makeClient: { DaemonClient(discovery: $0, transport: daemon.transport) }))
        model.start(); defer { model.stop(); stream.finish() }
        await eventually { model.isConnected }
        var snapshot = try AppModelTests.snapshot(); snapshot.daemon.capabilities = ["action-params-v1"]; snapshot.projects = [deploymentView()]
        model.apply(.snapshot(snapshot)); model.requestQuickAction("p_tasks", actionId: "build")
        let form = try #require(model.projectInspector.parameterForm)
        form.fields[1].input.boolean = false
        await model.submitActionParameters(form)
        #expect(form.stale && !form.isSubmitting && model.projectInspector.parameterForm === form)
        #expect(form.fields[1].input.boolean == false)
        await model.submitActionParameters(form)
        #expect(daemon.transport.requests.current.filter { $0.httpMethod == "POST" }.count == 1)
        model.projectInspector.actionChoice["p_tasks"] = "other"
        #expect(model.projectInspector.parameterForm == nil)
    }
    @Test func unknownSubmissionQueriesHistoryAndBlocksRetry() async throws {
        let daemon = FakeDaemon(), stream = try daemon.connectedStream()
        daemon.enqueue(.stream(stream))
        var info = try Fixture.decode(DaemonInfo.self, "recorded/daemon-info.json"); info.capabilities = ["action-params-v1"]
        let infoData = try ContractCoding.encoder().encode(info)
        daemon.transport.setHandler { request in
            if request.url?.path.hasSuffix("/daemon") == true { return (200, infoData) }
            if request.httpMethod == "POST" { throw URLError(.networkConnectionLost) }
            return (200, Data("[]".utf8))
        }
        let model = AppModel(environment: .init(discover: { testDiscovery }, makeClient: { DaemonClient(discovery: $0, transport: daemon.transport) }))
        model.start(); defer { model.stop(); stream.finish() }
        await eventually { model.isConnected }
        var snapshot = try AppModelTests.snapshot(); snapshot.daemon.capabilities = ["action-params-v1"]; snapshot.projects = [deploymentView()]
        model.apply(.snapshot(snapshot)); model.requestQuickAction("p_tasks", actionId: "build")
        let form = try #require(model.projectInspector.parameterForm)
        await model.submitActionParameters(form); await model.submitActionParameters(form)
        #expect(form.uncertain && model.projectInspector.parameterForm === form)
        #expect(daemon.transport.requests.current.filter { $0.httpMethod == "POST" }.count == 1)
        #expect(daemon.transport.requests.current.contains { $0.httpMethod == "GET" && $0.url?.path.hasSuffix("/actions/build/runs") == true })
    }
    @Test func parameterlessActionKeepsOneClickAndNoCapabilityRequest() async throws {
        let daemon = FakeDaemon(), stream = try daemon.connectedStream()
        daemon.enqueue(.stream(stream))
        let p = TaskTests().project(TaskTests().task())
        let pData = try ContractCoding.encoder().encode(p)
        let response = try ContractCoding.encoder().encode(StartTaskRunResponse(created: true, run: TaskTests().task(.running)))
        daemon.transport.setHandler { request in
            if request.httpMethod == "POST" { return (202, response) }
            if request.url?.path.hasSuffix("/view") == true { return (200, pData) }
            return (200, Data("[]".utf8))
        }
        let model = AppModel(environment: .init(discover: { testDiscovery }, makeClient: { DaemonClient(discovery: $0, transport: daemon.transport) }))
        model.start(); defer { model.stop(); stream.finish() }
        await eventually { model.isConnected }
        model.apply(.projectUpsert(p)); model.requestQuickAction(p.id, actionId: "build")
        await eventually { daemon.transport.requests.current.contains { $0.httpMethod == "POST" } }
        #expect(model.projectInspector.parameterForm == nil)
        #expect(!daemon.transport.requests.current.contains { $0.url?.path.hasSuffix("/daemon") == true })
    }
}
