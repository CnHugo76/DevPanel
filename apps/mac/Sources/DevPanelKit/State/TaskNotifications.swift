import Foundation

/// Snapshot establishes a baseline. Every completion is consumed even while foreground,
/// preventing a late notification when the app subsequently moves to the background.
public struct TaskNotificationTracker: Sendable {
    private var initialized = false
    private var seen: Set<RunID> = []
    private var order: [RunID] = []
    public init() {}
    public mutating func consume(_ event: DaemonEvent, foreground: Bool) -> [ServiceNotice] {
        let projects: [ProjectView]
        switch event {
        case .snapshot(let s): projects = s.projects
        case .projectUpsert(let p): projects = [p]
        default: return []
        }
        var notices: [ServiceNotice] = []
        for project in projects {
            let runs = project.actions.compactMap(\.lastRun) + [project.maven?.lastRun].compactMap { $0 }
            for run in runs where run.endedAt != nil && !seen.contains(run.id) {
                seen.insert(run.id); order.append(run.id)
                if initialized && !foreground && [.succeeded, .failed, .timedOut].contains(run.state) {
                    let target: TaskTarget
                    switch run.kind {
                    case .maven: target = .maven
                    case .action: guard let id = run.actionId else { continue }; target = .action(id)
                    case .other: continue
                    }
                    notices.append(ServiceNotice(id: run.id, ref: TaskRef(project.id, target), title: "\(project.name) · \(run.label)", body: run.statusText(now: Date())))
                }
            }
        }
        if order.count > 2000 { let old = order.prefix(order.count - 2000); seen.subtract(old); order.removeFirst(old.count) }
        if case .snapshot = event { initialized = true }
        return notices
    }
}
