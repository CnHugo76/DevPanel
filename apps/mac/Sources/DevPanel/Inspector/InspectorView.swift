import DevPanelKit
import SwiftUI

/// Service details (ui-design v2 §4): header (dot, name, status, ■/▶ or 强制停止, ↻, ✕), meta
/// line, tab bar and the selected tab. Keeps the log session pointed at the viewed run.
struct InspectorView: View {
    let model: AppModel
    let ref: ServiceRef

    @State private var forceStop: ForceStopTarget?

    var body: some View {
        if let project = model.project(ref.projectId), let service = project.service(ref.serviceId) {
            VStack(alignment: .leading, spacing: 0) {
                InspectorHeader(
                    model: model, project: project, service: service,
                    forceStop: { forceStop = $0 })
                InspectorTabBar(model: model, ref: ref)
                tabContent(project, service)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.window)
            }
            .forceStopConfirmation(model: model, target: $forceStop)
            .task(id: LogKey(ref: ref, run: model.viewedRunId(for: ref))) {
                model.syncLogSession()
            }
            .task(id: RunsKey(service: service, connected: model.isConnected)) {
                await model.refreshRuns(ref)
            }
            .onChange(of: model.isConnected) { _, connected in
                if connected { model.inspector.logs.connectionRestored() }
            }
            .onChange(of: model.inspector.tab) { _, _ in model.syncLogSession() }
            .onChange(of: model.configs[ref.projectId]?.revision) { _, _ in model.prepareServiceTools(ref) }
            .onDisappear { model.syncLogSession() }
        }
    }

    @ViewBuilder
    private func tabContent(_ project: ProjectView, _ service: ServiceView) -> some View {
        switch model.inspector.tab {
        case .logs: LogsTab(model: model, ref: ref, project: project, service: service)
        case .options: OptionsTab(model: model, ref: ref)
        case .runs: RunsTab(model: model, ref: ref, project: project, service: service)
        case .command: CommandTab(model: model, ref: ref, project: project)
        case .git: GitTab(model: model, project: model.serviceToolProject(ref) ?? project)
        case .maven: MavenTab(model: model, project: model.serviceToolProject(ref) ?? project)
        }
    }

    private struct LogKey: Hashable {
        var ref: ServiceRef
        var run: RunID?
    }

    /// Refetch the run list when a run starts or ends.
    private struct RunsKey: Hashable {
        var current: RunID?
        var last: RunID?
        var lastEnded: Timestamp?
        var connected: Bool

        init(service: ServiceView, connected: Bool) {
            current = service.currentRun?.id
            last = service.lastRun?.id
            lastEnded = service.lastRun?.endedAt
            self.connected = connected
        }
    }
}

struct InspectorHeader: View {
    let model: AppModel
    let project: ProjectView
    let service: ServiceView
    let forceStop: (ForceStopTarget) -> Void

    @Environment(\.isStale) private var stale

    var body: some View {
        let actions = stale ? .none : service.availableActions
        let reason = stale ? Copy.staleReason : nil
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                ServiceIdentityMark(color: Theme.process(ProcessPalette.index(of: service.id, in: project)))
                Text(service.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                TimeCell(model: model, rules: service.statusRefresh) { now in StatusPill(label: service.status(now: now)) }
                ReadyBadge(ready: service.currentRun?.ready)
                Spacer(minLength: 4)
                if service.availableActions.forceStop {
                    // Stop timed out: "■" becomes the red "强制停止" (confirmed).
                    ForceStopButton(enabled: !stale) {
                        forceStop(ForceStopTarget(projectId: project.id, serviceIds: [service.id]))
                    }
                } else if service.state.isStartable {
                    IconButton(
                        symbol: "▶", role: .play, help: reason ?? "启动", enabled: actions.start,
                        pending: model.isPending(request(.start))
                    ) { run(.start) }
                } else {
                    IconButton(
                        symbol: "■", role: .stop, help: reason ?? "停止", enabled: actions.stop,
                        pending: model.isPending(request(.stop))
                    ) { run(.stop) }
                }
                IconButton(
                    symbol: "↻", help: reason ?? "重启", enabled: actions.restart,
                    pending: model.isPending(request(.restart))
                ) { run(.restart) }
                IconButton(symbol: "✕", help: "关闭详情") { model.select(nil) }
            }
            TimeCell(model: model, rules: service.uptimeRefresh) { now in Text(service.actorNote(now: now)).font(.system(size: 11)).foregroundStyle(Theme.text3) }
            SupervisionNote(model: model, project: project, service: service)
            InspectorMeta(model: model, project: project, service: service)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private func request(_ action: ActionKind) -> ActionRequest {
        ActionRequest(projectId: project.id, serviceIds: [service.id], action: action)
    }

    private func run(_ action: ActionKind) {
        let r = request(action)
        Task { await model.runAction(r) }
    }
}

private struct InspectorMeta: View {
    let model: AppModel
    let project: ProjectView
    let service: ServiceView
    var body: some View {
        TimeCell(model: model, rules: service.uptimeRefresh) { now in
            Text(meta(now: now))
                .font(.system(size: 12))
                .foregroundStyle(Theme.text3)
                .monospacedDigit()
                .lineLimit(2)
                .textSelection(.enabled)
                .help(memory.help ?? "")
        }
    }
    /// `reg-radar · 运行 r_…7VV5Q3 · PID 41823 · 1h12m · CPU 128.0% · 内存 1.12 GiB · 5 个进程`
    private func meta(now: Date) -> String {
        var parts = [project.name]
        guard let run = service.currentRun else {
            parts.append("未运行")
            return parts.joined(separator: " · ")
        }
        parts.append("运行 \(Format.shortRunId(run.id))")
        if let pid = run.pid { parts.append("PID \(pid)") }
        parts.append(Metrics.uptime(service, now: now).text)
        let sample = Metrics.currentSample(service, model.serviceStats(project.id, service.id))
        parts.append("CPU \(Metrics.cpu(sample?.sample, active: true).text)")
        parts.append("内存 \(memory.text)")
        if let n = sample?.processCount { parts.append("\(n) 个进程") }
        return parts.joined(separator: " · ")
    }

    private var memory: MetricText {
        let sample = Metrics.currentSample(service, model.serviceStats(project.id, service.id))
        return Metrics.memory(sample?.sample, active: service.currentRun != nil)
    }
}

/// Base service tabs followed by tools belonging to this engineering directory.
struct InspectorTabBar: View {
    let model: AppModel
    let ref: ServiceRef

    var body: some View {
        HStack(spacing: 2) {
            ForEach(model.serviceTabs(ref)) { tab in
                let on = model.inspector.tab == tab
                Button {
                    model.selectServiceTab(tab, for: ref)
                } label: {
                    Text(tab.title)
                        .font(.system(size: 12.5, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Theme.text : Theme.text2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(on ? Theme.accent : .clear).frame(height: 2)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

/// A titled block of the inspector tabs (运行记录, 命令与环境).
struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.text3)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Monospaced, selectable, wrapped text on the window background (commands).
struct CodeBlock: View {
    let text: String
    var muted = false

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(muted ? Theme.text2 : Theme.text)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.window, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.line))
    }
}
