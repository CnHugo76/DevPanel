import DevPanelKit
import SwiftUI

private struct ActionFormHeight: PreferenceKey {
    static let defaultValue: CGFloat = 260
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct ActionRunHost: ViewModifier {
    let model: AppModel
    @Environment(\.inlineSheets) private var inline
    func body(content: Content) -> some View {
        content
            .sheet(item: inline ? .constant(nil) : Binding(get: { model.projectInspector.parameterForm }, set: { model.projectInspector.parameterForm = $0 })) { form in
                sheet(form)
            }
            .overlay {
                if inline, let form = model.projectInspector.parameterForm {
                    ZStack {
                        Color.black.opacity(0.28)
                        sheet(form).background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line2))
                    }
                }
            }
    }
    private func sheet(_ form: ActionRunSession) -> some View {
        ActionRunSheet(model: model, form: form) { model.projectInspector.parameterForm = nil }
    }
}

struct ActionRunSheet: View {
    let model: AppModel
    @Bindable var form: ActionRunSession
    let dismiss: () -> Void
    @State private var focusKey: String?
    @State private var attempt = 0
    @State private var fieldsHeight: CGFloat = 260
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(form.actionName).font(.title3.weight(.semibold))
                if let description = form.description { Text(description).font(.callout).foregroundStyle(Theme.text2) }
                Text("参数仅用于本次运行").font(.caption).foregroundStyle(Theme.text3)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach($form.fields) { $field in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(field.definition.label).fontWeight(.medium)
                                if field.definition.required == true { Text("必填").font(.caption).foregroundStyle(Theme.text3) }
                                Spacer()
                                if field.definition.defaultValue == nil && field.definition.required != true {
                                    Toggle("本次传入", isOn: $field.input.enabled).toggleStyle(.checkbox).font(.caption)
                                }
                            }
                            if let description = field.definition.description { Text(description).font(.caption).foregroundStyle(Theme.text2) }
                            if field.definition.defaultValue == .secret {
                                Toggle("使用已保存的默认值", isOn: $field.input.useStoredDefault).toggleStyle(.checkbox)
                            }
                            if !field.input.useStoredDefault {
                                ActionParameterControl(definition: field.definition, input: $field.input, focusRequest: focusKey == field.id ? attempt : 0)
                                    .disabled(!field.input.enabled || form.isSubmitting)
                            }
                            if let error = form.errors[field.id] { Text(error).font(.caption).foregroundStyle(Theme.red).accessibilityLabel("\(field.definition.label)：\(error)") }
                        }
                    }
                }.padding(.vertical, 2)
                    .background(GeometryReader { g in Color.clear.preference(key: ActionFormHeight.self, value: g.size.height) })
            }.frame(height: min(fieldsHeight, 420))
                .onPreferenceChange(ActionFormHeight.self) { fieldsHeight = $0 }
                .disabled(form.isSubmitting)
            if form.needsServiceWarning && form.runningCount > 0 {
                Label("项目有 \(form.runningCount) 个服务正在运行，请确认本次操作。", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(Theme.amber)
            }
            if let message = form.message { Text(message).font(.callout).foregroundStyle(form.stale || form.uncertain ? Theme.amber : Theme.red).textSelection(.enabled) }
            HStack {
                if form.stale { Button("载入最新定义…") { Task { await model.reloadActionParameters(form) } }.disabled(!model.isConnected) }
                Spacer()
                Button(form.uncertain ? "查看运行记录" : "取消", role: .cancel, action: dismiss)
                    .keyboardShortcut(.cancelAction).disabled(form.isSubmitting)
                Button(form.isSubmitting ? "正在提交…" : form.runLabel) {
                    Task {
                        await model.submitActionParameters(form)
                        focusKey = form.fields.first { form.errors[$0.id] != nil }?.id; attempt += 1
                    }
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(!model.isConnected || form.isSubmitting || form.stale || form.uncertain)
            }
        }
        .padding(24).frame(width: 460).textFieldStyle(.roundedBorder)
        .interactiveDismissDisabled(form.isSubmitting)
    }
}
