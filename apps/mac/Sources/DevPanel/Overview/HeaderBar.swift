import DevPanelKit
import SwiftUI

/// Compact window header: running count, search, add, ⋯.
/// Drawn in SwiftUI (the system title bar is hidden) so `--snapshot` captures it too.
struct HeaderBar: View {
    let model: AppModel
    @Bindable var prefs: ViewPreferences
    @Binding var query: String
    @Environment(AppController.self) private var app: AppController?
    @Environment(EditorPresenter.self) private var editor: EditorPresenter?
    @State private var creatingGroup = false
    @State private var showingResources = false

    /// Room for the traffic lights.
    static let leadingInset: CGFloat = 78
    static let height: CGFloat = 40

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                Text("D").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 23, height: 23).background(Theme.iconGradient, in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityHidden(true)
                Text("DevPanel").font(.system(size: 15, weight: .bold))
            }
            if model.connectionStatus != .connected || prefs.detailed {
                ConnectionStatusLabel(model: model)
            }
            Spacer(minLength: 12)
            if prefs.detailed {
                Button("返回总览") { prefs.detailed = false; model.select(nil) }.buttonStyle(.borderless)
            }
            SearchField(text: $query)
            Button {
                editor?.openNew()
            } label: {
                Text("＋ 添加项目")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.accent2)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!model.isConnected)
            .help("添加项目（⌘N）")
            Menu {
                if !prefs.detailed {
                    Button("详情视图") {
                        prefs.detailed = true
                    }
                }
                Button("DevPanel 自身资源…") { showingResources = true }
                Divider()
                Button("新建项目组…") { creatingGroup = true }
                let groups = prefs.organization.groups(in: model.projects)
                if !groups.isEmpty {
                    Menu("筛选项目组") {
                        Button("显示全部") { query = "" }
                        Divider()
                        ForEach(groups) { group in
                            Button(group.name) { query = "group:" + group.name }
                        }
                    }
                }
                Divider()
                Button("停止所有服务并退出管理服务…") { app?.requestShutdown() }.disabled(!model.isConnected || app?.shutdownBusy == true)
                Divider()
                Button("关于 DevPanel") {
                    NSApplication.shared.orderFrontStandardAboutPanel(nil)
                }
            } label: {
                Text("⋯").font(.system(size: 13)).foregroundStyle(Theme.text)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 28, height: 28)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.line2))
            .help("更多")
        }
        .padding(.leading, Self.leadingInset)
        .padding(.trailing, 14)
        .frame(height: Self.height)
        .background(WindowDragArea())
        .background(Theme.bar)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .sheet(isPresented: $creatingGroup) {
            ProjectGroupEditor(organization: prefs.organization, projects: model.projects)
        }
        .onChange(of: prefs.detailed) { _, detailed in
            if detailed, !model.hasInspectorSelection, let project = model.projects.first, let service = project.services.first {
                model.select(ServiceRef(project.id, service.id))
            }
        }
        .sheet(isPresented: $showingResources) {
            VStack(alignment: .trailing, spacing: 0) {
                ToolResourceDetails(readout: model.toolResources.currentReadout)
                Button("关闭") { showingResources = false }.keyboardShortcut(.cancelAction).padding(12)
            }
        }
        .onChange(of: prefs.organization.revealGeneration) { _, _ in query = "" }
    }
}

/// `⌕ 搜索项目或服务` (mockup `.search`).
struct SearchField: View {
    @Binding var text: String
    @Environment(AppController.self) private var app: AppController?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.text3)
            TextField("搜索项目、服务或分组", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($focused)
                .onChange(of: app?.overviewFocus) { _, _ in focused = true }
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.text3)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 180, height: 28)
        .background(Theme.graySoft, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(focused ? Theme.accent : Theme.line))
        .help("搜索项目、服务、分组、实例、目录或项目 ID；group:组名 和 instance:实例名 可精确筛选")
    }
}

/// Quiet running count while connected; connection problems replace it entirely.
struct ConnectionStatusLabel: View {
    let model: AppModel

    var body: some View {
        TimeCell(model: model, rules: model.connection.retryAt.map { [.countdown(until: $0)] } ?? [], freezesWhenStale: false) { now in
            let connection = model.connection
            let text = connection.summary(
                running: model.runningServiceCount,
                projectCount: model.projects.count, now: now)
            let color = Theme.color(for: connection.tone)
            HStack(spacing: 6) {
                if connection.status != .connected {
                    Image(systemName: connection.status == .connecting ? "arrow.triangle.2.circlepath" : "exclamationmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(color)
                        .accessibilityHidden(true)
                }
                Text(text)
                    .font(.system(size: 12.5))
                    .monospacedDigit()
                    .foregroundStyle(connection.status == .connected ? Theme.text2 : color)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .help(connection.status == .connected
                  ? "已连接管理服务 · 共 \(model.serviceCount) 个服务"
                  : "服务运行状态未知；连接恢复后更新")
        }
    }
}

/// ui-design v2 §7: "与管理服务的连接中断，下面是 hh:mm:ss 的状态，可能已过期；操作暂时不可用".
struct StaleBanner: View {
    let connection: ConnectionState

    var body: some View {
        HStack(spacing: 8) {
            Text("⚠ 与管理服务的连接中断")
                .fontWeight(.semibold)
                .foregroundStyle(Theme.amber)
            Text(StaleCopy.banner(syncedAt: connection.syncedAt))
                .foregroundStyle(Theme.text)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
        .background(Theme.amberSoft)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.amber.opacity(0.35)).frame(height: 1) }
    }
}
