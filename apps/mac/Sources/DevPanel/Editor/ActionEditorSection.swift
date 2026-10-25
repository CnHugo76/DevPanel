import DevPanelKit
import SwiftUI

struct ActionEditorSection: View {
    @Bindable var editor: ProjectEditor
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("快捷操作").font(.headline)
                Spacer()
                Button("＋ 添加快捷操作") {
                    editor.draft.actions.append(ActionDraft(service: ServiceDraft(serviceId: Slug.make("action", taken: editor.draft.actions.map { $0.service.serviceId }), idAuto: true)))
                }
            }
            ForEach($editor.draft.actions) { $action in
                ActionEditorCard(editor: editor, action: $action)
            }
        }
    }
}
private struct ActionEditorCard: View {
    let editor: ProjectEditor
    @Binding var action: ActionDraft
    private var index: Int { editor.draft.actions.firstIndex { $0.id == action.id } ?? 0 }
    private var running: Bool { editor.actionIsRunning(action.service.origId ?? action.service.serviceId) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(action.service.name.isEmpty ? "新快捷操作" : action.service.name).fontWeight(.semibold)
                if running { Text("运行中").foregroundStyle(Theme.amber) }
                Spacer()
                Button("删除", role: .destructive) { editor.draft.actions.removeAll { $0.id == action.id } }.disabled(running)
            }
            HStack {
                field("名称", text: $action.service.name)
                field("ID", text: $action.service.serviceId).disabled(running)
            }
            field("说明", text: $action.description)
            field("工作目录", text: $action.service.cwd)
            field("命令", text: $action.service.commandText)
            Toggle("通过 Shell 运行", isOn: $action.service.viaShell).toggleStyle(.checkbox)
            CommandPreviewBox(service: action.service, params: editor.params, local: nil, issues: [], hasResolution: false)
            HStack {
                field("停止等待（秒，默认 10）", text: $action.service.stopTimeoutText)
                field("最长运行时间（秒，留空不限）", text: $action.timeoutText)
            }
            Toggle("服务运行时需确认", isOn: $action.confirmWhenServicesRunning).toggleStyle(.checkbox)
            Text("环境变量（覆盖项目级同名变量）").font(.caption).foregroundStyle(Theme.text2)
            ForEach($action.service.env) { $row in
                HStack {
                    TextField("变量名", text: Binding(get: { row.name }, set: { row.rename($0) }))
                    if row.secret { SecureField(row.storedName == nil ? "值" : "留空保持已保存值", text: $row.value) }
                    else { TextField("值", text: $row.value) }
                    Toggle("敏感", isOn: Binding(get: { row.secret }, set: { row.setSecret($0) })).toggleStyle(.checkbox)
                    Button("−") { action.service.env.removeAll { $0.id == row.id } }
                }
            }
            Button("＋ 环境变量") { action.service.env.append(EnvRow()) }
            ForEach(editor.localErrors.keys.filter { $0.hasPrefix("actions[\(index)]") }.sorted(), id: \.self) { key in
                Text(editor.localErrors[key] ?? "").font(.caption).foregroundStyle(Theme.red)
            }
        }.textFieldStyle(.roundedBorder).font(.system(size: 12)).padding(12)
            .background(Theme.card2, in: RoundedRectangle(cornerRadius: 10))
            .onChange(of: action) { _, _ in editor.fieldDidBlur() }
    }
    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(Theme.text2)
            TextField(title, text: text)
        }
    }
}
