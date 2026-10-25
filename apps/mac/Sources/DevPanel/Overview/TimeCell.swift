import DevPanelKit
import SwiftUI

private struct LabelSchedule: TimelineSchedule {
    let rules: [TextRefresh]
    struct Entries: Sequence, IteratorProtocol {
        let rules: [TextRefresh]
        var date: Date?
        mutating func next() -> Date? {
            guard let current = date else { return nil }
            date = TextRefresh.alignedNext(rules, after: current)
            return current
        }
    }
    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        Entries(rules: rules, date: startDate)
    }
}

/// Owns only the label/cell that uses wall time. No schedule while stale or occluded.
struct TimeCell<Content: View>: View {
    let model: AppModel
    var rules: [TextRefresh]
    var freezesWhenStale = true
    @ViewBuilder var content: (Date) -> Content
    @Environment(\.timeVisible) private var visible

    var body: some View {
        if visible && (!freezesWhenStale || !model.isStale) && TextRefresh.alignedNext(rules, after: Date()) != nil {
            TimelineView(LabelSchedule(rules: rules)) { context in content(context.date) }
        } else {
            content(freezesWhenStale ? model.displayNow(Date()) : Date())
        }
    }
}

extension ServiceView {
    var statusRefresh: [TextRefresh] { state == .stopping && stateSince != nil ? [.seconds] : [] }
    var uptimeRefresh: [TextRefresh] {
        Timestamps.date(currentRun?.startedAt).map { [.duration(since: $0)] } ?? []
    }
    var noteRefresh: [TextRefresh] {
        guard !(currentRun != nil && configChangedSinceStart), [.failed, .exited, .stopped].contains(state) else { return [] }
        return [.days([lastRun?.endedAt, lastRun?.exit?.at].compactMap { Timestamps.date($0) })]
    }
}
