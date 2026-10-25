import Foundation
import Testing
@testable import DevPanelKit

@Suite("Option editing") struct OptionTests {
    @Test(arguments: ["a", "Z9_", String(repeating: "x", count: 32)])
    func validKeys(_ key: String) { #expect(OptionRules.validKey(key)) }
    @Test(arguments: ["", "_a", "1x", "a-b", "汉字", "a\n", String(repeating: "x", count: 33)])
    func invalidKeys(_ key: String) { #expect(!OptionRules.validKey(key)) }
    @Test func typesAndBounds() throws {
        let number = ParamConfig(key: "p", label: "端口", type: .number, min: 1, max: 65535)
        #expect(try OptionRules.value("8081", for: number) == .number(8081))
        for text in ["", "nan", "inf", "0", "65536", "x"] {
            #expect(throws: ApiError.self) { try OptionRules.value(text, for: number) }
        }
        #expect(try OptionRules.value("true", for: .init(key: "b", label: "", type: .boolean)) == .bool(true))
        #expect(throws: ApiError.self) { try OptionRules.value("1", for: .init(key: "b", label: "", type: .boolean)) }
        #expect(throws: ApiError.self) { try OptionRules.value("x", for: .init(key: "e", label: "", type: .enum, choices: [.init(value: "y")])) }
        #expect(try OptionRules.value("", for: .init(key: "s", label: "", type: .string, secret: true)) == nil)
        #expect(try OptionRules.value("", for: .init(key: "s", label: "", type: .string), creating: true) == .string(""))
    }
    @Test func inlineEscapesAndReferences() {
        let p = ParamConfig(key: "p", label: "", type: .string, value: .string("it's ${HOME}"), usedBy: [.init(serviceId: "s", where: .command, index: 2)])
        let q = ParamConfig(key: "q", label: "", type: .string, value: .string("keep"))
        let config = ProjectConfig(name: "", root: "/tmp", services: [.init(id: "s", name: "服务", cwd: ".", command: ["/bin/sh", "-c", "echo ${p} ${q} $${HOME}"])], params: [p, q])
        let preview = OptionRules.references(p, config: config, inline: true)
        #expect(preview.first?.text == "echo 'it'\\''s $${HOME}' ${q} $${HOME}")
        #expect(preview.first?.location == "服务 命令")
        var secret = p; secret.secret = true
        #expect(OptionRules.blocksInline(secret))
        secret.usedBy = [.init(serviceId: "*", where: .env, envKey: "TOKEN")]
        var env = config; env.env = ["TOKEN": .plain("prefix-${p}-${q}")]
        #expect(!OptionRules.blocksInline(secret))
        #expect(OptionRules.references(secret, config: env, inline: true).first?.text == "••••（写回为敏感环境变量）")
    }
    @Test func precisePending() throws {
        var project = try Fixture.decode(ProjectView.self, "recorded/project-view.json")
        var detail = try Fixture.decode(RunDetail.self, "recorded/run-detail.json")
        let run = try #require(project.services[0].currentRun)
        detail.id = run.id; detail.params = ["p": .value(.number(80))]
        project.services[0].configChangedSinceStart = true
        var param = ParamConfig(key: "p", label: "", type: .number, value: .number(81), valueUpdatedAt: run.startedAt, usedBy: [.init(serviceId: "*", where: .env, envKey: "PORT")])
        #expect(param.isPending(in: project, details: [run.id: detail], serviceId: project.services[0].id))
        param.value = .number(80)
        #expect(!param.isPending(in: project, details: [run.id: detail], serviceId: project.services[0].id))
        detail.params = [:]
        param.value = .number(82)
        #expect(!param.isPending(in: project, details: [run.id: detail], serviceId: project.services[0].id), "overridden project env is not actually used")
    }
    @Test func errorsAndAttribution() {
        #expect(OptionRules.errorText(.init(code: .paramUnknown, message: "")).contains("已被其他客户端删除"))
        #expect(OptionRules.errorText(.init(code: .revisionMismatch, message: "")).contains("保留你的输入"))
        #expect(OptionRules.attribution(.init(key: "p", label: "", type: .string, describedBy: .user)) == "说明由你编辑")
    }
}

@MainActor @Suite("Option revision safety", .serialized) struct OptionSessionTests {
    @Test func conflictRetainsInputAndRetriesFreshRevision() async throws {
        let daemon = FakeDaemon()
        var project = try Fixture.decode(Project.self, "recorded/project-order-service.json")
        let initial = project
        project.revision += 1
        project.config.params?[0].label = "外部新名称"
        let fresh = project
        let patches = Locked(0)
        daemon.transport.setHandler { req in
            if req.httpMethod == "PATCH" {
                patches.withLock { $0 += 1 }
                if patches.current == 1 { return (409, try ContractCoding.encoder().encode(ErrorBody(error: .init(code: .revisionMismatch, message: "conflict")))) }
                let body = try ContractCoding.decoder().decode(PatchParamRequest.self, from: req.httpBody!)
                #expect(body.ifRevision == fresh.revision)
                #expect(body.value == .string("prod"))
                #expect(body.label == nil, "retry must not overwrite unrelated external metadata")
            }
            return (200, try ContractCoding.encoder().encode(fresh))
        }
        daemon.enqueue(.stream(try daemon.connectedStream()))
        let model = AppModel(environment: .init(discover: { testDiscovery }, makeClient: { DaemonClient(discovery: $0, transport: daemon.transport) }))
        model.start(); defer { model.stop() }
        await eventually { model.isConnected }
        let param = try #require(initial.config.params?.first { $0.key == "profile" })
        let e = OptionEditor(model: model, project: initial, param: param)
        e.text = "prod"
        #expect(await e.save() == false)
        #expect(e.conflict && e.text == "prod")
        #expect(e.revision == fresh.revision)
        #expect(await e.save())
        #expect(!e.conflict)
    }
}
