import DevPanelKit
import SwiftUI

struct TargetEditorSection: View {
    @Bindable var editor: ProjectEditor
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Git 仓库与 Maven 工程").font(.headline)
            Text("路径相对项目根目录；填写各仓库根目录或含 pom.xml 的工程目录。保存不会执行命令。").font(.caption).foregroundStyle(Theme.text3)
            Toggle("明确登记 Git 仓库", isOn: Binding(get: { editor.draft.repositories != nil }, set: { editor.draft.repositories = $0 ? [] : nil; editor.fieldDidBlur() })).toggleStyle(.checkbox)
            if editor.draft.repositories != nil {
                ForEach(Array((editor.draft.repositories ?? []).enumerated()), id: \.offset) { index, _ in
                    HStack {
                        TextField("ID", text: repo(index, \.id)).frame(width: 100)
                        TextField("名称", text: repo(index, \.name))
                        TextField("目录", text: repo(index, \.path))
                        Button("−") { editor.draft.repositories?.remove(at: index); editor.fieldDidBlur() }
                    }
                }
                Button("＋ Git 仓库") {
                    let id = Slug.make("repo", taken: (editor.draft.repositories ?? []).map(\.id))
                    editor.draft.repositories?.append(RepositoryConfig(id: id, name: "新仓库", path: ".")); editor.fieldDidBlur()
                }
            } else { Text("沿用项目根目录所在的 Git 仓库").font(.caption).foregroundStyle(Theme.text3) }
            Toggle("明确登记 Maven 工程", isOn: Binding(get: { editor.draft.mavenProjects != nil }, set: { editor.draft.mavenProjects = $0 ? [] : nil; editor.fieldDidBlur() })).toggleStyle(.checkbox)
            if editor.draft.mavenProjects != nil {
                ForEach(Array((editor.draft.mavenProjects ?? []).enumerated()), id: \.offset) { index, _ in
                    VStack {
                        HStack {
                            TextField("ID", text: maven(index, \.id)).frame(width: 100)
                            TextField("名称", text: maven(index, \.name))
                            TextField("目录", text: maven(index, \.path))
                            Button("−") { editor.draft.mavenProjects?.remove(at: index); editor.fieldDidBlur() }
                        }
                        Picker("可执行文件", selection: mavenMode(index)) {
                            Text("自动（优先工程 mvnw）").tag("auto")
                            Text("工程 mvnw").tag("wrapper")
                            Text("PATH 中的 mvn").tag("mvn")
                        }
                    }
                }
                Button("＋ Maven 工程") {
                    let id = Slug.make("maven", taken: (editor.draft.mavenProjects ?? []).map(\.id))
                    editor.draft.mavenProjects?.append(MavenProjectConfig(id: id, name: "新工程", path: ".")); editor.fieldDidBlur()
                }
            } else { Text("沿用项目根目录的 pom.xml 与下方 Maven 可执行文件设置").font(.caption).foregroundStyle(Theme.text3) }
        }.font(.system(size: 12)).textFieldStyle(.roundedBorder).padding(12)
            .background(Theme.card2, in: RoundedRectangle(cornerRadius: 10))
    }
    private func repo(_ index: Int, _ path: WritableKeyPath<RepositoryConfig, String>) -> Binding<String> {
        Binding(get: {
            guard let list = editor.draft.repositories, list.indices.contains(index) else { return "" }
            return list[index][keyPath: path]
        }, set: {
            guard editor.draft.repositories?.indices.contains(index) == true else { return }
            editor.draft.repositories?[index][keyPath: path] = $0; editor.fieldDidBlur()
        })
    }
    private func maven(_ index: Int, _ path: WritableKeyPath<MavenProjectConfig, String>) -> Binding<String> {
        Binding(get: {
            guard let list = editor.draft.mavenProjects, list.indices.contains(index) else { return "" }
            return list[index][keyPath: path]
        }, set: {
            guard editor.draft.mavenProjects?.indices.contains(index) == true else { return }
            editor.draft.mavenProjects?[index][keyPath: path] = $0; editor.fieldDidBlur()
        })
    }
    private func mavenMode(_ index: Int) -> Binding<String> {
        Binding(get: {
            guard let list = editor.draft.mavenProjects, list.indices.contains(index) else { return "auto" }
            return list[index].executable ?? "auto"
        }, set: {
            guard editor.draft.mavenProjects?.indices.contains(index) == true else { return }
            editor.draft.mavenProjects?[index].executable = $0; editor.fieldDidBlur()
        })
    }
}
