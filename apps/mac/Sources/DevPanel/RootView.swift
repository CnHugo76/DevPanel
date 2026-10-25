import DevPanelKit
import SwiftUI

/// Window content: custom title bar, disconnected banner, and the main area chosen by connection.
struct RootView: View {
    let model: AppModel
    let prefs: ViewPreferences
    @State private var query: String
    /// Add / edit project sheet and remove confirmation (F5).
    @State private var editor: EditorPresenter
    @State private var options: OptionPresenter

    init(model: AppModel, prefs: ViewPreferences, initialQuery: String = "", editor: EditorPresenter? = nil, options: OptionPresenter? = nil) {
        self.model = model
        self.prefs = prefs
        _options = State(initialValue: options ?? OptionPresenter(model: model))
        _query = State(initialValue: initialQuery)
        _editor = State(initialValue: editor ?? EditorPresenter(model: model))
    }

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(model: model, prefs: prefs, query: $query)
                .zIndex(1)
            if showsStaleState {
                StaleBanner(connection: model.connection)
                if model.connection.status == .notRunning {
                    Button("启动管理服务") { Task { await model.startDaemon() } }
                        .disabled(model.daemonLaunch == .launching).padding(6)
                    if case .failed(let message) = model.daemonLaunch {
                        Text(message).font(.caption).foregroundStyle(Theme.red).padding(.bottom, 6)
                    }
                }
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Full-size window content must not let scrolling paint into the title bar.
                .clipped()
            ToolResourceBar(model: model)
        }
        .background(Theme.window)
        .foregroundStyle(Theme.text)
        .ignoresSafeArea(.container, edges: .top)
        .modifier(OptionHost(presenter: options))
        .editorHost(editor)
        .alert(model.projectInspector.confirmation?.title ?? "运行快捷操作？", isPresented: Binding(get: { model.projectInspector.confirmation != nil }, set: { if !$0 { model.projectInspector.confirmation = nil } }), presenting: model.projectInspector.confirmation) { confirmation in
            Button("仍然运行") { Task { await model.startQuickAction(confirmation.projectId, actionId: confirmation.actionId) } }
            Button("取消", role: .cancel) {}
        } message: { Text($0.message) }
        .alert("运行 clean？", isPresented: Binding(get: { model.maven.confirmation != nil }, set: { if !$0 { model.maven.confirmation = nil } }), presenting: model.maven.confirmation) { confirmation in
            Button("仍然运行") { Task { await model.startMaven(confirmation.projectId, request: confirmation.request) } }
            Button("取消", role: .cancel) {}
        } message: { Text($0.message) }
        .alert("操作失败", isPresented: Binding(get: { model.projectInspector.error != nil }, set: { if !$0 { model.projectInspector.error = nil } })) {
            Button("好") { model.projectInspector.error = nil }
        } message: { Text(model.projectInspector.error ?? "") }
        .onChange(of: editor.revealGeneration) { _, _ in query = "" }
    }

    /// Disconnected after having been connected: keep showing the last known state, greyed.
    private var showsStaleState: Bool { model.isStale }

    @ViewBuilder private var content: some View {
        switch model.connectionStatus {
        case .connecting:
            ProgressView("正在连接管理服务…")
                .controlSize(.small)
        case .notRunning:
            if model.isStale { main(stale: true) } else { NotRunningView(model: model) }
        case .connected:
            main(stale: false)
        case .disconnected, .unauthorized:
            if model.connection.syncedAt != nil {
                main(stale: true)
            } else {
                ConnectionProblemView(model: model)
            }
        }
    }

    @ViewBuilder private func main(stale: Bool) -> some View {
        if model.projects.isEmpty {
            EmptyProjectsView()
        } else {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    let selection = model.selection
                    Group {
                        if prefs.detailed {
                            ServiceNavigator(model: model, query: query).frame(width: 220)
                        } else {
                            OverviewView(model: model, prefs: prefs, query: query, compact: model.hasInspectorSelection)
                        }
                    }
                    if let selection {
                        InspectorContainer(
                            model: model, prefs: prefs, ref: selection,
                            width: prefs.detailed ? max(0, geo.size.width - 220) : CGFloat(prefs.effectiveInspectorWidth(total: Double(geo.size.width))))
                    } else if case .project(let id) = model.inspectorSelection, let project = model.project(id) {
                        InspectorContainer(model: model, prefs: prefs, ref: nil, project: project,
                            width: prefs.detailed ? max(0, geo.size.width - 220) : CGFloat(prefs.effectiveProjectInspectorWidth(total: Double(geo.size.width))))
                    } else if prefs.detailed {
                        Text("选择左侧项目或服务查看详情").foregroundStyle(Theme.text3)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .environment(\.isStale, stale)
        }
    }
}

/// ui-design v2 §8.
struct EmptyProjectsView: View {
    @Environment(EditorPresenter.self) private var editor: EditorPresenter?
    @Environment(AppController.self) private var controller: AppController?

    var body: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.iconGradient)
                .frame(width: 56, height: 56)
                .overlay(Text("D").font(.system(size: 24, weight: .bold)).foregroundStyle(.white))
                .padding(.bottom, 14)
            Text(EmptyStateCopy.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.text)
                .padding(.bottom, 8)
            Text(EmptyStateCopy.body)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)
            if let controller {
                Button("接入第一个项目…") { controller.showOnboarding = true }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .padding(.bottom, 12)
                SetupCopyButton(text: controller.onboardingGuide.agentInstruction, label: "复制 Agent 接入指令")
                    .padding(.bottom, 14)
            }
            Text("登记不会启动服务。面板只记录经 DevPanel 启动的项目进程。")
                .font(.system(size: 12)).foregroundStyle(Theme.text2)
                .multilineTextAlignment(.center).padding(.bottom, 14)
            Button {
                editor?.openNew()
            } label: {
                Text(EmptyStateCopy.manualAdd).font(.system(size: 12.5))
            }
            .buttonStyle(.bordered)
            .help("手动添加项目")
        }
        .frame(maxWidth: 440)
        .padding(40)
    }
}

/// Never connected yet (or unauthorized) and nothing to show.
struct ConnectionProblemView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: model.connection.status == .unauthorized ? "lock.trianglebadge.exclamationmark" : "bolt.horizontal.circle")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(model.connection.status == .unauthorized ? "管理服务拒绝了认证信息" : "无法连接管理服务")
                .font(.title3.weight(.semibold))
            if let error = model.connection.lastError {
                Text(error.message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            Button("立即重试") { model.retryNow() }
        }
        .padding(40)
    }
}
