import DevPanelKit
import SwiftUI

/// Environment variables: name / value / 敏感. Secret values are write-only: a stored one shows
/// "已设置（留空保持不变）" and is never revealed.
struct EnvTable: View {
    let editor: ProjectEditor
    @Binding var rows: [EnvRow]
    /// The service the rows belong to (nil = project level).
    let service: ServiceDraft?
    /// `env` or `services[i].env` (local error keys).
    let pathPrefix: String
    let issues: [ValidationIssue]
    var focus: FocusState<EditorField?>.Binding
    let onCommit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !rows.isEmpty {
                HStack(spacing: 8) {
                    Text("名称").frame(width: 190, alignment: .leading)
                    Text("值").frame(maxWidth: .infinity, alignment: .leading)
                    Text("敏感").frame(width: 58, alignment: .leading)
                    Color.clear.frame(width: 24)
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.text3)
                .accessibilityHidden(true)
            }
            ForEach(rows) { row in
                rowView(row)
            }
            HStack(spacing: 8) {
                SheetButton(title: "＋ 添加环境变量") {
                    let row = EnvRow()
                    rows.append(row)
                    focus.wrappedValue = .envName(row.id)
                }
                if let e = editor.localError(pathPrefix) { HintLine(tone: .bad, text: e) }
            }
            // Issues about variables of this table (e.g. WARN_SECRET_LIKE_PLAIN).
            ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                HintLine(tone: issue.severity == .error ? .bad : .warn, text: issue.message)
            }
        }
    }

    private func binding(_ id: UUID) -> Binding<EnvRow> {
        Binding(
            get: { rows.first { $0.id == id } ?? EnvRow(id: id) },
            set: { new in
                if let i = rows.firstIndex(where: { $0.id == id }) { rows[i] = new }
            })
    }

    private func rowView(_ row: EnvRow) -> some View {
        let b = binding(row.id)
        let name = row.name.trimmingCharacters(in: .whitespaces)
        let keeps = editor.keepsStoredSecret(row, in: service)
        let error = name.isEmpty ? nil : editor.localError("\(pathPrefix).\(name)")
        let unknown = row.secret ? [] : CommandPreview.unknownKeys(in: row.value, params: editor.params)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                EditorTextField(
                    label: "环境变量名称",
                    text: Binding(get: { b.wrappedValue.name }, set: { b.wrappedValue.rename($0) }),
                    prompt: "NAME", monospaced: true, invalid: error != nil, field: .envName(row.id), focus: focus)
                    .frame(width: 190)
                EditorTextField(
                    label: name.isEmpty ? "环境变量值" : "\(name) 的值", text: b.value,
                    prompt: row.secret ? (keeps ? "已设置（留空保持不变）" : "敏感值，保存后不再显示") : "值",
                    monospaced: !row.secret, secure: row.secret, field: .envValue(row.id), focus: focus)
                EditorCheckbox(
                    title: "敏感",
                    isOn: Binding(
                        get: { b.wrappedValue.secret },
                        set: {
                            b.wrappedValue.setSecret($0)
                            onCommit()
                        }),
                    help: "敏感值只写不读：保存后任何界面都不会再显示")
                    .frame(width: 58, alignment: .leading)
                    .accessibilityLabel(name.isEmpty ? "敏感" : "\(name) 是敏感值")
                CardIconButton(systemImage: "minus.circle", label: "删除环境变量 \(name)") {
                    rows.removeAll { $0.id == row.id }
                    onCommit()
                }
            }
            if let error { HintLine(tone: .bad, text: error) }
            if !unknown.isEmpty {
                HintLine(tone: .bad, text: "引用了不存在的选项：" + unknown.map { "${\($0)}" }.joined(separator: "、"))
            }
        }
    }
}
