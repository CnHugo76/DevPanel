import DevPanelKit
import SwiftUI

/// Native controls shared by the run form and definition defaults.
struct ActionParameterControl: View {
    let definition: ActionParamConfig
    @Binding var input: ActionParameterInput
    var focusRequest = 0
    @FocusState private var focused: Bool
    var body: some View {
        Group {
            switch definition.type {
            case .boolean:
                Toggle(input.boolean ? "开启" : "关闭", isOn: $input.boolean).toggleStyle(.switch).focused($focused)
            case .enum:
                Picker(definition.label, selection: $input.text) {
                    Text("请选择…").tag("")
                    ForEach(Array((definition.choices ?? []).enumerated()), id: \.offset) { _, choice in Text(choice.label ?? choice.value).tag(choice.value) }
                }.labelsHidden().focused($focused)
            case .multiselect:
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array((definition.choices ?? []).enumerated()), id: \.offset) { _, choice in
                        Toggle(isOn: Binding(get: { input.selections.contains(choice.value) }, set: { if $0 { input.selections.insert(choice.value) } else { input.selections.remove(choice.value) } })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(choice.label ?? choice.value)
                                if let description = choice.description { Text(description).font(.caption).foregroundStyle(Theme.text2) }
                            }
                        }.toggleStyle(.checkbox)
                    }
                }.focusable().focused($focused)
            case .string, .number:
                if definition.secret == true { SecureField(definition.type == .number ? "数字" : "本次值", text: $input.text).focused($focused) }
                else { TextField(definition.type == .number ? "数字" : "本次值", text: $input.text).focused($focused) }
            case .other:
                Text("此版本不支持该参数类型").foregroundStyle(Theme.red)
            }
        }
        .accessibilityLabel(definition.label)
        .accessibilityIdentifier("action-param-" + definition.key)
        .onChange(of: focusRequest) { _, value in if value > 0 { focused = true } }
    }
}
