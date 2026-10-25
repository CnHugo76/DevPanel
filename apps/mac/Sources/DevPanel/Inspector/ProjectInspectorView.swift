import AppKit
import DevPanelKit
import SwiftUI

struct ProjectInspectorView: View {
    let model: AppModel
    let project: ProjectView
    @Environment(EditorPresenter.self) private var editor: EditorPresenter?
    private var tab: ProjectInspectorTab { model.projectInspector.tabs[project.id, default: .actions] }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.name).font(.system(size: 15, weight: .semibold))
                    Text(Format.tildePath(project.root)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text3).lineLimit(1)
                }
                Spacer()
                Button("编辑…") { editor?.edit(project.id) }.disabled(!model.isConnected)
                IconButton(symbol: "✕", help: "关闭项目详情") { model.select(nil); model.syncLogSession() }
            }.padding(14)
            HStack(spacing: 16) {
                ForEach(model.projectTabs(project.id)) { item in
                    Button(item.title) { model.projectInspector.tabs[project.id] = item; model.syncLogSession() }
                        .buttonStyle(.plain).foregroundStyle(tab == item ? Theme.accent2 : Theme.text2)
                        .padding(.bottom, 8).overlay(alignment: .bottom) { Rectangle().fill(tab == item ? Theme.accent : .clear).frame(height: 2) }
                }
            }.padding(.horizontal, 14)
            Divider()
            switch tab {
            case .activity: ActivityTab(model: model, project: project)
            case .maven: MavenTab(model: model, project: project)
            case .actions: QuickActionsTab(model: model, project: project)
            case .git: GitTab(model: model, project: project)
            case .options: OptionsTab(model: model, ref: ServiceRef(project.id, "*"))
            }
        }.background(Theme.bar)
    }
}

struct QuickActionsTab: View {
    let model: AppModel
    let project: ProjectView
    @Environment(EditorPresenter.self) private var editor: EditorPresenter?
    var body: some View {
        VStack(spacing: 0) {
            if project.actions.isEmpty {
                ContentUnavailableView("尚无快捷操作", systemImage: "play.rectangle", description: Text("在编辑项目中添加命令，注册与保存不会执行命令。"))
                Button("添加快捷操作…") { editor?.edit(project.id) }.disabled(!model.isConnected).padding()
            } else {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(project.actions) { action in actionRow(action) }
                    }
                }.frame(maxHeight: 220)
                Divider()
                if let ref = model.selectedTaskRef {
                    TaskOutput(model: model, project: project, ref: ref)
                }
            }
        }
    }
    private func actionRow(_ action: ActionView) -> some View {
        let selected = model.selectedTaskRef?.target == .action(action.id)
        let command = model.configs[project.id]?.config.actions?.first { $0.id == action.id }?.command ?? []
        return HStack(alignment: .top, spacing: 8) {
            Button {
                model.projectInspector.actionChoice[project.id] = action.id
                model.syncLogSession()
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(action.name).font(.system(size: 12.5, weight: .semibold))
                    if let description = action.description { Text(description).font(.system(size: 11)).foregroundStyle(Theme.text2) }
                    Text(CommandText.join(command)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text3).lineLimit(2)
                        .help(CommandPreview.make(command, params: model.params(project.id)).args.map(\.text).joined(separator: " "))
                    if let last = action.lastRun { TaskRunText(model: model, run: last).font(.system(size: 10.5)).foregroundStyle(last.state == .succeeded ? Theme.green : Theme.text3) }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            QuickActionRunButton(model: model, project: project, action: action)
            MoreMenu {
                Button("编辑…") { editor?.edit(project.id) }
                Button("复制命令") { copy(CommandText.join(command)) }
                Button("删除", role: .destructive) { Task { await model.deleteQuickAction(project.id, actionId: action.id) } }.disabled(action.currentRun != nil)
            }.disabled(!model.isConnected)
        }.padding(12).background(selected ? Theme.accentSoft : .clear)
    }
}

struct TaskOutput: View {
    let model: AppModel
    let project: ProjectView
    let ref: TaskRef
    var body: some View {
        VStack(spacing: 0) {
            LogsTab(model: model, ref: .task(ref), project: project, currentRunId: model.taskRuns(ref).first { $0.endedAt == nil }?.id)
            if let run = model.taskRuns(ref).first(where: { $0.id == model.viewedRunId(for: ref) }) {
                TaskRunText(model: model, run: run, includeResources: true)
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(run.state == .failed || run.state == .timedOut ? Theme.red : Theme.text2)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
        }
        .task(id: String(describing: ref) + String(model.isConnected) + (model.latestRunId(for: ref) ?? "") + (model.taskRuns(ref).first?.endedAt ?? "")) {
            await model.refreshRuns(ref); model.syncLogSession()
        }
        .onChange(of: model.viewedRunId(for: ref)) { _, _ in model.syncLogSession() }
        .onChange(of: model.isConnected) { _, connected in if connected { model.inspector.logs.connectionRestored() } }
        .onDisappear { model.syncLogSession() }
    }

}

struct QuickActionRunButton: View {
    let model: AppModel
    let project: ProjectView
    let action: ActionView
    @State private var force = false
    var body: some View {
        Group {
            if let run = action.currentRun {
                if run.cancelTimedOut {
                    Button("强制取消…", role: .destructive) { force = true }
                } else {
                    Button { Task { await model.cancelTask(run) } } label: {
                        HStack(spacing: 4) { if run.state == .running { ProgressView().controlSize(.mini) }; Text(run.state == .cancelling ? "取消中…" : "■") }
                    }.disabled(run.state == .cancelling)
                }
            } else {
                Button("▶") { model.requestQuickAction(project.id, actionId: action.id) }
                    .disabled(model.projectInspector.pending.contains(TaskRef(project.id, .action(action.id))))
            }
        }.buttonStyle(.borderless).disabled(!model.isConnected)
        .alert("强制取消 \(action.name)？", isPresented: $force) {
            Button("强制取消", role: .destructive) { if let run = action.currentRun { Task { await model.cancelTask(run, force: true) } } }
            Button("返回", role: .cancel) {}
        } message: { Text("将立即终止此任务的已核验进程，尚未保存的结果可能丢失。") }
    }
}

struct QuickActionsRow: View {
    let model: AppModel
    let project: ProjectView
    var body: some View {
        if !project.actions.isEmpty {
            FlowLayout(spacing: 10) {
                Text("快捷操作").foregroundStyle(Theme.text3)
                ForEach(project.actions) { action in
                    HStack(spacing: 5) {
                        QuickActionRunButton(model: model, project: project, action: action)
                        Button(action.name) { model.selectProject(project.id, tab: .actions); model.projectInspector.actionChoice[project.id] = action.id }
                            .buttonStyle(.plain)
                        if let run = action.currentRun ?? action.lastRun {
                            TaskRunText(model: model, run: run, style: .compact).foregroundStyle(Theme.text3)
                        }
                    }.help(model.configs[project.id]?.config.actions?.first(where: { $0.id == action.id }).map { CommandText.join($0.command) } ?? "")
                }

            }.font(.system(size: 11.5)).padding(.horizontal, 14).padding(.bottom, 12)
        }
    }
}
