import Foundation

/// Contract §3.1. UI validation and previews; the daemon remains authoritative.
public enum OptionRules {
    public static func validKey(_ key: String) -> Bool {
        key.range(of: #"^[a-zA-Z][a-zA-Z0-9_]{0,31}\z"#, options: .regularExpression) != nil
    }

    public static func value(_ text: String, for param: ParamConfig, creating: Bool = false) throws -> ParamValue? {
        if param.isSecret && text.isEmpty && !creating { return nil }
        switch param.type {
        case .string: return .string(text)
        case .enum:
            guard param.choices?.contains(where: { $0.value == text }) == true else { throw invalid("请选择一个可选值") }
            return .string(text)
        case .number:
            guard let n = Double(text), n.isFinite else { throw invalid("请输入有效数字") }
            if let min = param.min, n < min { throw invalid("不能小于 \(ParamValue.number(min))") }
            if let max = param.max, n > max { throw invalid("不能大于 \(ParamValue.number(max))") }
            return .number(n)
        case .boolean:
            guard text == "true" || text == "false" else { throw invalid("请输入 true 或 false") }
            return .bool(text == "true")
        case .other: throw invalid("此版本暂不支持该选项类型")
        }
    }

    static func invalid(_ message: String) -> ApiError { ApiError(code: .paramInvalid, message: message) }

    public static func attribution(_ p: ParamConfig) -> String {
        let date = Timestamps.date(p.valueUpdatedAt)
        let f = DateFormatter()
        f.dateFormat = p.setBy == .user ? "HH:mm" : "MM/dd"
        let suffix = date.map { f.string(from: $0) }
        if p.setBy == .user { return "你修改于 " + (suffix ?? "未知时间") }
        if p.describedBy == .user { return "说明由你编辑" }
        if p.describedBy == .agent || p.setBy == .agent { return "✦ AI 编写" + (suffix.map { " · " + $0 } ?? "") }
        return "设置者未知"
    }

    public static func errorText(_ e: ApiError) -> String {
        switch e.code {
        case .revisionMismatch: "配置已被其他客户端修改。已保留你的输入，刷新后可重试。"
        case .paramUnknown: "此选项已被其他客户端删除，已刷新项目。"
        case .configInvalid: e.issues?.filter { $0.severity == .error }.map(\.message).joined(separator: "\n") ?? e.message
        case .paramInUse where e.details?["reason"]?.stringValue == "secret": "敏感选项被命令引用，不能将秘密写回命令。请先编辑项目，移除命令中的引用。"
        default: e.message
        }
    }

    public static func blocksInline(_ p: ParamConfig) -> Bool {
        p.isSecret && (p.usedBy ?? []).contains { $0.where == .command }
    }

    public struct ReferencePreview: Identifiable, Equatable, Sendable {
        public var id: Int
        public var location: String
        public var original: String
        public var segments: [CommandPreview.Segment]
        public var text: String { segments.map(\.text).joined() }
    }

    /// Inlining only this key leaves other placeholders and existing escapes intact.
    /// Secret env inline expands the complete value, then hides it as a sensitive env value.
    public static func references(_ p: ParamConfig, config: ProjectConfig, inline: Bool) -> [ReferencePreview] {
        (p.usedBy ?? []).enumerated().compactMap { n, ref in
            let action = config.actions?.first { "action:\($0.id)" == ref.serviceId }
            let service = config.services.first { $0.id == ref.serviceId } ?? action.map {
                ServiceConfig(id: "action:\($0.id)", name: $0.name, cwd: $0.cwd, command: $0.command, env: $0.env, stopTimeoutSec: $0.stopTimeoutSec)
            }
            let name = ref.isProjectLevel ? "项目" : (service?.name ?? ref.serviceId)
            var raw: String
            var quote = false
            let location: String
            switch ref.where {
            case .command:
                guard let s = service, let i = ref.index, s.command.indices.contains(i) else { return nil }
                raw = s.command[i]
                quote = CommandPreview.scriptIndex(s.command) == i
                location = "\(name) 命令"
            case .env:
                guard let key = ref.envKey, let value = (ref.isProjectLevel ? config.env : service?.env)?[key]?.plainValue else { return nil }
                raw = value
                location = "\(name) 环境变量 \(key)"
            case .ready:
                guard let ready = service?.ready, ready.check.kind == .port, let port = ready.check.port else { return nil }
                raw = port.description
                location = "\(name) 就绪端口"
            case .other: return nil
            }
            let all = Dictionary((config.params ?? []).map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
            var segments = CommandPreview.segments(raw, params: all, quote: quote)
            if inline && p.isSecret && ref.where == .env {
                segments = [.init(text: "••••（写回为敏感环境变量）", kind: .secret(key: p.key))]
            } else if inline {
                segments = segments.map { segment in
                    var s = segment
                    switch s.kind {
                    case .value(let key), .secret(let key):
                        if key != p.key { s = .init(text: "${\(key)}", kind: .text) }
                        else { s.text = s.text.replacingOccurrences(of: "${", with: "$${") }
                    case .escaped: s.text = "$${"
                    default: break
                    }
                    return s
                }
            }
            return ReferencePreview(id: n, location: location, original: raw, segments: segments)
        }
    }
}
