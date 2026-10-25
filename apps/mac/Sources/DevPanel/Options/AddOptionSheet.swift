import DevPanelKit
import SwiftUI

struct AddOptionSheet: View {
    let presenter: OptionPresenter
    @State var project: Project
    @State var key = ""
    @State var label = ""
    @State var type: ParamType = .string
    @State var text = ""
    @State var explanation = ""
    @State var choices = ""
    @State var minimum = ""
    @State var maximum = ""
    @State var secret = false
    @State private var error: String?
    @State private var busy = false
    @State private var added = false
    @Environment(EditorPresenter.self) private var projectEditor: EditorPresenter?

    private var param: ParamConfig {
        ParamConfig(key: key, label: label, type: type, description: explanation,
                    choices: type == .enum ? choices.split(separator: "\n").map { row in
                        let fields = row.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                        return ParamChoice(value: fields[0], label: fields.count > 1 ? fields[1] : nil, description: fields.count > 2 ? fields[2] : nil)
                    } : nil,
                    min: type == .number ? Double(minimum) : nil, max: type == .number ? Double(maximum) : nil, secret: secret)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(added ? "选项已添加" : "添加选项").font(.headline)
            if added {
                Text("在命令或环境变量中用 ${\(key)} 引用它。添加选项不会启动服务。")
                Button("编辑项目…") { presenter.sheet = nil; projectEditor?.edit(project.id) }
                Button("完成") { presenter.sheet = nil }
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow { Text("Key"); TextField("字母开头，最多 32 位", text: $key) }
                    GridRow { Text("名称"); TextField("例如 API 端口", text: $label) }
                    GridRow {
                        Text("类型")
                        Picker("类型", selection: $type) {
                            Text("文本").tag(ParamType.string); Text("数字").tag(ParamType.number)
                            Text("开关").tag(ParamType.boolean); Text("单选").tag(ParamType.enum)
                        }.labelsHidden()
                    }
                    GridRow { Text("说明"); TextField("可选", text: $explanation, axis: .vertical).lineLimit(2...3) }
                    if type == .enum {
                        GridRow { Text("可选值"); TextField("每行：值 | 标签 | 说明", text: $choices, axis: .vertical).lineLimit(3...5) }
                    }
                    if type == .number {
                        GridRow { Text("范围"); HStack { TextField("最小值（可选）", text: $minimum); TextField("最大值（可选）", text: $maximum) } }
                    }
                    GridRow { Text("敏感"); Toggle("隐藏值", isOn: $secret).toggleStyle(.checkbox) }
                    GridRow { Text("值"); VStack(alignment: .leading) { OptionValueControl(param: param, text: $text) } }
                }
                if !key.isEmpty && !OptionRules.validKey(key) { Text("Key 需字母开头，只能含字母、数字、下划线，最多 32 位").foregroundStyle(Theme.red) }
                if let error { Text(error).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true) }
                HStack {
                    Spacer()
                    Button("取消") { presenter.sheet = nil }
                    Button("添加") { Task { await save() } }.buttonStyle(.borderedProminent)
                        .disabled(busy || !presenter.model.isConnected)
                }
            }
        }.font(.system(size: 12.5)).textFieldStyle(.roundedBorder).padding(20)
            .onChange(of: type) { _, type in if type == .boolean { text = "false" } else { text = "" } }
    }
    private func save() async {
        guard OptionRules.validKey(key) else { error = "Key 格式不正确"; return }
        guard !label.trimmingCharacters(in: .whitespaces).isEmpty else { error = "请输入名称"; return }
        if type == .number {
            for bound in [minimum, maximum] where !bound.isEmpty {
                guard let n = Double(bound), n.isFinite else { error = "范围必须为有效数字"; return }
            }
            if let min = Double(minimum), let max = Double(maximum), min > max { error = "最小值不能大于最大值"; return }
        }
        busy = true; defer { busy = false }
        do {
            var p = param
            p.value = try OptionRules.value(text, for: p, creating: true)
            _ = try await presenter.model.addOption(project.id, revision: project.revision, param: p)
            added = true
        } catch {
            let e = error as? ApiError ?? .unreachable(error.localizedDescription)
            self.error = OptionRules.errorText(e)
            if e.code == .revisionMismatch, let fresh = try? await presenter.model.fetchProject(project.id) { project = fresh }
        }
    }
}
