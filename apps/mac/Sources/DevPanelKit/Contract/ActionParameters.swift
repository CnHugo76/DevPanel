import Foundation

public enum ActionParamType: OpenEnum {
    case string, number, boolean, `enum`, multiselect, other(String)
    public static let known: [Self] = [.string, .number, .boolean, .enum, .multiselect]
    public var rawValue: String {
        switch self { case .string: "string"; case .number: "number"; case .boolean: "boolean"; case .enum: "enum"; case .multiselect: "multiselect"; case .other(let value): value }
    }
    public var title: String {
        switch self { case .string: "文本"; case .number: "数字"; case .boolean: "布尔"; case .enum: "单选"; case .multiselect: "多选"; case .other: "未知类型" }
    }
}

/// Secret is a response/default marker only; never send it as a run override.
public enum ActionParamValue: Codable, Hashable, Sendable {
    case string(String), number(Double), bool(Bool), strings([String]), secret
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([String].self) { self = .strings(a) }
        else {
            let marker = try c.decode([String: Bool].self)
            guard marker == ["secret": true] else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid secret marker") }
            self = .secret
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .strings(let v): try c.encode(v)
        case .secret: try c.encode(["secret": true])
        }
    }
    public var display: String {
        switch self {
        case .string(let v): v.isEmpty ? "空文本" : v
        case .number(let v): ParamValue.number(v).description
        case .bool(let v): v ? "开启" : "关闭"
        case .strings(let v): v.isEmpty ? "未选择" : v.joined(separator: "、")
        case .secret: "••••"
        }
    }
}
public struct ActionParamConfig: Codable, Hashable, Sendable, Identifiable {
    public var key: String
    public var label: String
    public var description: String?
    public var type: ActionParamType
    public var required: Bool?
    public var defaultValue: ActionParamValue?
    public var choices: [ParamChoice]?
    public var min: Double?
    public var max: Double?
    public var secret: Bool?
    public var id: String { key }
    enum CodingKeys: String, CodingKey { case key, label, description, type, required, choices, min, max, secret; case defaultValue = "default" }
    public init(key: String, label: String, type: ActionParamType, description: String? = nil, required: Bool? = nil, defaultValue: ActionParamValue? = nil, choices: [ParamChoice]? = nil, min: Double? = nil, max: Double? = nil, secret: Bool? = nil) {
        self.key = key; self.label = label; self.type = type; self.description = description; self.required = required; self.defaultValue = defaultValue; self.choices = choices; self.min = min; self.max = max; self.secret = secret
    }
}
public struct ActionRunRequest: Codable, Hashable, Sendable {
    public var params: [String: ActionParamValue]?
    public var ifRevision: Int?
    public init(params: [String: ActionParamValue]? = nil, ifRevision: Int? = nil) { self.params = params; self.ifRevision = ifRevision }
}
public struct ActionParamSnapshot: Codable, Hashable, Sendable, Identifiable {
    public var key: String
    public var label: String
    public var description: String?
    public var type: ActionParamType
    public var value: ActionParamValue?
    public var choices: [ParamChoice]?
    public var id: String { key }
    public var display: String {
        let labels = Dictionary((choices ?? []).map { ($0.value, $0.label ?? $0.value) }, uniquingKeysWith: { a, _ in a })
        switch value {
        case .strings(let values): return values.isEmpty ? "未选择" : values.map { labels[$0] ?? $0 }.joined(separator: "、")
        case .string(let value) where type == .enum: return labels[value] ?? value
        default: return value?.display ?? "未提供"
        }
    }
}
