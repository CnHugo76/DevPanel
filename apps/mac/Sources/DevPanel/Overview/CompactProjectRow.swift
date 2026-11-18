import AppKit
import DevPanelKit
import SwiftUI

struct CompactProjectRow: View {
    let model: AppModel
    let prefs: ViewPreferences
    let item: FilteredProject
    let search: String
    let layout: ColumnLayout
    let problem: OverviewProblem?
    let forceStop: (ForceStopTarget) -> Void
    let diagnose: (OverviewDiagnosis) -> Void

    @Environment(\.isStale) private var stale
    @Environment(OptionPresenter.self) private var options: OptionPresenter?
    @Environment(EditorPresenter.self) private var editor: EditorPresenter?

    @State private var showPolicy = false
    private var project: ProjectView { item.project }

    @State private var collapsedSearch: String?
    @State private var digest: LogDigest?
    private var showMetrics: Bool { prefs.metricProjects.contains(project.id) }

    private var serviceMatch: Bool {
        guard !search.isEmpty else { return false }
        let group = prefs.organization.groupID(for: project).flatMap { id in
            prefs.organization.groups(in: model.projects).first(where: { $0.id == id })?.name
        }
        let identifiers = [project.name, project.root, project.id, group ?? "", project.instance?.name ?? ""]
        return !identifiers.contains { $0.localizedCaseInsensitiveContains(search) }
            && item.services.contains { $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search) }
    }

    private var collapsed: Bool { serviceMatch ? collapsedSearch == search : prefs.isCollapsed(project.id) }

    private var evidenceRunID: RunID? {
        guard model.isConnected, let problem, problem.isFailure else { return nil }
        return problem.runID
    }

    private func issueText(_ problem: OverviewProblem) -> String {
        guard problem.isFailure else { return problem.summary }
        return "运行失败 · " + (problem.evidence(in: digest) ?? problem.summary)
    }

    private var identity: String? {
        if let instance = project.instance { return instance.displayText }
        if problem != nil, let groupID = prefs.organization.groupID(for: project),
           let group = prefs.organization.groups(in: model.projects).first(where: { $0.id == groupID }),
           !model.projects.contains(where: { $0.id != project.id && $0.name == project.name }) {
            return group.name
        }
        let peers = model.projects.filter { $0.name == project.name }
        guard peers.count > 1 else { return nil }
        if peers.filter({ $0.root == project.root }).count > 1 { return project.id }
        let root = URL(fileURLWithPath: project.root)
        let parent = root.deletingLastPathComponent().lastPathComponent
        if !parent.isEmpty && peers.filter({ URL(fileURLWithPath: $0.root).deletingLastPathComponent().lastPathComponent == parent }).count == 1 {
            return parent + "/"
        }
        return Format.tildePath(project.root)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let result = model.actionResults[project.id] {
                ResultBar(model: model, project: project, result: result)
                    .padding(.horizontal, 12).padding(.bottom, 6)
            }
            if !collapsed {
                Divider()
                if showMetrics {
                    VStack(alignment: .leading, spacing: 8) {
                        ProjectIdentityCaption(project: project)
                        if project.services.contains(where: { $0.currentRun != nil }) {
                            ResourceUsageLabel { model.projectStats(project.id)?.total }
                        }
                        if !model.params(project.id).isEmpty {
                            ProjectOptionGroups(model: model, project: project, prefs: prefs)
                        }
                        QuickActionsRow(model: model, project: project)
                        ServiceTable(model: model, project: project, services: item.services,
                            params: model.params(project.id), layout: layout, forceStop: forceStop)
                    }
                    .padding(10)
                    .task(id: project.services.compactMap { $0.currentRun?.id }) {
                        for service in project.services {
                            if let run = service.currentRun { await model.loadRunDetail(run.id) }
                        }
                    }
                } else {
                    ForEach(item.services) { service in
                        ServiceRow(model: model, project: project, service: service, params: [],
                                   layout: layout, forceStop: forceStop, simple: true)
                    }
                }
            }
        }
        .onChange(of: search) { collapsedSearch = nil }
        .sheet(isPresented: $showPolicy) { PolicySheet(model: model, project: project) }
        .task(id: evidenceRunID) {
            guard let id = evidenceRunID, let client = model.client else { return }
            let result = try? await client.digest(id)
            guard !Task.isCancelled, result?.runId == id else { return }
            digest = result
        }
    }

    private func show(_ problem: OverviewProblem) {
        diagnose(OverviewDiagnosis(projectName: project.name, problem: problem,
            digest: digest?.runId == problem.runID ? digest : nil))
    }

    private var header: some View {
        HStack(spacing: 9) {
            ArrangementHandle(value: .project(project.id), label: "拖动项目 " + project.name,
                              symbol: problem == nil ? "folder" : "exclamationmark.triangle")
                .foregroundStyle(problem == nil ? Theme.accent2 : Theme.amber)
                .frame(width: 29, height: 29)
                .background(problem == nil ? Theme.accentSoft : Theme.amberSoft, in: RoundedRectangle(cornerRadius: 7))
            Button {
                if serviceMatch { collapsedSearch = collapsed ? nil : search }
                else { prefs.toggleCollapsed(project.id) }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(project.name).font(.system(size: 14, weight: .semibold)).lineLimit(1).layoutPriority(1)
                        if let identity {
                            Text(identity).font(.caption.monospaced()).foregroundStyle(Theme.text2)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.text3)
                    }
                    if let problem {
                        Text(problem.serviceName + " · " + issueText(problem))
                            .font(.caption).foregroundStyle(Theme.amber).lineLimit(2)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .help(project.root + "\n" + project.id)
                .accessibilityValue(collapsed ? "已折叠" : "已展开")
                .accessibilityIdentifier("project-disclosure-" + project.id)
            if let problem {
                let issues = item.services.compactMap { OverviewProblem(projectID: project.id, service: $0) }
                if issues.count > 1 {
                    Menu("查看异常（\(issues.count)）") {
                        ForEach(issues) { issue in
                            Button(issue.serviceName + " · " + issue.summary) { show(issue) }
                        }
                    }.fixedSize().disabled(stale)
                } else {
                    Button("查看错误") { show(problem) }.disabled(stale)
                        .accessibilityIdentifier("overview-error-" + project.id)
                }
            } else {
                let badge = project.badge()
                Label(badge.text, systemImage: "circle.fill")
                    .labelStyle(OverviewStatusStyle()).foregroundStyle(badge.glyph == .running ? Theme.green : Theme.colors(badge.tone).fg)
                    .staleDimmed().frame(minWidth: layout.compact ? 62 : 110, alignment: .leading)
                ProjectPrimaryAction(model: model, project: project, links: prefs.serviceLinks)
                    .frame(width: 82, alignment: .trailing)
            }
            more
        }
        .controlSize(.small).padding(.horizontal, 13)
        .frame(minHeight: problem == nil ? 45 : 59)
        .modifier(ArrangementDrop { value, after in
            switch value {
            case .project(let id):
                guard id != project.id, model.projects.contains(where: { $0.id == id }) else { return false }
                prefs.organization.placeProject(id, beside: project.id, after: after, projects: model.projects)
                return true
            case .group(let id):
                guard prefs.organization.groupID(for: project) == nil else { return false }
                prefs.organization.placeSection(id, beside: ProjectOrganization.projectSectionID(project.id), after: after, projects: model.projects)
                return true
            case .service: return false
            }
        })
    }

    private var more: some View {
        MoreMenu(help: project.name + " · 更多操作") {
            ForEach([ActionKind.start, .stop, .restart], id: \.rawValue) { action in
                let request = ActionRequest(projectId: project.id, action: action)
                Button(action == .start ? "启动全部服务" : action == .stop ? "停止全部服务" : "重启项目") {
                    Task { await model.runAction(request) }
                }.disabled(stale || model.isPending(request) || !canRun(action))
            }
            if !project.actions.isEmpty {
                Menu("快捷操作") {
                    ForEach(project.actions) { action in
                        Button(action.name) { model.requestQuickAction(project.id, actionId: action.id) }
                    }
                }.disabled(stale)
            }
            Button(showMetrics && !collapsed ? "收起运行指标" : "查看运行指标与选项") {
                if showMetrics && !collapsed { prefs.metricProjects.remove(project.id) }
                else { prefs.metricProjects.insert(project.id) }
                collapsedSearch = nil
                prefs.setCollapsed(project.id, false)
            }
            Divider()
            ProjectArrangementMenu(organization: prefs.organization, project: project, projects: model.projects)
            Divider()
            if project.maven != nil { Button("Maven…") { model.selectProject(project.id, tab: .maven) }.disabled(stale) }
            Button("项目详情…") { model.selectProject(project.id) }
            Button("添加选项…") { options?.add(project.id) }.disabled(stale)
            Button("AI 权限…") { showPolicy = true }.disabled(stale)
            Button("编辑项目…") { editor?.edit(project.id) }
                .disabled(stale)
            Button("导出共享配置…") { editor?.portable(.export(project.id)) }.disabled(stale)
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

    private func canRun(_ action: ActionKind) -> Bool {
        let available = project.availableActions
        return switch action {
        case .start: available.start
        case .stop: available.stop
        case .restart: available.restart
        default: false
        }
    }
}

private struct OverviewStatusStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 6))
            configuration.title.font(.system(size: 12)).lineLimit(1)
        }
    }
}
