import Foundation

/// One transient input. Defaults initialise each new form; this state is never persisted.
public struct ActionParameterInput: Hashable, Sendable {
    public var enabled: Bool
    public var useStoredDefault: Bool
    public var text = ""
    public var boolean = false
    public var selections: Set<String> = []
    public init(_ definition: ActionParamConfig) {
        enabled = definition.defaultValue != nil || definition.required == true
        useStoredDefault = definition.defaultValue == .secret
        switch definition.defaultValue {
        case .string(let value): text = value
        case .number(let value): text = ParamValue.number(value).description
        case .bool(let value): boolean = value
        case .strings(let values): selections = Set(values)
        default: break
        }
    }
    public func value(for definition: ActionParamConfig) throws -> ActionParamValue? {
        if !enabled || useStoredDefault { return nil }
        let value: ActionParamValue
        switch definition.type {
        case .string, .enum: value = .string(text)
        case .number:
            guard let n = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), n.isFinite else { throw ActionParameterError("请输入有效数字") }
            value = .number(n)
        case .boolean: value = .bool(boolean)
        case .multiselect:
            guard selections.isSubset(of: Set((definition.choices ?? []).map(\.value))) else { throw ActionParameterError("候选项已变更，请重新选择") }
            value = .strings((definition.choices ?? []).filter { selections.contains($0.value) }.map(\.value))
        case .other: throw ActionParameterError("此版本不支持该参数类型")
        }
        if let message = ActionParameterRules.issue(value, definition: definition) { throw ActionParameterError(message) }
        return value
    }
}
public struct ActionParameterError: Error, LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
public enum ActionParameterRules {
    public static func issue(_ value: ActionParamValue?, definition p: ActionParamConfig) -> String? {
        guard let value else { return p.required == true ? "请填写此参数" : nil }
        switch (p.type, value) {
        case (.string, .string(let v)): return v.contains("\0") ? "文本不能包含 NUL" : p.required == true && v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "请填写此参数" : nil
        case (.enum, .string(let v)): return p.choices?.contains { $0.value == v } == true ? nil : "请选择一个候选项"
        case (.number, .number(let v)): return !v.isFinite || p.min.map { v < $0 } == true || p.max.map { v > $0 } == true ? "数值超出允许范围" : nil
        case (.boolean, .bool): return nil
        case (.multiselect, .strings(let values)):
            if p.required == true && values.isEmpty { return "请至少选择一项" }
            return Set(values).count != values.count || values.contains { v in p.choices?.contains { $0.value == v } != true } ? "请选择有效且不重复的候选项" : nil
        default: return "值与参数类型不符"
        }
    }
}

public struct ActionChoiceDraft: Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var value: String
    public var label: String
    public var description: String
    public init(_ c: ParamChoice = ParamChoice(value: "")) { value = c.value; label = c.label ?? ""; description = c.description ?? "" }
}
public struct ActionParameterDraft: Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var key: String
    public var label: String
    public var description: String
    public var type: ActionParamType
    public var required: Bool
    public var secret: Bool
    public var hasDefault: Bool
    public var input: ActionParameterInput
    public var choices: [ActionChoiceDraft]
    public var minText: String
    public var maxText: String
    public init(_ p: ActionParamConfig = ActionParamConfig(key: "", label: "", type: .string)) {
        key = p.key; label = p.label; description = p.description ?? ""; type = p.type; required = p.required == true; secret = p.secret == true; hasDefault = p.defaultValue != nil
        input = ActionParameterInput(p); input.enabled = true
        choices = (p.choices ?? []).map(ActionChoiceDraft.init)
        minText = p.min.map { ParamValue.number($0).description } ?? ""; maxText = p.max.map { ParamValue.number($0).description } ?? ""
    }
    public var definition: ActionParamConfig {
        ActionParamConfig(key: key, label: label, type: type, description: description.isEmpty ? nil : description, required: required ? true : nil,
                          choices: type == .enum || type == .multiselect ? choices.map { ParamChoice(value: $0.value, label: $0.label.isEmpty ? nil : $0.label, description: $0.description.isEmpty ? nil : $0.description) } : nil,
                          min: type == .number ? Double(minText) : nil, max: type == .number ? Double(maxText) : nil, secret: secret ? true : nil)
    }
    public func build() throws -> ActionParamConfig {
        var p = definition
        if type == .number {
            if (!minText.isEmpty && p.min?.isFinite != true) || (!maxText.isEmpty && p.max?.isFinite != true) { throw ActionParameterError("范围须为有效数字") }
            if let min = p.min, let max = p.max, min > max { throw ActionParameterError("最小值不得大于最大值") }
        }
        if hasDefault {
            if secret && input.useStoredDefault { p.defaultValue = .secret }
            else { var value = input; value.useStoredDefault = false; p.defaultValue = try value.value(for: p) }
        }
        return p
    }
}
