import DevPanelKit
import SwiftUI

/// "运行记录" (ui-design v2 §4): the last `runsKeptPerService` runs with times, how they ended,
/// the param values each one actually used, and the substituted command. A card opens that
/// run's log.
struct RunsTab: View {
    let model: AppModel
    let ref: ServiceRef
    let project: ProjectView
    let service: ServiceView

    var body: some View {
        let runs = model.runs(for: ref)
        Group {
            if runs.isEmpty {
                Text("该服务还没有运行记录。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.text2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(Array(runs.enumerated()), id: \.element.id) { index, run in
                            RunCard(
                                model: model, ref: ref, run: run, index: index,
                                isCurrent: run.id == service.currentRun?.id,
                                detail: model.inspector.runDetails[run.id])
                        }
                        Text("保留最近 \(model.runsKept) 次运行，更早的运行连同日志已删除。")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.text3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
            }
        }
        .task(id: runs.map { "\($0.id)|\($0.state.rawValue)|\($0.endedAt ?? "")" }) {
            for run in runs {
                await model.loadRunDetail(run.id, force: run.endedAt == nil)
            }
        }
    }
}

struct RunCard: View {
    let model: AppModel
    let ref: ServiceRef
    let run: RunSummary
    let index: Int
    let isCurrent: Bool
    let detail: RunDetail?

    @Environment(\.isStale) private var stale
    @Environment(\.hoverEnabled) private var hoverEnabled
    @State private var hover = false

    var body: some View {
        let viewed = model.viewedRunId(for: ref) == run.id
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(RunLabels.title(index: index, isCurrent: isCurrent))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(Format.shortRunId(run.id))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.text3)
                    .textSelection(.enabled)
                    .help(run.id)
                RunStatePill(run: run)
                Spacer(minLength: 4)
                Button {
                    model.showRunLog(run.id, of: ref)
                } label: {
                    Text(viewed ? "查看日志 →" : "查看这次的日志 →")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.accent2)
                }
                .buttonStyle(.plain)
                .help("在日志标签中查看这次运行")
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
                timeRow("开始", rules: [.days([Timestamps.date(run.startedAt)].compactMap { $0 })]) { now in
                    Timestamps.date(run.startedAt).map { Format.dateTime($0, now: now) } ?? "—"
                }
                timeRow("结束", rules: [.days([Timestamps.date(run.endedAt)].compactMap { $0 })]) { now in
                    Timestamps.date(run.endedAt).map { Format.dateTime($0, now: now) } ?? (isCurrent ? "仍在运行" : "—")
                }
                timeRow("时长", rules: run.endedAt == nil ? Timestamps.date(run.startedAt).map { [.duration(since: $0)] } ?? [] : []) { now in
                    run.duration(now: now).map(Format.duration) ?? "—"
                }
                if let exit = run.exit {
                    row("结束方式", exit.summary, tone: run.state == .failed ? Theme.red : Theme.text)
                }
                if let pid = run.pid { row("PID", String(pid)) }
                row("发起方", run.startedBy?.sourceLabel ?? "未知")
                if let actor = run.exit?.requestedBy { row("停止方", actor.sourceLabel) }
                if let ready = run.ready, ready.label != nil { row("就绪", ready.explanation) }
                row("配置版本", "第 \(run.configRevision) 版")
            }
            .font(.system(size: 12))
            .monospacedDigit()

            if let detail {
                params(detail)
                InspectorSection(title: "实际执行的命令（已替换选项）") {
                    CodeBlock(text: CommandText.join(detail.command))
                }
                if !detail.envKeys.isEmpty {
                    Text("环境变量：\(detail.envKeys.sorted().joined(separator: "、"))（值不显示）")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(stale ? "连接中断，暂时无法读取运行详情" : "正在读取运行详情…")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hover ? Theme.card2 : Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(viewed && model.inspector.tab == .logs ? Theme.accent : Theme.line))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hover = $0 && hoverEnabled }
    }

    private func row(_ label: String, _ value: String, tone: Color = Theme.text) -> some View {
        GridRow {
            Text(label).foregroundStyle(Theme.text3).gridColumnAlignment(.trailing)
            Text(value).foregroundStyle(tone).textSelection(.enabled)
        }
    }

    private func timeRow(_ label: String, rules: [TextRefresh], value: @escaping (Date) -> String) -> some View {
        GridRow {
            Text(label).foregroundStyle(Theme.text3).gridColumnAlignment(.trailing)
            TimeCell(model: model, rules: rules) { now in
                Text(value(now)).foregroundStyle(Theme.text).textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func params(_ detail: RunDetail) -> some View {
        let rows = RunParamRow.make(detail.params, config: model.params(ref.projectId))
        InspectorSection(title: "当次使用的选项值") {
            if rows.isEmpty {
                Text("这次运行没有引用选项")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(rows) { r in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(r.label).foregroundStyle(Theme.text2)
                            Text("${\(r.key)}")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.text3)
                            Spacer(minLength: 8)
                            Text(r.value)
                                .font(.system(size: 12, design: .monospaced))
                                .fontWeight(.semibold)
                                .foregroundStyle(r.secret ? Theme.text3 : Theme.text)
                                .textSelection(.enabled)
                                .help(r.secret ? "敏感值不显示" : r.value)
                        }
                        .font(.system(size: 12))
                    }
                }
            }
        }
    }
}

/// `● 运行中` / `■ 已停止` / `▲ 异常（1）` for a run.
struct RunStatePill: View {
    let run: RunSummary

    var body: some View {
        let glyph: StatusGlyph = switch run.state {
        case .running: .running
        case .starting: .starting
        case .stopping: .stopping
        case .failed: .failed
        case .unknown: .unknown
        case .exited: .exited
        default: .stopped
        }
        StatusPill(label: StatusLabel(glyph: glyph, text: run.stateText, tone: run.tone))
    }
}
