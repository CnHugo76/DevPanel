import DevPanelKit
import SwiftUI

struct ActivityTab: View {
    let model: AppModel
    let project: ProjectView
    @State private var expanded: Set<String> = []
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                Text("来源中的 agent 名称为自报名称").font(.system(size: 11)).foregroundStyle(Theme.text3)
                if let error = model.activityError { Text(error).foregroundStyle(Theme.red) }
                ForEach(model.activityEntries[project.id, default: []]) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(entry.actor.displayName) \(entry.title)").font(.system(size: 12, weight: .medium))
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
                    Divider()
                }
                if model.activityHasMore[project.id] == true {
                    ProgressView().controlSize(.small).onAppear { Task { await model.refreshActivity(project.id, more: true) } }
                } else if model.activityEntries[project.id, default: []].isEmpty { Text("暂无动态").foregroundStyle(Theme.text3) }
            }.padding(14)
        }
        .task(id: project.id) {
            model.activityVisible = project.id; await model.refreshActivity(project.id)
            let process = ProcessInfo.processInfo
            if process.environment["DEVPANEL_HOME"] != nil, process.arguments.contains("--snapshot"), process.arguments.contains("--activity-expand") {
                expanded.formUnion(model.activityEntries[project.id, default: []].map(\.id))
            }
        }
        .onDisappear { if model.activityVisible == project.id { model.activityVisible = nil } }
    }
    private func display(_ value: JSONValue?) -> String {
        guard let value else { return "—" }
        if value["secret"]?.boolValue == true { return "••••" }
        if let text = value.stringValue { return text }
        return (try? String(data: ContractCoding.encoder().encode(value), encoding: .utf8)) ?? "—"
    }
}
