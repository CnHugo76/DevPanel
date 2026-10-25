import Foundation

extension AppModel {
    public func runs(for ref: TaskRef) -> [TaskRunSummary] { taskRuns(ref) }
    public func latestRunId(for ref: TaskRef) -> RunID? { taskRuns(ref).first?.id }
    public func viewedRunId(for ref: TaskRef) -> RunID? {
        if let chosen = projectInspector.runChoice[ref], taskRuns(ref).contains(where: { $0.id == chosen }) { return chosen }
        return latestRunId(for: ref)
    }
    public func isViewingHistory(_ ref: TaskRef) -> Bool { viewedRunId(for: ref) != nil && viewedRunId(for: ref) != latestRunId(for: ref) }
    public func chooseRun(_ id: RunID?, for ref: TaskRef) {
        projectInspector.runChoice[ref] = id == latestRunId(for: ref) ? nil : id
        syncLogSession()
    }
    public func refreshRuns(_ ref: TaskRef) async {
        guard isConnected, let client, !projectInspector.runLoads.contains(ref) else { return }
        projectInspector.runLoads.insert(ref); defer { projectInspector.runLoads.remove(ref) }
        let runs: [TaskRunSummary]?
        switch ref.target {
        case .maven: runs = try? await client.mavenRuns(ref.projectId)
        case .action(let id): runs = try? await client.actionRuns(ref.projectId, actionId: id)
        }
        if let runs { projectInspector.runs[ref] = runs }
    }
    public func refreshRuns(_ owner: LogOwner) async {
        switch owner { case .service(let ref): await refreshRuns(ref); case .task(let ref): await refreshRuns(ref) }
    }
    public func runs(for owner: LogOwner) -> [LogRun] {
        switch owner { case .service(let ref): runs(for: ref).map(LogRun.service); case .task(let ref): taskRuns(ref).map(LogRun.task) }
    }
    public func viewedRunId(for owner: LogOwner) -> RunID? {
        switch owner { case .service(let ref): viewedRunId(for: ref); case .task(let ref): viewedRunId(for: ref) }
    }
    public func isViewingHistory(_ owner: LogOwner) -> Bool {
        switch owner { case .service(let ref): isViewingHistory(ref); case .task(let ref): isViewingHistory(ref) }
    }
    public func chooseRun(_ id: RunID?, for owner: LogOwner) {
        switch owner { case .service(let ref): chooseRun(id, for: ref); case .task(let ref): chooseRun(id, for: ref) }
    }
}
