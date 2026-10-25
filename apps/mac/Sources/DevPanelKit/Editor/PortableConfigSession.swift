import Foundation
import Observation

@Observable @MainActor
public final class PortableConfigSession {
    public enum Mode: Sendable { case importFile, export(ProjectID) }
    public struct Environment: Sendable {
        public var projects: @Sendable () async throws -> [ProjectView]
        public var project: @Sendable (ProjectID) async throws -> Project
        public var validate: @Sendable (ProjectConfig) async throws -> ValidateResult
        public var register: @Sendable (ProjectConfig) async throws -> RegisterResponse
        public var update: @Sendable (ProjectID, Int, ProjectConfig) async throws -> UpdateResponse
        public init(projects: @escaping @Sendable () async throws -> [ProjectView], project: @escaping @Sendable (ProjectID) async throws -> Project,
                    validate: @escaping @Sendable (ProjectConfig) async throws -> ValidateResult,
                    register: @escaping @Sendable (ProjectConfig) async throws -> RegisterResponse,
                    update: @escaping @Sendable (ProjectID, Int, ProjectConfig) async throws -> UpdateResponse) {
            self.projects = projects; self.project = project; self.validate = validate; self.register = register; self.update = update
        }
    }
    public struct Preview: Sendable {
        fileprivate var config: ProjectConfig
        public var existingId: ProjectID?
        public var revision: Int?
        public var changedPaths: [String]
        public var protectedParamKeys: [String]
        public var validation: ValidateResult
        public var name: String { config.name }
        public var serviceNames: [String] { config.services.map(\.name) }
        public var actionCount: Int { config.actions?.count ?? 0 }
    }

    public let mode: Mode
    public private(set) var document: PortableProjectConfig?
    public private(set) var documentURL: URL?
    public private(set) var inputsURL: URL?
    public private(set) var root: String?
    public private(set) var suppliedIds = Set<String>()
    public private(set) var preview: Preview?
    public private(set) var busy = false
    public private(set) var notice: String?
    public private(set) var savedMessage: String?
    @ObservationIgnored private let environment: Environment
    @ObservationIgnored private var values: [String: JSONValue] = [:]
    @ObservationIgnored private var generation = 0

    public init(mode: Mode, environment: Environment) { self.mode = mode; self.environment = environment }
    public var missing: [PortableConfigInput] { document.map { PortableConfiguration.missing($0, values: values) } ?? [] }
    public var canSave: Bool { !busy && preview?.validation.ok == true }
    public var exportText: String { document.flatMap { try? PortableConfiguration.encode($0) }.map { String(decoding: $0, as: UTF8.self) } ?? "" }

    public func loadExport() async {
        guard case .export(let id) = mode, !busy else { return }
        invalidate()
        let token = generation
        busy = true
        defer { if generation == token { busy = false } }
        do {
            let project = try await environment.project(id)
            guard token == generation, !Task.isCancelled else { return }
            document = try PortableConfiguration.export(project.config)
        } catch {
            guard token == generation, !Task.isCancelled else { return }
            notice = safeMessage(error)
        }
    }

    public func loadDocument(_ url: URL) {
        invalidate()
        document = nil
        documentURL = nil
        values = [:]; suppliedIds = []; inputsURL = nil
        do {
            document = try PortableConfiguration.decode(PortableConfiguration.read(url, limit: PortableConfiguration.documentByteLimit))
            documentURL = url
        } catch { notice = safeMessage(error) }
    }

    public func loadInputs(_ url: URL) {
        invalidate()
        values = [:]; suppliedIds = []; inputsURL = nil
        do {
            values = try PortableConfiguration.decodeInputs(PortableConfiguration.read(url, limit: PortableConfiguration.inputsByteLimit))
            suppliedIds = Set(values.keys)
            inputsURL = url
        } catch { notice = safeMessage(error) }
    }

    public func setRoot(_ url: URL) {
        invalidate()
        root = PortableConfiguration.canonicalRoot(url.path)
    }

    public func prepare() async {
        guard !busy, let document, let root else { return }
        invalidate()
        let token = generation
        busy = true
        defer { if generation == token { busy = false } }
        do {
            let config = try PortableConfiguration.materialize(document, root: root, values: values)
            let projects = try await environment.projects()
            let found = projects.first { PortableConfiguration.canonicalRoot($0.root) == config.root }
            let existing: Project?
            if let found { existing = try await environment.project(found.id) } else { existing = nil }
            let validation = try await environment.validate(config)
            guard token == generation, !Task.isCancelled else { return }
            preview = Preview(config: config, existingId: existing?.id, revision: existing?.revision,
                              changedPaths: existing.map { Self.changedPaths($0.config, config) } ?? [],
                              protectedParamKeys: existing?.config.params?.filter { old in
                                  old.setBy == .user && config.params?.contains(where: { $0.key == old.key }) == true
                              }.map(\.key) ?? [],
                              validation: validation)
        } catch {
            guard token == generation, !Task.isCancelled else { return }
            notice = safeMessage(error)
        }
    }

    /// Saves exactly the prepared configuration and revision. Never refreshes or retries a conflict.
    public func save() async -> Project? {
        guard canSave, let prepared = preview else { return nil }
        let token = generation
        busy = true
        notice = nil
        defer { if generation == token { busy = false } }
        do {
            let project: Project
            let message: String
            if let id = prepared.existingId, let revision = prepared.revision {
                let result = try await environment.update(id, revision, prepared.config)
                project = result.project
                let kept = result.keptUserValues ?? []
                message = "配置已导入 · 下次启动生效，未执行命令" + (kept.isEmpty ? "" : "；保留用户选项：" + kept.joined(separator: "、"))
            } else {
                let result = try await environment.register(prepared.config)
                project = result.project
                message = result.created ? "项目已导入 · 未启动" : "相同配置已登记 · 未启动"
            }
            guard token == generation else { return nil }
            savedMessage = message
            preview = nil
            values = [:]; suppliedIds = []; inputsURL = nil
            return project
        } catch {
            guard token == generation else { return nil }
            preview = nil
            if (error as? ApiError)?.code == .revisionMismatch {
                notice = "配置在预览后发生变化。请重新预览，再确认保存；未自动重试。"
            } else { notice = safeMessage(error) }
            return nil
        }
    }

    public func saveExport(to url: URL) throws {
        guard let document else { throw ApiError(code: .badRequest, message: "尚无可导出的配置。") }
        // Also prevents a file created after the native save panel from being overwritten.
        try PortableConfiguration.encode(document).write(to: url, options: [.withoutOverwriting])
    }

    public func cancel() { invalidate(); values = [:]; suppliedIds = [] }

    private func invalidate() {
        generation += 1
        preview = nil
        busy = false
        notice = nil
        savedMessage = nil
    }

    private func safeMessage(_ error: any Error) -> String {
        // Provider validation errors can mention submitted scalar values. Never echo inputs.
        if let local = error as? PortableConfigError { return local.message }
        if let api = error as? ApiError {
            return "操作未完成（\(api.code.rawValue)）；请检查配置字段和本机输入后重新预览。"
        }
        return "文件无法读取或写入。请检查文件格式、大小、权限，以及目标文件是否已存在。"
    }

    private static func changedPaths(_ old: ProjectConfig, _ next: ProjectConfig) -> [String] {
        func object(_ config: ProjectConfig) -> JSONValue? {
            var clean = config
            clean.root = PortableConfiguration.canonicalRoot(config.root)
            clean.params = clean.params?.map(\.forRequest)
            guard let data = try? JSONEncoder().encode(clean) else { return nil }
            return try? JSONDecoder().decode(JSONValue.self, from: data)
        }
        guard let lhs = object(old), let rhs = object(next) else { return [] }
        var paths: [String] = []
        func compare(_ a: JSONValue?, _ b: JSONValue?, _ path: String) {
            guard a != b, paths.count < 100 else { return }
            if case .object(let left) = a, case .object(let right) = b {
                for key in Set(left.keys).union(right.keys).sorted() { compare(left[key], right[key], path + "/" + key) }
            } else if case .array(let left) = a, case .array(let right) = b, left.count == right.count {
                for i in left.indices { compare(left[i], right[i], path + "/\(i)") }
            } else { paths.append(path) }
        }
        compare(lhs, rhs, "")
        return paths
    }
}
