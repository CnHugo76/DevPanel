import DevPanelKit
import SwiftUI

/// Task output reuses log storage/search, but its footer clock is confined to quiet-time text.
struct TaskLogsFooter: View {
    let model: AppModel
    let onTarget: Bool
    let live: Bool
    let toast: String?
    private var session: LogSession { model.inspector.logs }
    var body: some View {
        let items = onTarget ? LogFooter.items(status: session.status, buffer: session.buffer, live: live, stale: model.isStale, now: .distantPast, logBytesPerRun: model.daemon?.limits.logBytesPerTaskRun) : []
        FlowLayout(spacing: 12) {
            if let toast { Text(toast).foregroundStyle(Theme.green) }
            ForEach(items) { item in
                Text(item.text).foregroundStyle(item.tone == .negative ? Theme.red : item.tone == .warning ? Theme.amber : Theme.text3)
            }
            if onTarget, live, let last = session.status.lastLineAt {
                TaskQuietText(model: model, lastLineAt: last)
            }
            if items.count + (toast == nil ? 0 : 1) <= 2 { Text("stderr 以红线标出").foregroundStyle(Theme.text3) }
        }.font(.system(size: 11.5)).monospacedDigit().padding(.horizontal, 14).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading).background(Theme.bar)
            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}
struct TaskQuietText: View {
    let model: AppModel
    let lastLineAt: Date
    var body: some View {
        TimeCell(model: model, rules: [.ago(since: lastLineAt, quietAfter: LogFooter.quietAfter)]) { now in text(now: now) }
    }

    private func text(now: Date) -> Text {
        let silence = now.timeIntervalSince(lastLineAt)
        return Text(silence > LogFooter.quietAfter ? "暂无新输出 · 最后输出于 \(Format.ago(silence))" : "").foregroundColor(Theme.text3)
    }
}

/// Only the quiet label and the hint whose presence depends on it own a clock.
struct QuietFooterTail: View {
    let model: AppModel
    let lastLineAt: Date?
    let count: Int
    private var quietRules: [TextRefresh] {
        lastLineAt.map { [.ago(since: $0, quietAfter: LogFooter.quietAfter)] } ?? []
    }
    var body: some View {
        TimeCell(model: model, rules: quietRules) { now in
            if let lastLineAt, now.timeIntervalSince(lastLineAt) > LogFooter.quietAfter {
                Text("暂无新输出 · 最后输出于 \(Format.ago(now.timeIntervalSince(lastLineAt)))").foregroundStyle(Theme.text3)
            }
        }
        TimeCell(model: model, rules: count == 2 ? lastLineAt.map { [.once(at: $0.addingTimeInterval(LogFooter.quietAfter + 0.001))] } ?? [] : []) { now in
            let quiet = lastLineAt.map { now.timeIntervalSince($0) > LogFooter.quietAfter } ?? false
            if count + (quiet ? 1 : 0) <= 2 {
                Text("stderr 以红线标出").foregroundStyle(Theme.text3)
            }
        }
    }
}
