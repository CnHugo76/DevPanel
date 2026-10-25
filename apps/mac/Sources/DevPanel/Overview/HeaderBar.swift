import DevPanelKit
import SwiftUI

/// The window's title bar (52 pt, mockup `.tb`): brand, connection status, search, add, ⋯.
/// Drawn in SwiftUI (the system title bar is hidden) so `--snapshot` captures it too.
struct HeaderBar: View {
    let model: AppModel
    @Bindable var prefs: ViewPreferences
    @Binding var query: String
    @Environment(AppController.self) private var app: AppController?
    @Environment(EditorPresenter.self) private var editor: EditorPresenter?

    /// Room for the traffic lights.
    static let leadingInset: CGFloat = 78
    static let height: CGFloat = 52

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.iconGradient)
                .frame(width: 26, height: 26)
                .overlay(Text("D").font(.system(size: 13, weight: .bold)).foregroundStyle(.white))
                .accessibilityHidden(true)
            Text("DevPanel")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.text)
            ConnectionStatusLabel(model: model)
            Spacer(minLength: 12)
            Picker("显示模式", selection: $prefs.detailed) {
                Text("总览").tag(false)
                Text("详情").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 112)
            .onChange(of: prefs.detailed) { _, detailed in
                if detailed, model.selection == nil,
                   let project = model.projects.first, let service = project.services.first {
                    model.select(ServiceRef(project.id, service.id))
                }
            }
            SearchField(text: $query)
            Button {
                editor?.openNew()
            } label: {
                Text("＋ 添加项目")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!model.isConnected)
            .help("添加项目（⌘N）")
            Menu {
                let groups = Array(Set(model.projects.compactMap { $0.instance?.group })).sorted()
                if !groups.isEmpty {
                    Menu("筛选实例组") {
                        Button("显示全部") { query = "" }
                        Divider()
                        ForEach(groups, id: \.self) { group in
                            Button(group) { query = "group:" + group }
                        }
                    }
                    Divider()
                }
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
            TextField("搜索项目、服务或实例", text: $text)
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
        .help("搜索项目、服务、实例、目录或项目 ID；group:组名 和 instance:实例名 可精确筛选")
    }
}

/// `● 已连接 · 4/7 服务运行中`
struct ConnectionStatusLabel: View {
    let model: AppModel

    var body: some View {
        TimeCell(model: model, rules: model.connection.retryAt.map { [.countdown(until: $0)] } ?? [], freezesWhenStale: false) { now in
            let connection = model.connection
            let text = connection.summary(
                running: model.runningServiceCount, total: model.serviceCount,
                projectCount: model.projects.count, now: now)
            let color = Theme.color(for: connection.tone)
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(text)
                    .font(.system(size: 12.5))
                    .monospacedDigit()
                    .foregroundStyle(connection.status == .connected ? Theme.text2 : color)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
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
