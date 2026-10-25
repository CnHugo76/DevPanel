import DevPanelKit
import SwiftUI

struct OptionValueControl: View {
    let param: ParamConfig
    @Binding var text: String

    var body: some View {
        if param.isSecret {
            SecureField("设置新值（留空不改）", text: $text).font(.system(.body, design: .monospaced))
        } else {
            switch param.type {
            case .enum:
                Picker("值", selection: $text) {
                    ForEach(param.choices ?? [], id: \.value) { choice in
                        Text(choice.value + (choice.label.map { " · " + $0 } ?? "")).tag(choice.value)
                    }
                }.labelsHidden()
            case .boolean:
                Toggle("启用", isOn: Binding(get: { text == "true" }, set: { text = $0 ? "true" : "false" })).toggleStyle(.switch)
            case .number:
                HStack {
                    TextField("数值", text: $text).font(.system(.body, design: .monospaced))
                    Stepper("调整数值", onIncrement: { step(1) }, onDecrement: { step(-1) }).labelsHidden()
                }
            case .string:
                TextField("值", text: $text).font(.system(.body, design: .monospaced))
            case .other: Text("此版本暂不支持该选项类型").foregroundStyle(Theme.text3)
            }
        }
    }

    private func step(_ delta: Double) {
        let n = (Double(text) ?? param.min ?? 0) + delta
        text = ParamValue.number(min(param.max ?? .greatestFiniteMagnitude, max(param.min ?? -.greatestFiniteMagnitude, n))).description
    }
}

struct OptionEditCard: View {
    @Bindable var editor: OptionEditor
    var editableDescription = false
    var close: (() -> Void)?
    @Environment(OptionPresenter.self) private var presenter: OptionPresenter?
    @State private var showDetails = ProcessInfo.processInfo.arguments.contains("--option-details")

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(editor.label).font(.system(size: 12.5, weight: .medium))
                Spacer(minLength: 8)
                if editor.busy { ProgressView().controlSize(.mini) }
                Button { showDetails.toggle() } label: {
                    Image(systemName: showDetails ? "questionmark.circle.fill" : "questionmark.circle")
                        .foregroundStyle(showDetails ? Theme.accent2 : Theme.text3)
                }.buttonStyle(.plain).help(showDetails ? "收起说明" : "说明与高级设置")
                    .accessibilityLabel("说明与高级设置")
            }
            OptionValueControl(param: editor.param, text: $editor.text)
                .disabled(editor.deleted || editor.busy || !editor.model.isConnected)
            if showDetails {
                details
            }
            if let error = editor.error {
                Text(error).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true)
                if !editor.deleted {
                    Button(editor.conflict ? "使用当前输入重试" : "重试") { Task { await editor.save() } }
                        .disabled(editor.busy || !editor.model.isConnected)
                }
            }
            if let close {
                HStack {
                    Text("下次启动生效").font(.system(size: 11)).foregroundStyle(Theme.text3)
                    Spacer()
                    Button("完成") { Task { if await editor.save() { close() } } }
                        .disabled(editor.busy || editor.conflict).buttonStyle(.borderedProminent)
                }
            }
        }
        .font(.system(size: 12.5))
        .textFieldStyle(.roundedBorder)
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
        .onChange(of: editor.text) { _, _ in editor.changed() }
        .onChange(of: editor.label) { _, _ in editor.changed() }
        .onChange(of: editor.model.configs[editor.projectId]) { _, p in if let p { editor.synchronize(p) } }
        .onDisappear { if editor.isDirty && !editor.conflict { Task { await editor.save() } } }
        .onChange(of: editor.explanation) { _, _ in editor.changed() }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("${\(editor.param.key)} · \(OptionRules.attribution(editor.param))")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text3)
            if editableDescription {
                TextField("名称", text: $editor.label)
                TextEditor(text: $editor.explanation).frame(height: 64).scrollContentBackground(.hidden)
                    .padding(6).background(Theme.window, in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("说明")
            } else if let desc = editor.param.description {
                Text(desc).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(editor.param.choices ?? [], id: \.value) { choice in
                if let description = choice.description {
                    Text("\(choice.value)：\(description)").foregroundStyle(Theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if editor.param.min != nil || editor.param.max != nil {
                Text("范围：\(editor.param.min.map { ParamValue.number($0).description } ?? "不限") – \(editor.param.max.map { ParamValue.number($0).description } ?? "不限")")
                    .foregroundStyle(Theme.text3)
            }
            if editableDescription, let config = editor.model.configs[editor.projectId]?.config {
                ForEach(OptionRules.references(editor.param, config: config, inline: false)) { ref in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("用于：\(ref.location) \(ref.original)").foregroundStyle(Theme.text3)
                        Text("→ \(ref.text)").foregroundStyle(Theme.accent2)
                    }.font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                }
            }
            Button("删除此选项", role: .destructive) {
                close?()
                presenter?.remove(editor.projectId, key: editor.param.key)
            }.disabled(editor.deleted)
        }.disabled(editor.busy || !editor.model.isConnected)
    }

}

struct OptionChipButton: View {
    let model: AppModel
    let project: ProjectView
    let chip: ParamChip
    @State private var editor: OptionEditor?
    @State private var shown = false
    var body: some View {
        Button {
            if let p = model.configs[project.id], let param = p.config.params?.first(where: { $0.key == chip.key }) {
                editor = OptionEditor(model: model, project: p, param: param); shown = true
            }
        } label: { ParamChipView(chip: chip) }
        .buttonStyle(.plain).disabled(!model.isConnected)
        .popover(isPresented: $shown) {
            if let editor { OptionEditCard(editor: editor, close: { shown = false }).frame(width: 360) }
        }
    }
}

struct OptionsTab: View {
    let model: AppModel
    let ref: ServiceRef
    @Environment(OptionPresenter.self) private var presenter: OptionPresenter?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("改动在下次启动时生效").font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                if let project = model.configs[ref.projectId] {
                    let params = (project.config.params ?? []).filter { p in
                        ref.serviceId == "*" || (p.usedBy ?? []).contains { $0.serviceId == ref.serviceId || $0.isProjectLevel }
                    }
                    if params.isEmpty { Text(ref.serviceId == "*" ? "本项目尚无选项" : "本服务尚未引用选项").foregroundStyle(Theme.text3) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), alignment: .top)], alignment: .leading, spacing: 10) {
                        ForEach(params) { param in
                            OptionCardContainer(model: model, project: project, param: param)
                        }
                    }
                }
                Button("＋ 添加选项") { presenter?.add(ref.projectId) }.disabled(!model.isConnected)
            }.padding(14)
        }
    }
}

private struct OptionCardContainer: View {
    @State var editor: OptionEditor
    init(model: AppModel, project: Project, param: ParamConfig) {
        _editor = State(initialValue: OptionEditor(model: model, project: project, param: param))
    }
    var body: some View { OptionEditCard(editor: editor, editableDescription: true) }
}
