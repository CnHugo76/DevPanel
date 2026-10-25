import Foundation
import Darwin
import Testing
@testable import DevPanelKit

private func portableConfig() -> ProjectConfig {
    ProjectConfig(name: "Portable", root: "/tmp/original",
                  env: ["TOKEN": .secret(value: "source-secret"), "HOME_DIR": .plain("/Users/source/private")],
                  services: [ServiceConfig(id: "api", name: "API", cwd: "/tmp/original/backend",
                                           command: ["/opt/source/bin/node", "app.js", "--data=/Users/source/data", "${port}"])],
                  params: [ParamConfig(key: "port", label: "Port", type: .number, value: .number(8080)),
                           ParamConfig(key: "secret", label: "Secret", type: .string, value: .string("param-secret"), secret: true)])
}

private func localInputs(_ document: PortableProjectConfig) -> [String: JSONValue] {
    Dictionary(uniqueKeysWithValues: document.inputs.map { ($0.id, .string($0.kind == .secret ? "local-secret" : "/local/value")) })
}

private actor PortableSaveGate {
    private var continuation: CheckedContinuation<UpdateResponse, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func receive() async -> UpdateResponse {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            waiter?.resume(); waiter = nil
        }
    }
    func waitForRequest() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finish(_ response: UpdateResponse) { continuation?.resume(returning: response); continuation = nil }
}

@Suite("Portable configuration boundaries")
struct PortableConfigurationTests {
    @Test func importsCLIExportIncludingTypedSecretsMissingPathValueAndInstance() throws {
        let doc = try PortableConfiguration.decode(Fixture.data("handwritten/portable-cli.json"))
        let inputs = try PortableConfiguration.decodeInputs(Fixture.data("handwritten/portable-inputs.json"))
        #expect(PortableConfiguration.missing(doc, values: inputs).isEmpty)
        let config = try PortableConfiguration.materialize(doc, root: "/new/root", values: inputs)
        #expect(config.instance == ProjectInstance(group: "demo", name: "a"))
        #expect(config.params?.first { $0.key == "count" }?.value == .number(27))
        #expect(config.params?.first { $0.key == "enabled" }?.value == .bool(false))
        #expect(config.params?.first { $0.key == "path" }?.value == .string("/new/path"))
        #expect(config.actions?.first?.cwd == "/new/path")
        #expect(config.services.first?.cwd == "sub")
        let reexport = try PortableConfiguration.export(config)
        #expect(reexport.project["instance"]?["name"]?.stringValue == "a")
        #expect(!String(decoding: try PortableConfiguration.encode(reexport), as: UTF8.self).contains("local-secret"))
    }
    @Test func exportRemovesSecretsPathsAndResponseMetadataAndRelocatesCwd() throws {
        var config = portableConfig()
        config.params?[0].setBy = .user
        config.params?[0].valueUpdatedAt = "private-time"
        let exported = try PortableConfiguration.export(config)
        let data = try PortableConfiguration.encode(exported)
        let text = String(decoding: data, as: UTF8.self)
        for forbidden in ["source-secret", "param-secret", "/Users/source", "/opt/source", "/tmp/original", "setBy", "private-time", "\"root\""] {
            #expect(!text.contains(forbidden))
        }
        #expect(exported.inputs.filter { $0.kind == .secret }.count == 2)
        #expect(exported.project["services"]?.arrayValue?.first?["cwd"]?.stringValue == "backend")
        #expect(try PortableConfiguration.decode(data) == exported)
        let moved = try PortableConfiguration.materialize(exported, root: "/tmp/new-root", values: localInputs(exported))
        #expect(moved.root == PortableConfiguration.canonicalRoot("/tmp/new-root"))
        #expect(moved.services[0].cwd == "backend")
        #expect(moved.env?["TOKEN"] == .secret(value: "local-secret"))
        #expect(moved.params?.first { $0.key == "secret" }?.value == .string("local-secret"))
        #expect(moved.services[0].command[0] == "/local/value")
    }

    @Test func cannotImportMissingSecretsOrUndeclaredInputs() throws {
        let doc = try PortableConfiguration.export(portableConfig())
        #expect(!PortableConfiguration.missing(doc, values: [:]).isEmpty)
        #expect(throws: PortableConfigError.self) { try PortableConfiguration.materialize(doc, root: "/tmp/new", values: [:]) }
        var values = localInputs(doc)
        values["not-declared"] = .string("never-echo")
        #expect(throws: PortableConfigError.self) { try PortableConfiguration.materialize(doc, root: "/tmp/new", values: values) }
    }

    @Test(arguments: ["/services", "/services/0/command", "/services/0/command/99", "/services/00/command/0", "/params/0", "/root", "/__proto__/x", "/services/0/constructor/value", "/services/0/command/~2"])
    func rejectsStructuralUnknownAndPrototypeTargets(_ target: String) throws {
        var doc = try PortableConfiguration.export(ProjectConfig(name: "Safe", root: "/tmp", services: [.init(id: "api", name: "API", cwd: ".", command: ["node"])]))
        doc.inputs = [.init(id: "path", target: target, kind: .path, label: "Path", valueType: .string)]
        #expect(throws: PortableConfigError.self) { try PortableConfiguration.validate(doc) }
    }

    @Test func rejectsDuplicateTargetsAndUnmarkedSecretLocations() throws {
        var doc = try PortableConfiguration.export(portableConfig())
        var duplicate = doc.inputs[0]
        duplicate.id = "another"
        doc.inputs.append(duplicate)
        #expect(throws: PortableConfigError.self) { try PortableConfiguration.validate(doc) }
        doc.inputs.removeLast()
        let pathIndex = try #require(doc.inputs.firstIndex { $0.kind == .path })
        doc.inputs[pathIndex].kind = .secret
        #expect(throws: PortableConfigError.self) { try PortableConfiguration.validate(doc) }
    }

    @Test func secretValuesCannotBeEmbeddedInSharedDocument() throws {
        let text = #"{"format":"devpanel.project","version":1,"project":{"schemaVersion":1,"name":"P","env":{"TOKEN":{"secret":true,"value":"embedded-secret"}},"services":[{"id":"api","name":"API","cwd":".","command":["node"]}]},"inputs":[{"id":"token","target":"/env/TOKEN/value","kind":"secret","label":"Token","valueType":"string"}]}"#
        #expect(throws: PortableConfigError.self) { try PortableConfiguration.decode(Data(text.utf8)) }
    }

    @Test func pathEnumChoicesAndUnsupportedMachinePathsRefuseExport() throws {
        var config = portableConfig()
        config.params = [ParamConfig(key: "path", label: "Path", type: .enum, value: .string("/Users/me/a"), choices: [.init(value: "/Users/me/a")])]
        #expect(throws: PortableConfigError.self) { try PortableConfiguration.export(config) }
        config.params = nil
        config.maven = .init(executable: "/Users/me/mvn")
        #expect(throws: PortableConfigError.self) { try PortableConfiguration.export(config) }
    }

    @Test func fileLimitsAndScalarOnlyInputsAreEnforced() throws {
        #expect(throws: PortableConfigError.self) { try PortableConfiguration.decode(Data(repeating: 32, count: PortableConfiguration.documentByteLimit + 1)) }
        #expect(throws: PortableConfigError.self) { try PortableConfiguration.decodeInputs(Data(repeating: 32, count: PortableConfiguration.inputsByteLimit + 1)) }
        for text in [#"{"x":null}"#, #"{"x":{}}"#, #"{"x":[]}"#, #"{"__proto__":"value"}"#] {
            #expect(throws: PortableConfigError.self) { try PortableConfiguration.decodeInputs(Data(text.utf8)) }
        }
        #expect(try PortableConfiguration.decodeInputs(Data(#"{"x":false,"y":42,"z":""}"#.utf8)).count == 3)
    }

    @Test func fileReaderRejectsFIFOAndExportRefusesOverwrite() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dp-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fifo = dir.appendingPathComponent("pipe.json")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: PortableConfigError.self) { try PortableConfiguration.read(fifo, limit: 128) }
        let regular = dir.appendingPathComponent("large.json")
        try Data(repeating: 32, count: 129).write(to: regular)
        #expect(throws: PortableConfigError.self) { try PortableConfiguration.read(regular, limit: 128) }
        let output = dir.appendingPathComponent("existing.json")
        try Data("keep".utf8).write(to: output)
        #expect(throws: (any Error).self) {
            try PortableConfiguration.encode(PortableConfiguration.export(portableConfig())).write(to: output, options: [.withoutOverwriting])
        }
        #expect(try String(contentsOf: output, encoding: .utf8) == "keep")
    }

    @Test func preservesTypedSecretInputsAndRejectsWrongType() throws {
        var config = portableConfig()
        config.params = [.init(key: "privatePort", label: "Private", type: .number, value: .number(1234), secret: true)]
        let doc = try PortableConfiguration.export(config)
        let input = try #require(doc.inputs.first { $0.target == "/params/0/value" })
        var values = localInputs(doc)
        #expect(throws: PortableConfigError.self) { try PortableConfiguration.materialize(doc, root: "/tmp/new", values: values) }
        values[input.id] = .number(4321)
        let imported = try PortableConfiguration.materialize(doc, root: "/tmp/new", values: values)
        #expect(imported.params?.first?.value == .number(4321))
    }

    @Test func localStringsRejectNULAndEmptyPaths() throws {
        let doc = try PortableConfiguration.export(portableConfig())
        let path = try #require(doc.inputs.first { $0.kind == .path })
        let secret = try #require(doc.inputs.first { $0.kind == .secret })
        var values = localInputs(doc)
        values[path.id] = .string("")
        #expect(throws: PortableConfigError.self) { try PortableConfiguration.materialize(doc, root: "/tmp/new", values: values) }
        values = localInputs(doc)
        values[secret.id] = .string("bad\0secret")
        #expect(throws: PortableConfigError.self) { try PortableConfiguration.materialize(doc, root: "/tmp/new", values: values) }
    }
}

@Suite("Portable preview and save") @MainActor
struct PortableConfigSessionTests {
    private func files() throws -> (URL, URL, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dp-portable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let doc = try PortableConfiguration.export(portableConfig())
        let source = dir.appendingPathComponent("devpanel.json")
        let inputs = dir.appendingPathComponent("local.json")
        try PortableConfiguration.encode(doc).write(to: source)
        try JSONEncoder().encode(localInputs(doc)).write(to: inputs)
        return (dir, source, inputs)
    }
    private func environment(_ calls: Locked<[String]>, conflict: Bool = false) -> PortableConfigSession.Environment {
        var config = portableConfig(); config.root = PortableConfiguration.canonicalRoot("/tmp/new-root")
        config.params?[0].setBy = .user
        let saved = Project(id: "p_existing", revision: 7, createdAt: "now", updatedAt: "now", config: config)
        return .init(projects: {
            calls.withLock { $0.append("projects") }
            return [.init(id: saved.id, name: "Existing", root: saved.config.root, revision: 7, aggregate: .idle, runningCount: 0, serviceCount: 1, services: [])]
        }, project: { id in
            calls.withLock { $0.append("project") }; return saved
        }, validate: { _ in
            calls.withLock { $0.append("validate") }; return .init(ok: true, issues: [], services: [])
        }, register: { _ in
            calls.withLock { $0.append("register") }; return .init(created: true, project: saved)
        }, update: { id, revision, config in
            calls.withLock { $0.append("update:\(revision)") }
            #expect(id == "p_existing")
            #expect(revision == 7)
            #expect(config.env?["TOKEN"] == .secret(value: "local-secret"))
            if conflict { throw ApiError(code: .revisionMismatch, message: "untrusted local-secret should not appear") }
            return .init(project: saved, keptUserValues: ["port"])
        })
    }

    @Test func previewOnlyReadsAndValidatesThenSaveUsesItsRevisionAndShowsProtectedValues() async throws {
        let (dir, source, inputs) = try files()
        defer { try? FileManager.default.removeItem(at: dir) }
        let calls = Locked<[String]>([])
        let session = PortableConfigSession(mode: .importFile, environment: environment(calls))
        session.loadDocument(source); session.loadInputs(inputs); session.setRoot(URL(fileURLWithPath: "/tmp/new-root"))
        await session.prepare()
        #expect(calls.current == ["projects", "project", "validate"])
        #expect(session.canSave)
        #expect(session.preview?.protectedParamKeys == ["port"])
        #expect(session.preview?.changedPaths.contains { $0.contains("TOKEN") } == true)
        #expect(await session.save()?.id == "p_existing")
        #expect(calls.current == ["projects", "project", "validate", "update:7"])
        #expect(session.savedMessage?.contains("保留用户选项：port") == true)
        #expect(session.suppliedIds.isEmpty)
    }

    @Test func missingInputsDoNotReachDaemonAndChangesInvalidatePreparedSave() async throws {
        let (dir, source, inputs) = try files()
        defer { try? FileManager.default.removeItem(at: dir) }
        let calls = Locked<[String]>([])
        let session = PortableConfigSession(mode: .importFile, environment: environment(calls))
        session.loadDocument(source); session.setRoot(URL(fileURLWithPath: "/tmp/new-root"))
        await session.prepare()
        #expect(calls.current.isEmpty && !session.canSave)
        session.loadInputs(inputs); await session.prepare()
        #expect(session.canSave)
        session.setRoot(URL(fileURLWithPath: "/tmp/different-root"))
        #expect(!session.canSave)
        #expect(await session.save() == nil)
        #expect(!calls.current.contains { $0.hasPrefix("update") })
    }

    @Test func revisionConflictNeverRetriesOrEchoesInputAndRequiresNewPreview() async throws {
        let (dir, source, inputs) = try files()
        defer { try? FileManager.default.removeItem(at: dir) }
        let calls = Locked<[String]>([])
        let session = PortableConfigSession(mode: .importFile, environment: environment(calls, conflict: true))
        session.loadDocument(source); session.loadInputs(inputs); session.setRoot(URL(fileURLWithPath: "/tmp/new-root"))
        await session.prepare()
        #expect(await session.save() == nil)
        #expect(!session.canSave)
        #expect(session.notice?.contains("重新预览") == true)
        #expect(session.notice?.contains("local-secret") == false)
        #expect(calls.current.filter { $0.hasPrefix("update") }.count == 1)
    }

    @Test func lateSaveCompletionCannotPolluteReplacedPreview() async throws {
        let (dir, source, inputs) = try files()
        defer { try? FileManager.default.removeItem(at: dir) }
        let calls = Locked<[String]>([])
        var env = environment(calls)
        let saved = try await env.project("p_existing")
        let gate = PortableSaveGate()
        env.update = { _, _, _ in await gate.receive() }
        let session = PortableConfigSession(mode: .importFile, environment: env)
        session.loadDocument(source); session.loadInputs(inputs); session.setRoot(URL(fileURLWithPath: "/tmp/new-root"))
        await session.prepare()
        let pending = Task { await session.save() }
        await gate.waitForRequest()
        session.loadDocument(source)
        await gate.finish(.init(project: saved, keptUserValues: ["port"]))
        #expect(await pending.value == nil)
        #expect(session.savedMessage == nil)
        #expect(session.preview == nil)
        #expect(!session.busy)
    }
}
