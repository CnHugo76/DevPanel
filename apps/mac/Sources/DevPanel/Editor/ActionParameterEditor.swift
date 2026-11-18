import DevPanelKit
import SwiftUI

struct ActionParameterEditor: View {
    @Binding var action: ActionDraft
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("操作专属参数").fontWeight(.semibold)
                Spacer()
                Button("＋ 参数") { action.params.append(ActionParameterDraft()) }
            }
            Text("在执行前就地选择；命令参数或环境变量可引用 ${action.key}。多选以 JSON 数组传递。").font(.caption).foregroundStyle(Theme.text2)
            ForEach($action.params) { $param in
                ParameterDefinitionCard(param: $param) { action.params.removeAll { $0.id == param.id } }
            }
            if !action.params.isEmpty { TextField("运行按钮文字（默认：开始运行）", text: $action.runLabel) }
        }.padding(.top, 8)
    }
}
private struct ParameterDefinitionCard: View {
    @Binding var param: ActionParameterDraft
    let remove: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("名称", text: $param.label)
                TextField("key", text: $param.key).font(.system(.body, design: .monospaced))
                Picker("类型", selection: $param.type) {
                    ForEach(ActionParamType.known, id: \.rawValue) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 100)
                Button("−", action: remove).help("删除参数")
            }
            TextField("说明", text: $param.description)
            HStack {
                Toggle("必填", isOn: $param.required)
                Toggle("敏感", isOn: $param.secret)
                Toggle("有默认值", isOn: $param.hasDefault)
            }.toggleStyle(.checkbox)
            if param.type == .number {
                HStack { TextField("最小值（可选）", text: $param.minText); TextField("最大值（可选）", text: $param.maxText) }
            }
            if param.type == .enum || param.type == .multiselect {
                ForEach($param.choices) { $choice in
                    VStack(spacing: 4) {
                        HStack {
                            TextField("候选值", text: $choice.value)
                            TextField("显示名称", text: $choice.label)
                            Button("−") { param.choices.removeAll { $0.id == choice.id } }
                        }
                        TextField("候选项说明（可选）", text: $choice.description)
                    }
                }
                Button("＋ 候选项") { param.choices.append(ActionChoiceDraft()) }
            }
            if param.hasDefault {
                if param.input.useStoredDefault {
                    HStack { Text("保持已保存的敏感默认值").foregroundStyle(Theme.text2); Spacer(); Button("修改默认值") { param.input.useStoredDefault = false } }
                } else {
                    Text("默认值").font(.caption).foregroundStyle(Theme.text2)
                    ActionParameterControl(definition: param.definition, input: $param.input)
                }
            }
        }.padding(10).background(Theme.card, in: RoundedRectangle(cornerRadius: 6))
            .onChange(of: param.type) { _, _ in param.input = ActionParameterInput(param.definition); param.input.enabled = true; param.hasDefault = false }
            .onChange(of: param.secret) { _, value in if !value { param.input.useStoredDefault = false } }
    }
}
