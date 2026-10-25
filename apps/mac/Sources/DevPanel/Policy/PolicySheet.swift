import DevPanelKit
import SwiftUI

struct PolicySheet: View {
    let model: AppModel
    let project: ProjectView
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ProjectPolicy()
    @State private var loaded = false
    @State private var saving = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("AI 权限 · \(project.name)").font(.system(size: 16, weight: .semibold))
            Text("规则约束命令行发起的服务操作，界面操作始终可用。agent 名称为自报名称。").font(.system(size: 12)).foregroundStyle(Theme.text2)
            Toggle("你停止服务后，暂停 AI 启动", isOn: $draft.holdAfterUserStop)
            Toggle("允许 AI 强制停止", isOn: Binding(get: { draft.agentForceStop == .allow }, set: { draft.agentForceStop = $0 ? .allow : .deny }))
            Text("锁定的服务").font(.system(size: 12, weight: .semibold))
            ForEach(project.services) { service in
                Toggle(service.name, isOn: Binding(get: { draft.lockedServices.contains(service.id) }, set: { locked in draft.lockedServices.removeAll { $0 == service.id }; if locked { draft.lockedServices.append(service.id) } }))
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saving ? "保存中…" : "保存") {
                    saving = true
                    Task { do { try await model.savePolicy(project.id, policy: draft); dismiss() } catch { self.error = error.localizedDescription }; saving = false }
                }.keyboardShortcut(.defaultAction).disabled(!loaded || saving || !model.isConnected)
            }
        }.padding(24).frame(width: 450)
        .disabled(saving)
        .task {
            do { draft = try await model.loadPolicy(project.id); loaded = true }
            catch { self.error = error.localizedDescription }
        }
    }
}
struct SupervisionNote: View {
    let model: AppModel
    let project: ProjectView
    let service: ServiceView
    var body: some View {
        if let hold = service.hold {
            VStack(alignment: .leading, spacing: 3) {
                Label("AI 需你同意", systemImage: "pause.fill").foregroundStyle(Theme.amber)
                    .help("你在 \(Timestamps.date(hold.since).map { Format.clock($0) } ?? hold.since) 停止了它")
                Button("允许 AI 启动") { Task { await model.allowAgentStart(ServiceRef(project.id, service.id)) } }.buttonStyle(.plain).foregroundStyle(Theme.accent2).disabled(!model.isConnected)
            }.font(.system(size: 10.5)).fixedSize(horizontal: false, vertical: true)
        }
    }
}
