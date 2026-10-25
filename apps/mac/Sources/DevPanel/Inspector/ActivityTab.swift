import DevPanelKit
import SwiftUI

struct ActivityTab: View {
    let model: AppModel
    let project: ProjectView
    @State private var expanded: Set<String> = []
    @State private var taskQuery = ""
    private var loading: Bool { model.activityLoading.contains(project.id) }
    private var selectedTask: String? { model.activityTaskFilters[project.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            filterBar
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    Text("Agent 名称与工作标识由调用方自报，用于关联操作。")
                        .font(.system(size: 11)).foregroundStyle(Theme.text3)
                    if let error = model.activityError {
                        Text(error).font(.system(size: 11.5)).foregroundStyle(Theme.red)
                        Button("重试") { Task { await model.refreshActivity(project.id) } }.disabled(loading || !model.isConnected)
                    }
                    ForEach(model.activityEntries[project.id, default: []]) { entry in
                        activity(entry)
                        Divider()
                    }
                    if loading {
                        ProgressView("正在读取动态…").controlSize(.small)
                    } else if model.activityHasMore[project.id] == true {
                        Button("加载更多") { Task { await model.refreshActivity(project.id, more: true) } }.disabled(!model.isConnected)
                    } else if model.activityEntries[project.id, default: []].isEmpty, model.activityError == nil {
                        Text(selectedTask == nil ? "暂无动态" : "此工作在当前项目中暂无动态")
                            .font(.system(size: 12)).foregroundStyle(Theme.text3)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }
        }
        .task(id: project.id) {
            expanded.removeAll()
            model.activityVisible = project.id
            taskQuery = selectedTask ?? ""
            let process = ProcessInfo.processInfo
            if process.environment["DEVPANEL_HOME"] != nil, process.arguments.contains("--snapshot"),
               let task = AppSnapshot.value("--activity-task", process.arguments) {
                taskQuery = task
                await model.setActivityTaskFilter(task, for: project.id)
            }
            await model.refreshActivity(project.id)
            if process.environment["DEVPANEL_HOME"] != nil, process.arguments.contains("--snapshot"), process.arguments.contains("--activity-expand") {
                expanded.formUnion(model.activityEntries[project.id, default: []].map(\.id))
            }
        }
        .onDisappear { if model.activityVisible == project.id { model.activityVisible = nil } }
        .onChange(of: model.isConnected) { _, connected in
            if connected { Task { await model.refreshActivity(project.id) } }
        }
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                TextField("工作 ID，例如 checkout-42", text: $taskQuery)
                    .textFieldStyle(.roundedBorder).font(.system(size: 11.5, design: .monospaced))
                    .accessibilityLabel("按工作 ID 筛选动态")
                    .onSubmit { apply(taskQuery) }
                Button("筛选") { apply(taskQuery) }.disabled(!model.isConnected)
                if selectedTask != nil {
                    Button("清除") { apply(nil) }.disabled(!model.isConnected)
                }
            }
            if let selectedTask {
                Text("当前工作 · " + selectedTask).textSelection(.enabled).font(.system(size: 11)).foregroundStyle(Theme.accent2)
            } else {
                Text("可直接输入工作 ID，查看当前项目内的关联操作。")
                    .font(.system(size: 11)).foregroundStyle(Theme.text3)
            }
        }.padding(14)
    }

    private func activity(_ entry: ActivityEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(entry.actor.displayName) \(entry.title)").font(.system(size: 12, weight: .medium))
            if let work = entry.actor.workSummary {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("工作 · " + work).font(.system(size: 11)).foregroundStyle(Theme.text2).textSelection(.enabled)
                    if let id = entry.actor.filterableTaskId, selectedTask != id {
                        Button("仅看此工作") { apply(id) }.font(.system(size: 11)).disabled(!model.isConnected)
                    }
                }
            }
            Text(entry.at).font(.system(size: 10.5)).foregroundStyle(Theme.text3)
            if let changes = entry.detail["changes"]?.arrayValue, !changes.isEmpty {
                DisclosureGroup("配置差异（\(changes.count) 项）", isExpanded: Binding(get: { expanded.contains(entry.id) }, set: { if $0 { expanded.insert(entry.id) } else { expanded.remove(entry.id) } })) {
                    ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
                        Text("\(change["path"]?.stringValue ?? "")：\(display(change["existing"])) → \(display(change["incoming"]))")
                            .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    }
                    if entry.detail["changesTruncated"]?.boolValue == true { Text("其余差异已省略") }
                }.font(.system(size: 11))
            }
            ForEach(entry.runIds, id: \.self) { runId in
                Button("查看运行日志 \(Format.shortRunId(runId))") { Task { await model.openActivityRun(entry, runId: runId) } }.buttonStyle(.plain).foregroundStyle(Theme.accent2)
            }
        }
    }

    private func apply(_ task: String?) {
        taskQuery = task ?? ""
        expanded.removeAll()
        Task { await model.setActivityTaskFilter(task, for: project.id) }
    }

    private func display(_ value: JSONValue?) -> String {
        guard let value else { return "—" }
        if value["secret"]?.boolValue == true { return "••••" }
        if let text = value.stringValue { return text }
        return (try? String(data: ContractCoding.encoder().encode(value), encoding: .utf8)) ?? "—"
    }
}
