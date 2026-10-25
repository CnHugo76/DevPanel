import AppKit
import DevPanelKit
import SwiftUI

struct MavenTab: View {
    let model: AppModel
    let project: ProjectView
    @Environment(EditorPresenter.self) private var editor: EditorPresenter?
    @State private var showGoals = false
    @State private var goalsToRun: [String]?
    @State private var saveRequest: MavenRunRequest?
    @State private var force = false
    private var state: MavenState { model.maven }
    private var request: MavenRunRequest { state.request(project.id) }
    private var current: TaskRunSummary? { model.taskRuns(TaskRef(project.id, .maven)).first { $0.endedAt == nil } }
    private var pending: Bool { model.projectInspector.pending.contains(TaskRef(project.id, .maven)) }
    var body: some View {
        VStack(spacing: 0) {
            targetPicker
            toolbar
            if let error = state.errors[model.maven.key(project.id)] {
                HStack(alignment: .top) {
                    Text(error).font(.system(size: 11.5)).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button { state.errors[model.maven.key(project.id)] = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.foregroundStyle(Theme.red).padding(10).background(Theme.redSoft)
            }
            if let maven = state.models[model.maven.key(project.id)] {
                MavenTreeView(model: model, project: project, maven: maven, run: run, save: { saveRequest = $0 })
                    .frame(minHeight: 140, idealHeight: 250, maxHeight: 300)
                Text(request.goals.isEmpty ? "选择阶段后双击运行" : CommandText.join(request.previewCommand(executable: maven.executable)))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text2).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10).background(Theme.card2)
            } else if state.loading.contains(model.maven.key(project.id)) {
                ProgressView("正在静态解析 pom.xml…").controlSize(.small).padding(24)
            } else if project.mavenProjects?.isEmpty == true {
                ContentUnavailableView { Label("尚未登记 Maven 工程", systemImage: "shippingbox") } description: { Text("编辑项目，填写包含 pom.xml 的工程目录。") } actions: { Button("编辑项目…") { editor?.edit(project.id) } }
            } else {
                Text("无法读取 Maven 模型，可重新加载后重试。").font(.caption).foregroundStyle(Theme.text3).padding(24)
            }
            Divider()
            if project.maven != nil {
                TaskOutput(model: model, project: project, ref: TaskRef(project.id, .maven))
            }
        }
        .task(id: model.maven.key(project.id) + String(project.revision) + String(model.isConnected)) { if project.mavenProjects?.isEmpty != true { await model.loadMaven(project.id) } }
        .sheet(isPresented: $showGoals, onDismiss: {
            if let goals = goalsToRun { goalsToRun = nil; run(state.request(project.id, goals: goals)) }
        }) {
            MavenGoalsSheet(model: model, project: project) { goalsToRun = $0 }
        }
        .sheet(isPresented: Binding(get: { saveRequest != nil }, set: { if !$0 { saveRequest = nil } })) {
            if let saveRequest { MavenSaveActionSheet(model: model, project: project, request: saveRequest) }
        }
        .alert("强制取消 Maven？", isPresented: $force) {
            Button("强制取消", role: .destructive) { if let current { Task { await model.cancelTask(current, force: true) } } }
            Button("返回", role: .cancel) {}
        } message: { Text("将立即终止本次运行的已核验进程，构建结果可能不完整。") }
    }
    @ViewBuilder private var targetPicker: some View {
        if let targets = project.mavenProjects, !targets.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if model.selection != nil, let target = targets.first {
                    Text(target.name).font(.system(size: 12, weight: .medium))
                } else {
                Picker("工程", selection: Binding(get: { state.targetSelections[project.id] ?? targets.first?.id ?? "" }, set: {
                    state.targetSelections[project.id] = $0
                    model.chooseRun(nil, for: TaskRef(project.id, .maven))
                })) { ForEach(targets) { Text($0.name).tag($0.id) } }
                }
                if let target = targets.first(where: { $0.id == (state.targetSelections[project.id] ?? targets.first?.id) }) {
                    Text(target.path).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.text3).textSelection(.enabled)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(10).background(Theme.bar)
            Divider()
        }
    }
    private var toolbar: some View {
        FlowLayout(spacing: 8) {
            Button { Task { await model.loadMaven(project.id, reload: true) } } label: { Image(systemName: "arrow.clockwise") }
                .help("重新加载 Maven 模型").disabled(!model.isConnected || state.loading.contains(model.maven.key(project.id)))
            Button { run(request) } label: { Label("运行", systemImage: "play.fill") }
                .disabled(!model.isConnected || request.goals.isEmpty || pending || state.models[model.maven.key(project.id)] == nil)
            Button {
                if current?.cancelTimedOut == true { force = true }
                else if let current { Task { await model.cancelTask(current) } }
            } label: { Label(current?.cancelTimedOut == true ? "强制取消…" : "取消", systemImage: "stop.fill") }
                .disabled(!model.isConnected || current == nil || current?.state == .cancelling && current?.cancelTimedOut != true)
                .keyboardShortcut(".", modifiers: .command)
            option("跳过测试", keyPath: \.skipTests)
            option("离线", keyPath: \.offline)
            option("-am", keyPath: \.alsoMake).help("同时构建选中模块的依赖模块；根模块忽略此开关")
            Button("运行 Maven 目标…") { showGoals = true }.disabled(!model.isConnected || state.models[model.maven.key(project.id)] == nil)
            Button("存为快捷操作") { saveRequest = request }.disabled(!model.isConnected || request.goals.isEmpty || state.models[model.maven.key(project.id)] == nil)
        }.font(.system(size: 11.5)).controlSize(.small).padding(10)
    }
    private func option(_ title: String, keyPath: WritableKeyPath<MavenOptions, Bool>) -> some View {
        Toggle(title, isOn: Binding(get: { state.options[model.maven.key(project.id), default: MavenOptions()][keyPath: keyPath] }, set: { value in
            var options = state.options[model.maven.key(project.id), default: MavenOptions()]; options[keyPath: keyPath] = value
            state.setOptions(options, for: project.id)
        })).toggleStyle(.checkbox).disabled(!model.isConnected)
    }
    private func run(_ request: MavenRunRequest) { model.requestMaven(project.id, request: request) }
}
