import Foundation
import Darwin

public struct PortableConfigError: Error, LocalizedError, Sendable {
    public var message: String
    public var errorDescription: String? { message }
}

public enum PortableConfiguration {
    public static let documentByteLimit = 1_048_576
    public static let inputsByteLimit = 65_536

    public static func read(_ url: URL, limit: Int) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw invalid("文件无法读取；请检查路径与权限。") }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw invalid("请选择普通 JSON 文件；不读取目录、管道或设备。")
        }
        let data = try file.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw invalid("文件超过 \(limit / 1024) KiB 上限。") }
        return data
    }

    public static func decode(_ data: Data) throws -> PortableProjectConfig {
        guard data.count <= documentByteLimit else { throw invalid("共享配置超过 1 MiB 上限。") }
        let raw: JSONValue
        let document: PortableProjectConfig
        do {
            raw = try JSONDecoder().decode(JSONValue.self, from: data)
            document = try JSONDecoder().decode(PortableProjectConfig.self, from: data)
        } catch { throw invalid("共享配置格式无效；需要 devpanel.project v1 文档及 inputs 列表。") }
        guard case .object(let object) = raw, Set(object.keys) == ["format", "version", "project", "inputs"] else {
            throw invalid("共享配置只允许 format、version、project 和 inputs。")
        }
        try validate(document)
        return document
    }

    public static func decodeInputs(_ data: Data) throws -> [String: JSONValue] {
        guard data.count <= inputsByteLimit else { throw invalid("本机输入文件超过 64 KiB 上限。") }
        guard let object = try? JSONDecoder().decode(JSONValue.self, from: data), case .object(let values) = object,
              values.values.allSatisfy(isScalar), values.keys.allSatisfy({ !forbidden.contains($0) }) else {
            throw invalid("本机输入文件必须是输入 ID 到字符串、数值或布尔值的 JSON 对象。")
        }
        return values
    }

    public static func encode(_ document: PortableProjectConfig) throws -> Data {
        try validate(document)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)
        guard data.count + 1 <= documentByteLimit else { throw invalid("导出配置超过 1 MiB 上限。") }
        return data + Data([10])
    }

    public static func export(_ config: ProjectConfig) throws -> PortableProjectConfig {
        var clean = config
        clean.params = config.params?.map(\.forRequest)
        var project = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(clean))
        guard case .object(var root) = project else { throw invalid("项目配置无效。") }
        root.removeValue(forKey: "root")
        project = .object(root)
        var inputs: [PortableConfigInput] = []
        func input(_ target: [String], kind: PortableConfigInput.Kind, label: String, type: ParamType? = nil) throws {
            let pointer = pointer(target)
            inputs.append(PortableConfigInput(id: "\(kind.rawValue)_\(inputs.count + 1)", target: pointer,
                                              kind: kind, label: label, valueType: type))
            project = try replacing(project, at: target[...], with: kind == .secret ? nil : .string(""), allowMissingLeaf: kind == .secret)
        }
        func env(_ value: JSONValue?, prefix: [String], label: String) throws {
            guard case .object(let map) = value else { return }
            for key in map.keys.sorted() {
                if map[key]?["secret"]?.boolValue == true {
                    try input(prefix + [key, "value"], kind: .secret, label: "\(label)环境变量 \(key)", type: .string)
                } else if let text = map[key]?.stringValue, isMachinePath(text) {
                    try input(prefix + [key], kind: .path, label: "\(label)环境变量 \(key)", type: .string)
                }
            }
        }
        try env(project["env"], prefix: ["env"], label: "项目 ")
        for collection in ["services", "actions"] {
            let list = project[collection]?.arrayValue ?? []
            for (index, item) in list.enumerated() {
                let base = [collection, String(index)]
                let name = item["name"]?.stringValue ?? item["id"]?.stringValue ?? String(index + 1)
                if let cwd = item["cwd"]?.stringValue, (cwd as NSString).isAbsolutePath {
                    if let relative = relativePath(cwd, root: config.root) {
                        project = try replacing(project, at: (base + ["cwd"])[...], with: .string(relative))
                    } else {
                        try input(base + ["cwd"], kind: .path, label: "\(name) 工作目录", type: .string)
                    }
                }
                for (arg, value) in (item["command"]?.arrayValue ?? []).enumerated() {
                    if let text = value.stringValue, isMachinePath(text) {
                        try input(base + ["command", String(arg)], kind: .path, label: "\(name) 命令参数 \(arg + 1)", type: .string)
                    }
                }
                try env(item["env"], prefix: base + ["env"], label: "\(name) ")
            }
        }
        for (index, param) in (project["params"]?.arrayValue ?? []).enumerated() {
            let key = param["key"]?.stringValue ?? String(index)
            if (param["choices"]?.arrayValue ?? []).contains(where: { isMachinePath($0["value"]?.stringValue ?? "") }) {
                throw invalid("选项 \(key) 的枚举取值包含本机路径；请改为 string 选项后再导出。")
            }
            let type = param["type"]?.stringValue.map(ParamType.init(raw:))
            if param["secret"]?.boolValue == true {
                try input(["params", String(index), "value"], kind: .secret, label: "选项 \(key)", type: type)
            } else if let value = param["value"]?.stringValue, isMachinePath(value) {
                try input(["params", String(index), "value"], kind: .path, label: "选项 \(key)", type: type)
            }
        }
        // Executables outside supported input locations must use a portable command name.
        if let executable = project["maven"]?["executable"]?.stringValue, isMachinePath(executable) {
            throw invalid("Maven 可执行文件含本机绝对路径；请改为 auto、wrapper 或 mvn 后再导出。")
        }
        for item in project["mavenProjects"]?.arrayValue ?? [] {
            if let executable = item["executable"]?.stringValue, isMachinePath(executable) {
                throw invalid("Maven 工程的可执行文件含本机绝对路径；请改为 auto、wrapper 或 mvn 后再导出。")
            }
        }
        let result = PortableProjectConfig(format: "devpanel.project", version: 1, project: project, inputs: inputs)
        try validate(result)
        return result
    }

    public static func missing(_ document: PortableProjectConfig, values: [String: JSONValue]) -> [PortableConfigInput] {
        document.inputs.filter { values[$0.id] == nil }
    }

    public static func materialize(_ document: PortableProjectConfig, root: String, values: [String: JSONValue]) throws -> ProjectConfig {
        try validate(document)
        let required = Set(document.inputs.map(\.id))
        guard Set(values.keys).isSubset(of: required) else { throw invalid("本机输入包含共享配置未声明的 ID。") }
        guard missing(document, values: values).isEmpty else { throw invalid("仍有必填本机输入缺失；不会把缺失秘密解释为清空。") }
        guard (root as NSString).isAbsolutePath else { throw invalid("请选择本机项目的绝对根目录。") }
        var project = document.project
        for input in document.inputs {
            let tokens = try tokens(input.target)
            let expected = try allowedType(input, project: project, tokens: tokens)
            let value = values[input.id]!
            guard matches(value, type: expected) else { throw invalid("输入 \(input.id) 的类型不符；需要 \(expected.rawValue)。") }
            if case .string(let text) = value {
                guard !text.contains("\0"), input.kind != .path || !text.isEmpty else {
                    throw invalid("输入 \(input.id) 不合法：字符串不能包含 NUL，路径输入不能为空。")
                }
            }
            project = try replacing(project, at: tokens[...], with: value,
                                    allowMissingLeaf: input.kind == .secret || (tokens.count == 3 && tokens[0] == "params" && tokens[2] == "value"))
        }
        project = try replacing(project, at: ["root"][...], with: .string(canonicalRoot(root)), allowMissingLeaf: true)
        do { return try project.decode(as: ProjectConfig.self) }
        catch { throw invalid("填写后的项目结构无效；请检查共享配置的字段类型。") }
    }

    public static func canonicalRoot(_ root: String) -> String {
        URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
    }

    public static func validate(_ document: PortableProjectConfig) throws {
        guard document.format == "devpanel.project", document.version == 1, case .object(let project) = document.project,
              project["root"] == nil, Set(project.keys).isSubset(of: projectKeys) else {
            throw invalid("共享配置必须是 devpanel.project v1，且不能包含 root、项目 ID、revision 或托管规则。")
        }
        var ids = Set<String>(), targets = Set<String>()
        for input in document.inputs {
            guard !input.id.isEmpty, !forbidden.contains(input.id), ids.insert(input.id).inserted,
                  targets.insert(input.target).inserted else { throw invalid("输入 ID 和目标必须唯一，且不能使用原型属性。") }
            let parts = try tokens(input.target)
            _ = try allowedType(input, project: document.project, tokens: parts)
        }
        for target in secretTargets(document.project) {
            guard value(document.project, at: try tokens(target)) == nil,
                  document.inputs.contains(where: { $0.target == target && $0.kind == .secret }) else {
                throw invalid("秘密值必须移到独立本机输入文件，并声明必填输入。")
            }
        }
    }

    private static let forbidden: Set<String> = ["__proto__", "constructor", "prototype"]
    private static let projectKeys: Set<String> = ["schemaVersion", "name", "services", "env", "params", "actions", "maven", "repositories", "mavenProjects", "instance"]
    private static func invalid(_ message: String) -> PortableConfigError { PortableConfigError(message: message) }
    private static func isScalar(_ value: JSONValue) -> Bool {
        switch value { case .string, .bool: true; case .number(let n): n.isFinite; default: false }
    }
    private static func matches(_ value: JSONValue, type: ParamType) -> Bool {
        switch (value, type) { case (.string, .string), (.string, .enum), (.bool, .boolean): true; case (.number(let n), .number): n.isFinite; default: false }
    }
    private static func pointer(_ tokens: [String]) -> String {
        "/" + tokens.map { $0.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1") }.joined(separator: "/")
    }
    private static func tokens(_ pointer: String) throws -> [String] {
        guard pointer.hasPrefix("/"), !pointer.dropFirst().isEmpty else { throw invalid("本机输入目标必须是受支持的 JSON Pointer。") }
        let raw = pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard raw.allSatisfy({ $0.range(of: "~(?![01])", options: .regularExpression) == nil }) else { throw invalid("输入目标的 JSON Pointer 转义无效。") }
        let parts = raw.map { $0.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~") }
        guard parts.allSatisfy({ !forbidden.contains($0) }) else { throw invalid("输入目标不能使用原型属性。") }
        return parts
    }
    private static func value(_ node: JSONValue, at path: [String]) -> JSONValue? {
        var current = node
        for token in path {
            if case .object(let dict) = current, let item = dict[token] { current = item }
            else if case .array(let list) = current, let index = Int(token), String(index) == token, list.indices.contains(index) { current = list[index] }
            else { return nil }
        }
        return current
    }
    private static func allowedType(_ input: PortableConfigInput, project: JSONValue, tokens: [String]) throws -> ParamType {
        var type: ParamType = .string
        var expectedSecret = false
        var allowed = false
        if tokens.count == 3, tokens[0] == "params", let param = value(project, at: Array(tokens.prefix(2))), tokens[2] == "value" {
            expectedSecret = param["secret"]?.boolValue == true
            type = ParamType(raw: param["type"]?.stringValue ?? "invalid")
            allowed = type.isKnown
        } else {
            var base: [String] = []
            var rest = tokens
            if tokens.count >= 3, ["services", "actions"].contains(tokens[0]) {
                base = Array(tokens.prefix(2)); rest = Array(tokens.dropFirst(2))
                guard value(project, at: base) != nil else { throw invalid("输入目标不存在。") }
                if rest == ["cwd"] || (rest.count == 2 && rest[0] == "command") { allowed = true }
            }
            if rest.first == "env", rest.count == 2 || rest.count == 3 {
                let env = value(project, at: base + Array(rest.prefix(2)))
                expectedSecret = env?["secret"]?.boolValue == true
                allowed = expectedSecret ? rest.count == 3 && rest[2] == "value" : rest.count == 2
            }
        }
        guard allowed, expectedSecret == (input.kind == .secret), input.valueType == nil || input.valueType == type else {
            throw invalid("输入 \(input.id) 的目标、秘密标记或类型声明不受支持。")
        }
        if input.kind == .path {
            let stored = value(project, at: tokens)
            let declaredParam = tokens.count == 3 && tokens[0] == "params" && tokens[2] == "value"
            guard (stored?.stringValue != nil || (declaredParam && stored == nil)), type == .string || type == .enum else {
                throw invalid("路径输入只能替换已存在的字符串标量。")
            }
        }
        return type
    }
    private static func replacing(_ node: JSONValue, at path: ArraySlice<String>, with replacement: JSONValue?, allowMissingLeaf: Bool = false) throws -> JSONValue {
        guard let first = path.first else { return replacement ?? .null }
        if case .object(var dict) = node {
            if path.count == 1 {
                guard dict[first] != nil || allowMissingLeaf else { throw invalid("输入目标不存在。") }
                dict[first] = replacement
            } else {
                guard let child = dict[first] else { throw invalid("输入目标不存在。") }
                dict[first] = try replacing(child, at: path.dropFirst(), with: replacement, allowMissingLeaf: allowMissingLeaf)
            }
            return .object(dict)
        }
        if case .array(var list) = node, let index = Int(first), String(index) == first, list.indices.contains(index) {
            guard path.count > 1 || replacement != nil else { throw invalid("输入不能改变数组结构。") }
            list[index] = try replacing(list[index], at: path.dropFirst(), with: replacement, allowMissingLeaf: allowMissingLeaf)
            return .array(list)
        }
        throw invalid("输入不能改变配置结构。")
    }
    private static func secretTargets(_ project: JSONValue) -> [String] {
        var targets: [String] = []
        func env(_ node: JSONValue?, base: [String]) {
            guard case .object(let values) = node else { return }
            for (key, value) in values where value["secret"]?.boolValue == true { targets.append(pointer(base + [key, "value"])) }
        }
        env(project["env"], base: ["env"])
        for collection in ["services", "actions"] {
            for (i, item) in (project[collection]?.arrayValue ?? []).enumerated() { env(item["env"], base: [collection, String(i), "env"]) }
        }
        for (i, item) in (project["params"]?.arrayValue ?? []).enumerated() where item["secret"]?.boolValue == true {
            targets.append(pointer(["params", String(i), "value"]))
        }
        return targets
    }
    private static func relativePath(_ path: String, root: String) -> String? {
        let root = canonicalRoot(root)
        let absolute = canonicalRoot(path)
        if absolute == root { return "." }
        let prefix = root == "/" ? "/" : root + "/"
        return absolute.hasPrefix(prefix) ? String(absolute.dropFirst(prefix.count)) : nil
    }
    private static func isMachinePath(_ text: String) -> Bool {
        text.range(of: #"(?:^|[\s='\"(:])(?:/(?!/)|~[/\\]|[A-Za-z]:[/\\])|file://"#, options: .regularExpression) != nil
    }
}
