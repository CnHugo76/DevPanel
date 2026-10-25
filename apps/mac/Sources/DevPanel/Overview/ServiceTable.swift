import AppKit
import DevPanelKit
import SwiftUI

/// Service table of one project card: fixed column widths shared by every card, so columns line
/// up across cards (not SwiftUI `Table`).
struct ServiceTable: View {
    let model: AppModel
    let project: ProjectView
    let services: [ServiceView]
    let params: [ParamConfig]
    let layout: ColumnLayout
    let forceStop: (ForceStopTarget) -> Void

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            ForEach(Array(services.enumerated()), id: \.element.id) { index, service in
                if index > 0 { Rectangle().fill(Theme.line).frame(height: 1) }
                ServiceRow(
                    model: model, project: project, service: service, params: params, layout: layout,
                    forceStop: forceStop)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.line))
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            ForEach(layout.columns, id: \.self) { column in
                Text(column.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .frame(width: CGFloat(layout.width(column) ?? 0), alignment: column.trailing ? .trailing : .leading)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card2)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

struct ServiceRow: View {
    let model: AppModel
    let project: ProjectView
    let service: ServiceView
    let params: [ParamConfig]
    let layout: ColumnLayout
    let forceStop: (ForceStopTarget) -> Void

    @Environment(\.isStale) private var stale
    @Environment(\.hoverEnabled) private var hoverEnabled
    @State private var hover = false

    private var ref: ServiceRef { ServiceRef(project.id, service.id) }
    private var selected: Bool { model.selection == ref }
    private var narrowStatus: Bool { (layout.width(.status) ?? 112) < 112 }

    var body: some View {
        let sample = Metrics.currentSample(service, model.serviceStats(project.id, service.id))
        let active = service.currentRun != nil
        HStack(spacing: 0) {
            ForEach(layout.columns, id: \.self) { column in
                cell(column, sample: sample, active: active)
                    .padding(.leading, column == .status && narrowStatus ? 4 : 10)
                    .padding(.trailing, column == .actions || (column == .status && narrowStatus) ? 4 : 10)
                    .frame(width: CGFloat(layout.width(column) ?? 0), alignment: column.trailing ? .trailing : .leading)
                    .clipped()
            }
        }
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(selected ? Theme.sel : hover ? Theme.graySoft : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 && hoverEnabled }
        .onTapGesture {
            // Double-click = "打开日志" (the first click already selected the row).
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                model.openLogs(ref)
            } else {
                model.select(selected ? nil : ref)
            }
        }
        .contextMenu {
            Button(service.locked == true ? "解锁" : "锁定") { Task { await model.setServiceLocked(ref, locked: service.locked != true) } }.disabled(stale)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func cell(_ column: OverviewColumn, sample: ServiceStats?, active: Bool) -> some View {
        switch column {
        case .service: nameCell
        case .command: commandCell
        case .status:
            VStack(alignment: .leading, spacing: 3) {
                TimeCell(model: model, rules: service.statusRefresh) { now in
                    let full = service.status(now: now)
                    let parts = full.text.components(separatedBy: " · ")
                    VStack(alignment: .leading, spacing: 2) {
                        StatusPill(label: StatusLabel(glyph: full.glyph, text: narrowStatus ? (parts.first ?? full.text) : full.text, tone: full.tone), compact: narrowStatus)
                        if narrowStatus, parts.count > 1 {
                            Text(parts.dropFirst().joined(separator: " · ")).font(.system(size: 10.5)).foregroundStyle(Theme.text3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }.help(full.text)
                }
                ReadyBadge(ready: service.currentRun?.ready)
            }
        case .ports: portsCell(PortCell.make(sample?.listening, active: active))
        case .uptime:
            TimeCell(model: model, rules: service.uptimeRefresh) { now in MetricCell(metric: Metrics.uptime(service, now: now)) }
        case .cpu: MetricCell(metric: Metrics.cpu(sample?.sample, active: active))
        case .memory: MetricCell(metric: Metrics.memory(sample?.sample, active: active))
        case .actions: actionsCell
        }
    }

    private var nameCell: some View {
        let paramChanged = model.hasPendingParams(project.id, service.id)
        return HStack(spacing: 9) {
            ServiceIdentityMark(color: Theme.process(ProcessPalette.index(of: service.id, in: project)))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                if service.locked == true { Image(systemName: "lock.fill").help("已锁定：AI 不能操作此服务") }
                Text(service.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                }
                HStack(spacing: 10) {
                    ForEach(model.serviceTabs(ref).filter { $0 == .git || $0 == .maven }) { tab in
                        Button(tab.title) { model.selectServiceTab(tab, for: ref) }
                            .buttonStyle(.plain).foregroundStyle(Theme.accent2)
                            .help("打开 " + service.name + " 的 " + tab.title)
                    }
                }.font(.system(size: 11))
                SupervisionNote(model: model, project: project, service: service)
                TimeCell(model: model, rules: service.uptimeRefresh) { now in Text(service.actorNote(now: now)).font(.system(size: 10)).foregroundStyle(Theme.text3).lineLimit(1) }
                TimeCell(model: model, rules: service.noteRefresh) { now in
                    if let note = service.note(paramChanged: paramChanged, now: now) {
                        Text(note.text)
                            .font(.system(size: 11))
                            .foregroundStyle(noteColor(note.tone))
                            .lineLimit(1)
                            .help(note.text)
                    }
                }
            }
        }
        .help(service.name)
    }

    private func noteColor(_ tone: ServiceNote.Tone) -> Color {
        switch tone {
        case .warning: Theme.amber
        case .negative: Theme.red
        case .muted: Theme.text3
        }
    }

    @ViewBuilder private var commandCell: some View {
        if let config = model.serviceConfig(project.id, service.id) {
            let template = CommandText.join(config.command)
            Text(template)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.text2)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(commandHelp(config, template: template))
        } else {
            Text("—").foregroundStyle(Theme.text3).help("配置读取中")
        }
    }

    private func commandHelp(_ config: ServiceConfig, template: String) -> String {
        guard CommandText.hasPlaceholders(config.command) else { return template }
        let preview = CommandText.join(CommandText.substitute(config.command, params: params))
        return "\(template)\n\n按当前选项值：\n\(preview)"
    }

    @ViewBuilder private func portsCell(_ cell: PortCell) -> some View {
        switch cell {
        case .ports(let chips):
            // All chips if they fit; then with "局域网" shortened to a dot; then the first ones
            // plus "+N" (every port is in the help).
            ViewThatFits(in: .horizontal) {
                chipRow(chips, count: chips.count, short: false)
                chipRow(chips, count: chips.count, short: true)
                ForEach(Array(stride(from: chips.count - 1, through: 1, by: -1)), id: \.self) { n in
                    chipRow(chips, count: n, short: true)
                }
            }
            .staleDimmed()
        default:
            Text("—")
                .foregroundStyle(Theme.text3)
                .help(cell.help ?? "")
        }
    }

    private func chipRow(_ chips: [PortChip], count: Int, short: Bool) -> some View {
        HStack(spacing: 4) {
            ForEach(chips.prefix(count)) { PortChipView(chip: $0, shortLAN: short) }
            if count < chips.count {
                Text("+\(chips.count - count)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3)
                    .help(chips.map { String($0.port) }.joined(separator: "、"))
            }
        }
        .fixedSize()
    }

    private var actionsCell: some View {
        let actions = stale ? .none : service.availableActions
        let reason = stale ? Copy.staleReason : nil
        let ids = [service.id]
        return HStack(spacing: 2) {
            if service.availableActions.forceStop {
                ForceStopButton(enabled: !stale) {
                    forceStop(ForceStopTarget(projectId: project.id, serviceIds: ids))
                }
            } else if service.state.isStartable {
                IconButton(
                    symbol: "▶", role: .play, size: 26, help: reason ?? "启动", enabled: actions.start,
                    pending: model.isPending(request(.start))
                ) { run(.start) }
            } else {
                IconButton(
                    symbol: "■", role: .stop, size: 26, help: reason ?? "停止", enabled: actions.stop,
                    pending: model.isPending(request(.stop))
                ) { run(.stop) }
            }
            if !service.availableActions.forceStop {
                IconButton(
                    symbol: "↻", size: 26, help: reason ?? "重启", enabled: actions.restart,
                    pending: model.isPending(request(.restart))
                ) { run(.restart) }
            }
            MoreMenu(size: service.availableActions.forceStop ? 22 : 26) {
                Button("显示详情") { model.select(ref) }
                Button("打开日志") { model.openLogs(ref) }
                Button(service.locked == true ? "解锁" : "锁定") { Task { await model.setServiceLocked(ref, locked: service.locked != true) } }.disabled(stale)
                Button("复制服务 ID") { copy(service.id) }
            }
        }
    }

    private func request(_ action: ActionKind) -> ActionRequest {
        ActionRequest(projectId: project.id, serviceIds: [service.id], action: action)
    }

    private func run(_ action: ActionKind) {
        let r = request(action)
        Task { await model.runAction(r) }
    }
}
