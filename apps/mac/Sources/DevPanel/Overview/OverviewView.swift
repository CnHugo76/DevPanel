import AppKit
import DevPanelKit
import SwiftUI

/// The overview: every project as a card, in registration order (ui-design v2 §3).
struct OverviewView: View {
    let model: AppModel
    let prefs: ViewPreferences
    let query: String
    /// The inspector is open.
    let compact: Bool

    @Environment(EditorPresenter.self) private var editor: EditorPresenter?
    @State private var forceStop: ForceStopTarget?
    @Environment(\.isStale) private var stale

    /// main padding 20×2 + card border 1×2 + table margin 10×2 + table border 1×2.
    static let tableInset: CGFloat = 64

    var body: some View {
        let filtered = OverviewFilter.apply(model.projects, query: query)
        GeometryReader { geo in
            let layout = ColumnLayout.make(tableWidth: Double(geo.size.width - Self.tableInset), compact: compact)
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(filtered) { item in
                        ProjectCard(
                            model: model, prefs: prefs, item: item, layout: layout,
                            forceStop: { forceStop = $0 }).id(item.project.id)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 28)
                if filtered.isEmpty {
                    Text(EmptyStateCopy.noMatch(query.trimmingCharacters(in: .whitespaces)))
                        .foregroundStyle(Theme.text3)
                        .padding(.top, 60)
                }
            }
            .onChange(of: editor?.revealGeneration) { _, _ in
                if let id = editor?.revealProject {
                    prefs.setCollapsed(id, false)
                    Task { @MainActor in
                        await Task.yield()
                        proxy.scrollTo(id, anchor: .top)
                    }
                }
            }
            }
        }
        .forceStopConfirmation(model: model, target: $forceStop)
    }
}

// MARK: - Project card

struct ProjectCard: View {
    let model: AppModel
    let prefs: ViewPreferences
    let item: FilteredProject
    let layout: ColumnLayout
    let forceStop: (ForceStopTarget) -> Void

    @Environment(AppController.self) private var controller: AppController?
    @Environment(\.isStale) private var stale
    @Environment(OptionPresenter.self) private var options: OptionPresenter?
    @Environment(EditorPresenter.self) private var editor: EditorPresenter?

    @State private var showPolicy = false
    private var project: ProjectView { item.project }

    var body: some View {
        let collapsed = prefs.isCollapsed(project.id)
        let params = model.params(project.id)
        VStack(alignment: .leading, spacing: 0) {
            header(collapsed: collapsed)

            if layout.compact, project.services.contains(where: { $0.currentRun != nil }) {
                HStack {
                    ProjectTotals(model: model, projectId: project.id)
                    Spacer(minLength: 0)
                }.padding(.horizontal, 14).padding(.bottom, 10)
            }
            if let result = model.actionResults[project.id] {
                ResultBar(model: model, project: project, result: result)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
            if !collapsed {
                if !params.isEmpty {
                    ProjectOptionGroups(model: model, project: project, prefs: prefs)
                        .padding(.leading, 40)
                        .padding(.trailing, 14)
                        .padding(.bottom, 14)
                }
                QuickActionsRow(model: model, project: project)
                ServiceTable(
                    model: model, project: project, services: item.services, params: params,
                    layout: layout, forceStop: forceStop)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
        }
        .task(id: project.services.compactMap { $0.currentRun?.id }.joined(separator: ",") + String(model.isConnected)) {
            for service in project.services {
                if let run = service.currentRun { await model.loadRunDetail(run.id) }
            }
        }
        .sheet(isPresented: $showPolicy) { PolicySheet(model: model, project: project) }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line))
    }

    private func header(collapsed: Bool) -> some View {
        let actions = stale ? .none : project.availableActions
        return HStack(spacing: 10) {
            Button {
                prefs.toggleCollapsed(project.id)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.text3)
                        .frame(width: 16, height: 20)
                    Text(project.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .layoutPriority(1)
                    CountBadge(label: project.badge())
                    if !layout.compact {
                        Text(Format.tildePath(project.root))
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Theme.text3)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(project.root)
                    }
                    Spacer(minLength: 8)
                    if !layout.compact, project.services.contains(where: { $0.currentRun != nil }) {
                        ProjectTotals(model: model, projectId: project.id)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(collapsed ? "展开项目" : "折叠项目")
            .accessibilityLabel(project.name)
            .accessibilityValue(collapsed ? "已折叠" : "已展开")
            .accessibilityIdentifier("project-disclosure-" + project.id)
            HStack(spacing: 0) {
                IconButton(
                    symbol: "▶", role: .play, help: stale ? Copy.staleReason : "启动全部", enabled: actions.start,
                    pending: model.isPending(request(.start))
                ) { run(.start) }
                IconButton(
                    symbol: "■", role: .stop, help: stale ? Copy.staleReason : "停止全部", enabled: actions.stop,
                    pending: model.isPending(request(.stop))
                ) { run(.stop) }
                IconButton(
                    symbol: "↻", help: stale ? Copy.staleReason : "重启", enabled: actions.restart,
                    pending: model.isPending(request(.restart))
                ) { run(.restart) }
                MoreMenu {
                    if project.maven != nil { Button("Maven…") { model.selectProject(project.id, tab: .maven) }.disabled(stale) }
                    Button("项目详情…") { model.selectProject(project.id) }
                    Button("添加选项…") { options?.add(project.id) }.disabled(stale)
                    Button("AI 权限…") { showPolicy = true }.disabled(stale)
                    Button("编辑项目…") { editor?.edit(project.id) }
                        .disabled(stale)
                    Button("复制项目 ID") { copy(project.id) }
                    Button("在 Finder 中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.root)])
                    }
                    if project.availableActions.forceStop {
                        Divider()
                        Button("强制停止…") { forceStop(ForceStopTarget(projectId: project.id, serviceIds: nil)) }
                            .disabled(stale)
                    }
                    Divider()
                    Button("移除项目…") { editor?.remove(project.id) }
                        .disabled(stale)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private func request(_ action: ActionKind) -> ActionRequest {
        ActionRequest(projectId: project.id, action: action)
    }

    private func run(_ action: ActionKind) {
        let r = request(action)
        Task { await model.runAction(r) }
    }
}

func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

/// `CPU 132.4% · 内存 1.31 GiB` (mockup `.psum`).
struct ProjectTotals: View {
    let model: AppModel
    let projectId: ProjectID
    @Environment(\.isStale) private var stale

    var body: some View {
        let sample = model.projectStats(projectId)?.total
        let cpu = Metrics.cpu(sample, active: true)
        let mem = Metrics.memory(sample, active: true)
        HStack(spacing: 4) {
            Text("CPU").foregroundStyle(Theme.text2)
            value(cpu).help(cpu.help ?? "")
            Text("· 内存").foregroundStyle(Theme.text2)
            value(mem).help(mem.help ?? "")
            if cpu.partial || mem.partial {
                Text("部分").font(.system(size: 10)).foregroundStyle(Theme.amber)
            }
        }
        .font(.system(size: 12))
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
        .staleDimmed()
    }

    private func value(_ m: MetricText) -> some View {
        Text(m.text)
            .fontWeight(m.kind == .value ? .semibold : .regular)
            .foregroundStyle(m.kind == .value && !stale ? Theme.text : Theme.text3)
    }
}

// MARK: - Result bar

struct ResultBar: View {
    let model: AppModel
    let project: ProjectView
    let result: ActionResult

    var body: some View {
        if let summary {
            let c = colors(summary.tone)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                (Text(summary.title + "：").fontWeight(.semibold).foregroundColor(c.fg)
                    + Text(itemsText(summary)).foregroundColor(Theme.text)
                    + Text(summary.hint.map { " " + $0 } ?? "").foregroundColor(Theme.text2)
                    + Text(summary.sourceNote.map { "（\($0)）" } ?? "").foregroundColor(Theme.text3))
                    .font(.system(size: 12.5))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                Button {
                    model.dismissResult(project.id)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.text3)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("关闭")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(c.bg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(c.border))
            .accessibilityElement(children: .combine)
        }
    }

    private var summary: OperationSummary? {
        if let error = result.error { return .rejected(error) }
        guard let op = model.finishedOperation(for: project.id) else { return nil }
        return op.summary { id in project.service(id)?.name ?? id }
    }

    private func itemsText(_ s: OperationSummary) -> String {
        s.items.map { $0.name.isEmpty ? $0.text : "\($0.name) \($0.text)" }.joined(separator: " · ")
    }

    private func colors(_ tone: OperationSummary.Tone) -> (fg: Color, bg: Color, border: Color) {
        switch tone {
        case .ok: Theme.colors(.green)
        case .warn: Theme.colors(.amber)
        case .bad: Theme.colors(.red)
        }
    }
}

// MARK: - Flow layout

/// Wraps children onto new lines (option chips).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.indices {
                let size = itemSize(subviews[i], width: bounds.width)
                subviews[i].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for i in subviews.indices {
            let size = itemSize(subviews[i], width: width)
            // A scheduled label can be absent before its threshold; it occupies no gap.
            guard size != .zero else { continue }
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row(indices: [], y: current.y + current.height + spacing)
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(i)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }

    private func itemSize(_ subview: LayoutSubview, width: CGFloat) -> CGSize {
        let ideal = subview.sizeThatFits(.unspecified)
        return subview.sizeThatFits(ProposedViewSize(width: min(ideal.width, width), height: nil))
    }
}
