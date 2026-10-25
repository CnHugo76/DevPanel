import DevPanelKit
import SwiftUI

struct MavenGoalsSheet: View {
    let model: AppModel
    let project: ProjectView
    let run: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    private var request: MavenRunRequest { model.maven.request(project.id, goals: text.split(whereSeparator: \.isWhitespace).map(String.init)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("运行 Maven 目标").font(.headline)
            Text("模块：\(request.moduleId) · 使用当前 Profiles 和运行开关").font(.caption).foregroundStyle(Theme.text2)
            TextField("例如 dependency:tree versions:display-dependency-updates", text: $text)
                .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
            Text(CommandText.join(request.previewCommand(executable: model.maven.models[model.maven.key(project.id)]?.executable ?? .mvn)))
                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            if !text.isEmpty, let error = request.localError { Text(error).font(.caption).foregroundStyle(Theme.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("运行") { let goals = request.goals; dismiss(); run(goals) }
                    .keyboardShortcut(.defaultAction).disabled(request.localError != nil || !model.isConnected)
            }
        }.padding(20).frame(width: 480)
    }
}

struct MavenSaveActionSheet: View {
    let model: AppModel
    let project: ProjectView
    let request: MavenRunRequest
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var actionId: String
    @State private var description = ""
    @State private var error: String?
    @State private var saving = false
    init(model: AppModel, project: ProjectView, request: MavenRunRequest) {
        self.model = model; self.project = project; self.request = request
        _name = State(initialValue: request.goals.joined(separator: " ") + (request.moduleId == "." ? "" : " · " + request.moduleId))
        _actionId = State(initialValue: Slug.make("maven-" + request.goals.joined(separator: "-"), taken: project.actions.map(\.id)))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("存为快捷操作").font(.headline)
            Text("保存后可从项目卡片运行，不会立即执行。").font(.caption).foregroundStyle(Theme.text2)
            LabeledContent("名称") { TextField("名称", text: $name) }
            LabeledContent("ID") { TextField("ID", text: $actionId) }
            LabeledContent("说明") { TextField("说明（可选）", text: $description) }
            Text(CommandText.join(request.previewCommand(executable: model.maven.models[model.maven.key(project.id)]?.executable ?? .mvn)))
                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            if request.goals.contains("clean") { Text("已设置：服务运行时需确认").font(.caption).foregroundStyle(Theme.amber) }
            if let error { Text(error).font(.caption).foregroundStyle(Theme.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button(saving ? "保存中…" : "保存") { save() }.keyboardShortcut(.defaultAction)
                    .disabled(saving || !model.isConnected || name.trimmingCharacters(in: .whitespaces).isEmpty || !Slug.isValidServiceID(actionId))
            }
        }.textFieldStyle(.roundedBorder).padding(20).frame(width: 460)
    }
    private func save() {
        saving = true
        Task {
            defer { saving = false }
            do {
                try await model.saveMavenAction(project.id, request: request, name: name.trimmingCharacters(in: .whitespaces), actionId: actionId, description: description)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
