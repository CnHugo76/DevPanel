import Foundation
import Testing

@testable import DevPanelKit

@Suite("Encoding request bodies")
struct EncodingTests {
    private let config = ProjectConfig(
        name: "demo", root: "/tmp/demo",
        env: ["TOKEN": .secret(value: "s3"), "KEEP": .secret(value: nil), "PLAIN": .plain("${port}")],
        services: [ServiceConfig(id: "app", name: "应用", cwd: ".", command: ["sleep", "${secs}"], stopTimeoutSec: 5)],
        params: [ParamConfig(key: "port", label: "端口", type: .number, value: .number(8081), min: 1024, max: 65535)])

    private func string(_ v: some Encodable) throws -> String {
        String(decoding: try ContractCoding.encoder().encode(v), as: UTF8.self)
    }

    @Test("UpdateRequest: ifRevision, config, overrideUserValues")
    func updateRequest() throws {
        let plain = try json(UpdateRequest(ifRevision: 3, config: config))
        #expect(Set(plain.keys) == ["ifRevision", "config"])
        #expect(plain["ifRevision"] as? Int == 3)
        let override = try json(UpdateRequest(ifRevision: 3, config: config, overrideUserValues: true))
        #expect(Set(override.keys) == ["ifRevision", "config", "overrideUserValues"])
        #expect(override["overrideUserValues"] as? Bool == true)
        let cfg = try #require(override["config"] as? [String: Any])
        #expect(cfg["schemaVersion"] as? Int == 1)
        #expect(Set(cfg.keys) == ["schemaVersion", "name", "root", "env", "services", "params"])
    }

    @Test("EnvValue: plain string, {secret,value}, {secret} keep")
    func envValues() throws {
        #expect(try string(EnvValue.plain("x")) == #""x""#)
        #expect(try string(EnvValue.secret(value: "v")) == #"{"secret":true,"value":"v"}"#)
        #expect(try string(EnvValue.secret(value: nil)) == #"{"secret":true}"#)
    }

    @Test("PatchParamRequest sends only present fields; integers stay integers")
    func patchParam() throws {
        #expect(try string(PatchParamRequest(ifRevision: 4, value: .number(8081))) == #"{"ifRevision":4,"value":8081}"#)
        #expect(try string(PatchParamRequest(ifRevision: 4, value: .number(0.5))) == #"{"ifRevision":4,"value":0.5}"#)
        #expect(try string(PatchParamRequest(ifRevision: 4, value: .bool(false))) == #"{"ifRevision":4,"value":false}"#)
        #expect(try string(PatchParamRequest(ifRevision: 4, value: .string("dev"))) == #"{"ifRevision":4,"value":"dev"}"#)
        let meta = try json(PatchParamRequest(
            ifRevision: 4, label: "L", description: "D", choices: [ParamChoice(value: "a", label: "A")], min: 1, max: 9))
        #expect(Set(meta.keys) == ["ifRevision", "label", "description", "choices", "min", "max"])
        #expect(meta["value"] == nil)
    }

    @Test("AddParamRequest strips response-only fields")
    func addParam() throws {
        let p = ParamConfig(
            key: "mode", label: "模式", type: .enum, value: .string("a"),
            choices: [ParamChoice(value: "a"), ParamChoice(value: "b", label: "B", description: "bee")],
            setBy: .user, valueUpdatedAt: "2026-10-20T00:00:00.000Z", describedBy: .agent,
            usedBy: [ParamReference(serviceId: "*", where: .env, envKey: "X")])
        let body = try json(AddParamRequest(ifRevision: 2, param: p))
        #expect(Set(body.keys) == ["ifRevision", "param"])
        let param = try #require(body["param"] as? [String: Any])
        #expect(Set(param.keys) == ["key", "label", "type", "value", "choices"])
        #expect(param["type"] as? String == "enum")
    }

    @Test("secret param in a request: value present sets, absent keeps")
    func secretParam() throws {
        let keep = ParamConfig(key: "tok", label: "T", type: .string, secret: true)
        #expect(try string(keep) == #"{"key":"tok","label":"T","secret":true,"type":"string"}"#)
        let set = ParamConfig(key: "tok", label: "T", type: .string, value: .string("x"), secret: true)
        #expect(try json(set)["value"] as? String == "x")
    }

    @Test("ActionRequest: kebab-case actions, serviceIds omitted for whole project")
    func actionRequest() throws {
        #expect(try string(ActionRequest(projectId: "p_1", action: .forceStop)) == #"{"action":"force-stop","projectId":"p_1"}"#)
        #expect(try string(ActionRequest(projectId: "p_1", serviceIds: ["a", "b"], action: .restart))
            == #"{"action":"restart","projectId":"p_1","serviceIds":["a","b"]}"#)
    }

    @Test func shutdownRequest() throws {
        #expect(try string(ShutdownRequest(stopServices: true)) == #"{"stopServices":true}"#)
    }

    @Test("register body is a bare ProjectConfig with contract field names")
    func registerBody() throws {
        let body = try json(config as RegisterRequest)
        let services = try #require(body["services"] as? [[String: Any]])
        #expect(Set(services[0].keys) == ["id", "name", "cwd", "command", "stopTimeoutSec"])
        let params = try #require(body["params"] as? [[String: Any]])
        #expect(params[0]["value"] as? Int == 8081)
        #expect(params[0]["min"] as? Int == 1024)
    }

    @Test("unknown enum values encode back verbatim")
    func openEnumEncode() throws {
        #expect(try string(ServiceState.other("hibernating")) == #""hibernating""#)
        #expect(try string(ListeningPort.Scope.specific) == #""other""#)
        #expect(try string(ErrorCode.daemonUnreachable) == #""DAEMON_UNREACHABLE""#)
    }
}
