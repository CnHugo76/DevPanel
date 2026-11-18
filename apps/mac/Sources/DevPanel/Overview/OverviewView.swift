import AppKit
import DevPanelKit
import SwiftUI

struct OverviewView: View {
    let model: AppModel
    let prefs: ViewPreferences
    let query: String
    let compact: Bool

    @Environment(EditorPresenter.self) private var editor: EditorPresenter?
    @State private var filter: OverviewStateFilter = .all
    @State private var forceStop: ForceStopTarget?
    @State private var diagnosis: OverviewDiagnosis?

    var body: some View {
        let sections = prefs.organization.sections(model.projects, query: query)
        let list = CompactProjectList(sections: sections, filter: filter)
        let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        GeometryReader { geo in
            let width = min(960, max(0, geo.size.width - (compact ? 28 : 64)))
            let layout = ColumnLayout.make(tableWidth: max(0, width - 24), compact: compact)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if !list.attention.isEmpty {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                heading("需要处理", count: list.attention.count)
                                ForEach(list.attention) { item in
                                    row(item, layout: layout, problem: item.firstProblem)
                                        .background(Theme.amberSoft.opacity(0.45))
                                        .background(Theme.card)
                                        .overlay(alignment: .leading) { Rectangle().fill(Theme.amber).frame(width: 3) }
                                        .clipShape(RoundedRectangle(cornerRadius: 9))
                                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.amber.opacity(0.32)))
                                        .id(item.id)
                                }
                            }
                        }
                        if sections.isEmpty {
                            Text(EmptyStateCopy.noMatch(query)).foregroundStyle(Theme.text3)
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    heading(list.attention.isEmpty ? "项目" : "其他项目", count: list.otherCount)
                                    Spacer()
                                    Picker("筛选项目状态", selection: $filter) {
                                        ForEach(OverviewStateFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                                    }.labelsHidden().fixedSize().controlSize(.small)
                                }
                                LazyVStack(spacing: 0) {
                                    ForEach(list.sections) { section in
                                        if section.id != list.sections.first?.id { Divider() }
                                        if section.group != nil {
                                            ProjectGroupHeader(organization: prefs.organization, section: section,
                                                projects: model.projects, searching: searching)
                                                .padding(.horizontal, 12).background(Theme.card2)
                                                .id(section.id)
                                        }
                                        if section.group == nil || searching || !prefs.organization.isCollapsed(section.id) {
                                            ForEach(section.projects) { item in
                                                if section.group != nil { Divider() }
                                                row(item, layout: layout).id(item.id)
                                            }
                                            if section.group != nil && section.members.isEmpty {
                                                Text("可拖入项目或在分组菜单中添加成员")
                                                    .font(.callout).foregroundStyle(Theme.text3).padding(8)
                                            }
                                        }
                                    }
                                    if list.otherCount == 0 && list.sections.isEmpty {
                                        Text("没有符合此状态的项目").font(.callout).foregroundStyle(Theme.text3).padding(14)
                                    }
                                }
                                .background(Theme.card)
                                .clipShape(RoundedRectangle(cornerRadius: 9))
                                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.line))
                            }
                        }
                        if !searching && !prefs.organization.groups(in: model.projects).isEmpty {
                            UngroupedDropArea(organization: prefs.organization, projects: model.projects)
                        }
                    }
                    .frame(width: width, alignment: .leading)
                    .padding(.vertical, compact ? 14 : 22)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: editor?.revealGeneration) { _, _ in
                    guard let id = editor?.revealProject else { return }
                    filter = .all
                    prefs.setCollapsed(id, false)
                    if let p = model.project(id), let g = prefs.organization.groupID(for: p), prefs.organization.isCollapsed(g) {
                        prefs.organization.toggleCollapsed(g)
                    }
                    Task { @MainActor in await Task.yield(); proxy.scrollTo(id, anchor: .top) }
                }
                .onChange(of: prefs.organization.revealGeneration) { _, _ in
                    guard let id = prefs.organization.revealGroup else { return }
                    filter = .all
                    Task { @MainActor in await Task.yield(); proxy.scrollTo(id, anchor: .top) }
                }
            }
        }
        .sheet(item: $diagnosis) { OverviewProblemSheet(model: model, diagnosis: $0) }
        .forceStopConfirmation(model: model, target: $forceStop)
    }

    private func heading(_ text: String, count: Int) -> some View {
        HStack(spacing: 7) {
            Text(text).font(.system(size: 14, weight: .semibold))
            Text(String(count)).font(.caption.monospacedDigit()).foregroundStyle(Theme.text2)
                .padding(.horizontal, 5).background(Theme.graySoft, in: RoundedRectangle(cornerRadius: 4))
        }.frame(minHeight: 24)
    }

    private func row(_ item: FilteredProject, layout: ColumnLayout, problem: OverviewProblem? = nil) -> some View {
        CompactProjectRow(model: model, prefs: prefs, item: item, search: query.trimmingCharacters(in: .whitespacesAndNewlines),
                          layout: layout, problem: problem, forceStop: { forceStop = $0 }, diagnose: { diagnosis = $0 })
    }
}

func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
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
