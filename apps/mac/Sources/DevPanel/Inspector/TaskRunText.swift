import DevPanelKit
import SwiftUI

/// Only the time-dependent text ticks. Completed/disconnected tasks own no clock.
struct TaskRunText: View {
    enum Style { case status, compact, maven }
    let model: AppModel
    let run: TaskRunSummary
    var style: Style = .status
    var includeResources = false
    var body: some View {
        TimeCell(model: model, rules: run.state.isActive ? Timestamps.date(run.startedAt).map { [.duration(since: $0)] } ?? [] : []) { now in
            Text(label(now: now))
        }
    }

    private func label(now: Date) -> String {
        let duration = Format.duration(run.duration(now: now) ?? 0)
        switch style {
        case .compact:
            if run.state == .succeeded { return "✓ " + duration }
            if run.state == .failed { return "✕ 退出码 \(run.exit?.code ?? 1)" }
            return run.state.title + " · " + duration
        case .maven: return "● Maven: \(run.label) · \(duration)"
        case .status:
            var text = run.statusText(now: now) + " · 由 \(run.startedBy?.displayName ?? "未知") 启动"
            if includeResources, run.state.isActive, let sample = model.projectStats(run.projectId)?.tasks?[run.id] {
                text += " · CPU \(Metrics.cpu(sample.sample, active: true).text) · 内存 \(Metrics.memory(sample.sample, active: true).text)"
                if let count = sample.processCount { text += "（\(count) 个进程）" }
            }
            return text
        }
    }
}
