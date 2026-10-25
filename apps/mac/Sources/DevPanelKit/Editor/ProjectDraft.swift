import Foundation

// The editable form model of `ProjectConfig` (ui-design §6, v2 §6) and its conversion both ways.
//
// `ProjectDraft(config:)` followed by `build(.save).config` gives back the same config (params
// carried over untouched, minus response-only metadata; secrets in their "keep" form), so opening
// and saving a project without changes never alters it.

/// One environment variable row.
public struct EnvRow: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    /// Plain value, or a newly typed secret value (never pre-filled: the daemon never returns one).
    public var value: String
    public var secret: Bool
    /// Name under which a secret value is stored on the daemon (from the loaded config); an empty
    /// value keeps it as long as the row still has this name in the same service.
    public var storedName: String?
    /// The user flipped the secret switch: stop deriving it from the name.
    public var secretTouched: Bool

    public init(
        id: UUID = UUID(), name: String = "", value: String = "", secret: Bool = false,
        storedName: String? = nil, secretTouched: Bool = false
    ) {
        self.id = id
        self.name = name
        self.value = value
        self.secret = secret
        self.storedName = storedName
        self.secretTouched = secretTouched
    }

    /// Names containing TOKEN, SECRET, PASSWORD, KEY (also PASSWD, CREDENTIAL) default to secret.
    public static func looksSecret(_ name: String) -> Bool {
        let n = name.uppercased()
        return ["TOKEN", "SECRET", "PASSWORD", "PASSWD", "KEY", "CREDENTIAL"].contains { n.contains($0) }
    }

    /// Renames the row; the secret switch follows the name until the user touches it.
    public mutating func rename(_ newName: String) {
        name = newName
        if !secretTouched { secret = Self.looksSecret(newName) }
    }

    public mutating func setSecret(_ on: Bool) {
        secret = on
        secretTouched = true
    }

    var isBlank: Bool { name.trimmingCharacters(in: .whitespaces).isEmpty && value.isEmpty }
}

/// One service card.
public struct ServiceDraft: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var serviceId: String
    /// The ID follows the name until the user edits it (new services only).
    public var idAuto: Bool
    /// ID of the saved service this card edits; nil for a service added in this sheet.
    public var origId: ServiceID?
    public var name: String
    public var cwd: String
    /// The single-line command (argv in shell syntax), or the script when `viaShell`.
    public var commandText: String
    public var viaShell: Bool
    public var shell: String
    public var shellFlag: String
    public var env: [EnvRow]
    /// Empty = default (10 s).
    public var readyKind: String = "none"
    public var readyContainsText: String = ""
    public var readyPortText: String = ""
    public var readyTimeoutText: String = ""
    public var stopTimeoutText: String

    public init(
        id: UUID = UUID(), serviceId: String, idAuto: Bool, origId: ServiceID? = nil, name: String = "",
        cwd: String = ".", commandText: String = "", viaShell: Bool = false,
        shell: String = ShellWords.defaultShell, shellFlag: String = ShellWords.defaultShellFlag,
        env: [EnvRow] = [], stopTimeoutText: String = ""
    ) {
        self.id = id
        self.serviceId = serviceId
        self.idAuto = idAuto
        self.origId = origId
        self.name = name
        self.cwd = cwd
        self.commandText = commandText
        self.viaShell = viaShell
        self.shell = shell
        self.shellFlag = shellFlag
        self.env = env
        self.stopTimeoutText = stopTimeoutText
    }

    public static let defaultStopTimeout = 10

    /// A new, empty service whose ID does not clash with `taken`.
    public static func empty(taken: some Collection<String>) -> ServiceDraft {
        ServiceDraft(serviceId: Slug.make("service", taken: taken), idAuto: true)
    }

    /// Renames the service; an automatic ID follows the name.
    public mutating func rename(_ newName: String, taken: some Collection<String>) {
        name = newName
        if idAuto {
            serviceId = Slug.make(newName.isEmpty ? "service" : newName, taken: taken)
        }
    }

    /// The user typed an ID: it no longer follows the name.
    public mutating func setServiceId(_ id: String) {
        serviceId = id
        idAuto = false
    }

    /// The argv this card saves, or why it cannot.
    public var command: CommandParse {
        if viaShell {
            if commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .empty }
            return .argv([shell, shellFlag, commandText])
        }
        let r = ShellWords.split(commandText)
        if let error = r.error { return .invalid(error.description) }
        return r.argv.isEmpty ? .empty : .argv(r.argv)
    }

    /// `&`, `nohup`, `docker … -d` in the typed text (shown as a yellow warning).
    public var backgroundHint: String? {
        commandText.isEmpty ? nil : ShellWords.backgroundHint(commandText)
    }
}

public enum CommandParse: Equatable, Sendable {
    case argv([String])
    case empty
    case invalid(String)

    public var argv: [String]? {
        if case .argv(let a) = self { return a }
        return nil
    }
}

/// The whole form.
public struct ProjectDraft: Hashable, Sendable {
    public var schemaVersion: Int
    public var name: String
    public var root: String
    public var instanceGroup: String = ""
    public var instanceName: String = ""
    /// Project-level env (all services; a service's own variable wins).
    public var env: [EnvRow]
    public var services: [ServiceDraft]
    public var actions: [ActionDraft] = []
    public var maven: MavenConfig?
    public var repositories: [RepositoryConfig]?
    public var mavenProjects: [MavenProjectConfig]?
    /// Carried over unchanged (edited in the options panel, F4); response-only fields dropped.
    public var params: [ParamConfig]?

    public init(
        schemaVersion: Int = 1, name: String = "", root: String = "", env: [EnvRow] = [],
        services: [ServiceDraft], params: [ParamConfig]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.name = name
        self.root = root
        self.env = env
        self.services = services
        self.params = params
    }

    /// A new project with one empty service.
    public static func empty() -> ProjectDraft {
        ProjectDraft(services: [.empty(taken: [])])
    }

    /// Loads a saved (masked) config. Every service is linked to its saved ID.
    public init(config: ProjectConfig) {
        schemaVersion = config.schemaVersion
        name = config.name
        root = config.root
        instanceGroup = config.instance?.group ?? ""
        instanceName = config.instance?.name ?? ""
        env = Self.rows(config.env)
        services = config.services.map { s in
            let form = ShellWords.shellForm(s.command)
            var draft = ServiceDraft(
                serviceId: s.id, idAuto: false, origId: s.id, name: s.name, cwd: s.cwd,
                commandText: form?.script ?? ShellWords.join(s.command), viaShell: form != nil,
                shell: form?.shell ?? ShellWords.defaultShell, shellFlag: form?.flag ?? ShellWords.defaultShellFlag,
                env: Self.rows(s.env), stopTimeoutText: s.stopTimeoutSec.map(String.init) ?? "")
            if let ready = s.ready {
                draft.readyKind = ready.check.kind.rawValue
                draft.readyContainsText = ready.check.contains?.joined(separator: "\n") ?? ""
                draft.readyPortText = ready.check.port?.description ?? ""
                draft.readyTimeoutText = ready.timeoutSec.map { String(format: "%g", $0) } ?? ""
            }
            return draft
        }
        params = config.params?.map(\.forRequest)
        actions = (config.actions ?? []).map(ActionDraft.init(config:))
        maven = config.maven
        repositories = config.repositories
        mavenProjects = config.mavenProjects
    }

    static func rows(_ env: EnvMap?) -> [EnvRow] {
        (env ?? [:]).sorted { $0.key < $1.key }.map { name, value in
            switch value {
            case .plain(let s):
                EnvRow(name: name, value: s, secret: false, secretTouched: true)
            case .secret(let v):
                // A response never carries the value; a value here would only come from a request.
                EnvRow(name: name, value: v ?? "", secret: true, storedName: v == nil ? name : nil, secretTouched: true)
            }
        }
    }

    public var serviceIds: [String] { services.map(\.serviceId) }

    /// IDs used by the other cards (for slug de-duplication).
    public func takenIds(except rowId: UUID) -> [String] {
        services.filter { $0.id != rowId }.map(\.serviceId)
    }

    // MARK: Build

    public enum BuildMode: Sendable {
        /// The request body: typed secret values are sent, missing ones are local errors.
        case save
        /// For `/config/validate` and change detection: secrets always as the "keep" marker.
        case validate
    }

    public struct BuildResult: Sendable {
        public var config: ProjectConfig
        /// Problems found before asking the daemon, keyed by issue-style path
        /// (`name`, `root`, `services[1].command`, `services[0].env.API_KEY`, …).
        public var errors: [String: String]
    }

    public func build(_ mode: BuildMode = .save) -> BuildResult {
        var errors: [String: String] = [:]
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRoot = root.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty { errors["name"] = "项目名称不能为空" }
        if trimmedRoot.isEmpty {
            errors["root"] = "根目录不能为空"
        } else if !trimmedRoot.hasPrefix("/") {
            errors["root"] = "根目录必须是绝对路径"
        }
        var config = ProjectConfig(
            schemaVersion: schemaVersion, name: trimmedName, root: trimmedRoot,
            env: Self.buildEnv(env, at: "env", sameScope: true, mode: mode, errors: &errors),
            services: [], params: params)
        let group = instanceGroup
        let instance = instanceName
        if !group.isEmpty || !instance.isEmpty {
            if !ProjectInstance.isValidLabel(group) { errors["instance.group"] = "实例组须为 1–80 字符的单行文本；与实例名称一起填写" }
            if !ProjectInstance.isValidLabel(instance) { errors["instance.name"] = "实例名称须为 1–80 字符的单行文本；与实例组一起填写" }
            config.instance = ProjectInstance(group: group, name: instance)
        }
        if services.isEmpty { errors["services"] = "至少需要一个服务" }
        var seen = Set<String>()
        for (i, s) in services.enumerated() {
            let at = "services[\(i)]"
            let id = s.serviceId.trimmingCharacters(in: .whitespaces)
            let serviceName = s.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if serviceName.isEmpty { errors["\(at).name"] = "服务名称不能为空" }
            if !Slug.isValidServiceID(id) {
                errors["\(at).id"] = "ID 须为小写字母开头，只含小写字母、数字和连字符，最长 32 位"
            } else if seen.contains(id) {
                errors["\(at).id"] = "服务 ID 重复：\(id)"
            }
            seen.insert(id)
            var argv: [String] = []
            switch s.command {
            case .argv(let a): argv = a
            case .empty: errors["\(at).command"] = "启动命令不能为空"
            case .invalid(let why): errors["\(at).command"] = why
            }
            let cwd = s.cwd.trimmingCharacters(in: .whitespaces)
            var service = ServiceConfig(id: id, name: serviceName, cwd: cwd.isEmpty ? "." : cwd, command: argv)
            // A stored secret can only be kept under the same service ID.
            service.env = Self.buildEnv(
                s.env, at: "\(at).env", sameScope: s.origId == nil || s.origId == id, mode: mode, errors: &errors)
            let t = s.stopTimeoutText.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty {
                if let n = Int(t), (1...300).contains(n) {
                    service.stopTimeoutSec = n
                } else {
                    errors["\(at).stopTimeoutSec"] = "停止等待须为 1–300 的整数秒"
                }
            }
            if s.readyKind != "none" {
                let timeout = s.readyTimeoutText.isEmpty ? nil : Double(s.readyTimeoutText)
                if !s.readyTimeoutText.isEmpty && (timeout == nil || timeout! < 1 || timeout! > 900) { errors["\(at).ready.timeoutSec"] = "等待上限须为 1–900 秒" }
                var check = ReadyCheck(kind: ReadyCheckKind(raw: s.readyKind))
                if s.readyKind == "log" {
                    let contains = s.readyContainsText.components(separatedBy: .newlines).filter { !$0.isEmpty }
                    if contains.isEmpty || contains.count > 5 || contains.contains(where: { $0.count > 200 }) { errors["\(at).ready.check.contains"] = "填写 1–5 行，每行最多 200 字符" }
                    check.contains = contains
                } else if !s.readyPortText.isEmpty {
                    if let port = Int(s.readyPortText), (1...65535).contains(port) { check.port = .number(Double(port)) }
                    else if s.readyPortText.range(of: #"^\$\{[a-zA-Z][a-zA-Z0-9_]{0,31}\}$"#, options: .regularExpression) != nil { check.port = .string(s.readyPortText) }
                    else { errors["\(at).ready.check.port"] = "填写 1–65535 或 ${选项名}，留空表示任意端口" }
                }
                service.ready = ReadyConfig(check: check, timeoutSec: timeout)
            }
            config.services.append(service)
        }
        config.maven = maven
        config.repositories = repositories
        config.mavenProjects = mavenProjects
        if !actions.isEmpty {
            var actionIDs = Set<String>()
            config.actions = actions.enumerated().map { i, draft in
                let one = ProjectDraft(name: name, root: root, services: [draft.service]).build(mode)
                for (key, value) in one.errors where key.hasPrefix("services[0]") {
                    errors[key.replacingOccurrences(of: "services[0]", with: "actions[\(i)]")] = value
                }
                let service = one.config.services[0]
                if !actionIDs.insert(service.id).inserted { errors["actions[\(i)].id"] = "快捷操作 ID 重复" }
                var action = ActionConfig(id: service.id, name: service.name, description: draft.description.isEmpty ? nil : draft.description, cwd: service.cwd, command: service.command, env: service.env, stopTimeoutSec: service.stopTimeoutSec, confirmWhenServicesRunning: draft.confirmWhenServicesRunning ? true : nil)
                let timeout = draft.timeoutText.trimmingCharacters(in: .whitespaces)
                if !timeout.isEmpty {
                    if let value = Int(timeout), (1...86400).contains(value) { action.timeoutSec = value }
                    else { errors["actions[\(i)].timeoutSec"] = "最长运行时间须为 1–86400 的整数秒" }
                }
                return action
            }
        }
        return BuildResult(config: config, errors: errors)
    }

    static func buildEnv(
        _ rows: [EnvRow], at: String, sameScope: Bool, mode: BuildMode, errors: inout [String: String]
    ) -> EnvMap? {
        var out: EnvMap = [:]
        var any = false
        for r in rows where !r.isBlank {
            let name = r.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else {
                errors[at] = "环境变量名不能为空"
                continue
            }
            if out[name] != nil { errors["\(at).\(name)"] = "重复的环境变量：\(name)" }
            any = true
            if !r.secret {
                out[name] = .plain(r.value)
                continue
            }
            let keeps = sameScope && r.storedName == name
            if !r.value.isEmpty {
                out[name] = .secret(value: mode == .save ? r.value : nil)
            } else {
                out[name] = .secret(value: nil)
                if !keeps, mode == .save { errors["\(at).\(name)"] = "请填写 \(name) 的值" }
            }
        }
        return any ? out : nil
    }

    /// Typed secret values (they make the draft dirty without changing the masked config).
    public var hasTypedSecrets: Bool {
        (env + services.flatMap(\.env) + actions.flatMap { $0.service.env }).contains { $0.secret && !$0.value.isEmpty }
    }
}
