import Foundation

// MARK: - Validation results mapped onto the form

/// A `/config/validate` (or CONFIG_INVALID) result, remembered with the order of the service
/// cards it was computed for: issue paths say `services[i]`, and cards may have moved since.
public struct EditorValidation: Equatable, Sendable {
    public var result: ValidateResult
    /// Card IDs in the order they were sent.
    public var sentRows: [UUID]
    /// Service IDs in the order they were sent.
    public var sentServiceIds: [String]

    public init(result: ValidateResult, sentRows: [UUID], sentServiceIds: [String]) {
        self.result = result
        self.sentRows = sentRows
        self.sentServiceIds = sentServiceIds
    }

    public var issues: [ValidationIssue] { result.issues }

    /// `services[i]` of a card in the validated request, nil if the card was added since.
    public func prefix(for row: UUID) -> String? {
        sentRows.firstIndex(of: row).map { "services[\($0)]" }
    }

    /// Issues at `path` or below it (`path.x`, `path[3]`).
    public func issues(under path: String) -> [ValidationIssue] {
        issues.filter { $0.path == path || $0.path.hasPrefix(path + ".") || $0.path.hasPrefix(path + "[") }
    }

    /// Issues of one field of a card (`name`, `id`, `cwd`, `command`, `env`, `stopTimeoutSec`).
    public func issues(row: UUID, field: String) -> [ValidationIssue] {
        guard let p = prefix(for: row) else { return [] }
        return issues(under: "\(p).\(field)")
    }

    public func resolution(for row: UUID) -> ServiceResolution? {
        guard let i = sentRows.firstIndex(of: row) else { return nil }
        let id = sentServiceIds[i]
        return result.services.first { $0.serviceId == id }
    }

    static let serviceFields = ["id", "name", "cwd", "command", "env", "stopTimeoutSec"]

    /// Issues that no field of the form shows (e.g. `params[0]` warnings, `schemaVersion`).
    public var otherIssues: [ValidationIssue] {
        issues.filter { issue in
            let p = issue.path
            if p == "name" || p == "root" || p == "env" || p.hasPrefix("env.") || p.hasPrefix("env[") { return false }
            for i in sentRows.indices {
                for f in Self.serviceFields {
                    let base = "services[\(i)].\(f)"
                    if p == base || p.hasPrefix(base + ".") || p.hasPrefix(base + "[") { return false }
                }
            }
            return true
        }
    }
}

/// What the resolution line under a service card says.
public enum ResolutionLine: Equatable, Sendable {
    /// `将执行 /opt/homebrew/bin/mvn · 目录存在`
    case ok(program: String)
    /// `工作目录不存在：/abs/dir`
    case cwdMissing(String)
    /// `在 PATH 中找不到 mvn（当前 PATH：…）` / `找不到文件 ./mvnw`
    case notFound(program: String, path: String)
    /// Standalone validation could not resolve it (PATH depends on a secret / option).
    case unresolved(program: String)

    public init(_ r: ServiceResolution) {
        if !r.cwdExists {
            self = .cwdMissing(r.cwdAbs)
        } else if let resolved = r.programResolved {
            self = .ok(program: resolved)
        } else if r.pathUsed.isEmpty {
            self = .unresolved(program: r.program)
        } else {
            self = .notFound(program: r.program, path: r.pathUsed)
        }
    }

    public var text: String {
        switch self {
        case .ok(let p): "将执行 \(p) · 目录存在"
        case .cwdMissing(let d): "工作目录不存在：\(d)"
        case .notFound(let program, let path):
            program.contains("/")
                ? "找不到文件 \(program)"
                : "在 PATH 中找不到 \(program)（当前 PATH：\(path)）"
        case .unresolved(let p): "暂时无法解析 \(p)：PATH 依赖敏感值，保存时再完整校验"
        }
    }

    public var isProblem: Bool {
        switch self {
        case .ok, .unresolved: false
        case .cwdMissing, .notFound: true
        }
    }
}

// MARK: - Save results and errors

public enum EditorSaveOutcome: Equatable, Sendable {
    /// `POST /projects` → 201.
    case created(Project)
    /// `POST /projects` → 200 `created:false`: the same config is already registered.
    case alreadyRegistered(Project)
    /// `PUT /projects/:id`; `keptUserValues` lists option keys whose user-set value was kept.
    case updated(Project, keptUserValues: [String])

    public var project: Project {
        switch self {
        case .created(let p), .alreadyRegistered(let p), .updated(let p, _): p
        }
    }
}

/// The banner at the top of the sheet.
public enum EditorNotice: Equatable, Sendable {
    /// Local checks failed; fields are marked.
    case fixFields
    /// `REVISION_MISMATCH`: someone else (maybe an agent) saved first.
    case revisionMismatch(currentRevision: Int?)
    /// `CONFIG_CONFLICT`: the root is already registered with a different config.
    case conflict(projectId: ProjectID?, diff: [ConfigDiffEntry], message: String)
    /// `CONFIG_INVALID`: the daemon's checks failed (issues are shown on the fields).
    case invalid(message: String, issueCount: Int)
    /// `PROJECT_RUNNING`: a removed service is still running.
    case projectRunning(message: String, serviceId: ServiceID?)
    /// Anything else, as the daemon said it.
    case failed(code: String, message: String)
    /// The config could not be read.
    case loadFailed(message: String)

    public static func from(_ error: ApiError) -> EditorNotice {
        switch error.code {
        case .revisionMismatch:
            return .revisionMismatch(currentRevision: error.currentRevision)
        case .configConflict:
            return .conflict(
                projectId: error.details?["projectId"]?.stringValue, diff: error.configDiff ?? [],
                message: error.message)
        case .configInvalid:
            let n = error.issues?.filter { $0.severity == .error }.count ?? 0
            return .invalid(message: error.message, issueCount: n)
        case .projectRunning:
            return .projectRunning(message: error.message, serviceId: error.details?["serviceId"]?.stringValue)
        default:
            return .failed(code: error.code.rawValue, message: error.message)
        }
    }

    public var title: String {
        switch self {
        case .fixFields: "请先修正标出的问题"
        case .revisionMismatch: "配置已被其他客户端（可能是 AI）修改"
        case .conflict: "该根目录已注册为另一个项目，且配置不同"
        case .invalid: "管理服务校验未通过，未保存"
        case .projectRunning: "有服务正在运行，不能删除"
        case .failed: "保存失败"
        case .loadFailed: "读取配置失败"
        }
    }

    public var detail: String {
        switch self {
        case .fixFields: ""
        case .revisionMismatch(let r):
            (r.map { "当前版本 r\($0)。" } ?? "") + "你的修改尚未保存；载入最新配置会丢弃这些修改。"
        case .conflict: "不会覆盖已有配置；如需修改，请打开已有项目后编辑。"
        case .invalid(let message, let n): n > 0 ? "\(message)：\(n) 个问题已标在对应字段下。" : message
        case .projectRunning(let message, _): message
        case .failed(let code, let message): "\(message)（\(code)）"
        case .loadFailed(let message): message
        }
    }

    public var isWarning: Bool {
        switch self {
        case .revisionMismatch, .conflict: true
        default: false
        }
    }
}

extension ConfigDiffEntry {
    /// `services[0].command: ["a"] → ["b"]` (compact JSON, truncated).
    public var summary: String {
        "\(path)：\(Self.compact(existing)) → \(Self.compact(incoming))"
    }

    static func compact(_ v: JSONValue?) -> String {
        guard let v else { return "（无）" }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let s = (try? enc.encode(v)).map { String(decoding: $0, as: UTF8.self) } ?? "?"
        return s.count > 80 ? String(s.prefix(79)) + "…" : s
    }
}

// MARK: - Service and project guards

extension ServiceState {
    /// starting / running / stopping / unknown: the daemon refuses to delete it (PROJECT_RUNNING).
    public var blocksRemoval: Bool { isActive || self == .unknown }
}

/// Whether a project can be removed from DevPanel (ui-design §7).
public struct RemovalCheck: Equatable, Sendable {
    /// Services that must be stopped first.
    public var blocking: [ServiceView]
    public var blockingTasks: [TaskRunSummary]

    public init(_ project: ProjectView) {
        blocking = project.services.filter { $0.state.blocksRemoval }
        blockingTasks = project.actions.compactMap(\.currentRun) + [project.maven?.currentRun].compactMap { $0 }
    }

    public var allowed: Bool { blocking.isEmpty && blockingTasks.isEmpty }

    /// `只从 DevPanel 移除配置和日志，不会删除 <root> 下的任何文件。`
    public static func message(root: String) -> String {
        "只从 DevPanel 移除配置和日志，不会删除 \(root) 下的任何文件。"
    }

    /// Why the button is disabled, nil when allowed.
    public var blockedReason: String? {
        guard !allowed else { return nil }
        if !blockingTasks.isEmpty { return "任务 \(blockingTasks.map(\.label).joined(separator: "、")) 尚未结束。请先取消运行中的任务再移除。" }
        let names = blocking.map { "\($0.name)（\(Self.stateText($0.state))）" }.joined(separator: "、")
        return "\(names) 尚未停止。请先停止项目的所有服务再移除。"
    }

    static func stateText(_ s: ServiceState) -> String {
        switch s {
        case .starting: "启动中"
        case .running: "运行中"
        case .stopping: "停止中"
        case .unknown: "状态未知"
        default: s.rawValue
        }
    }
}
