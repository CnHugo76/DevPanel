import Foundation

// Inspector actions (F3): opening the log view, picking a run, run history, and the frozen
// clock used while disconnected. Views call these; they never talk to the client directly.

extension ConnectionState {
    /// Disconnected after having been connected: what is shown is the state at `syncedAt`.
    public var isStale: Bool {
        (status == .disconnected || status == .unauthorized || status == .notRunning) && syncedAt != nil
    }

    /// The time every "since / for N seconds" display uses: the wall clock while connected,
    /// frozen at `syncedAt` while stale (ui-design v1 §9: nothing keeps counting on old data).
    public func displayNow(_ wall: Date) -> Date {
        isStale ? (syncedAt ?? wall) : wall
    }
}

extension AppModel {
    /// See `ConnectionState.displayNow(_:)`.
    public func displayNow(_ wall: Date) -> Date { isStale ? (connection.syncedAt ?? wall) : wall }

    // MARK: Navigation

    /// Selects the service and shows its log (double-click on a row, "打开日志").
    public func openLogs(_ ref: ServiceRef) {
        select(ref)
        guard selection == ref else { return }
        inspector.tab = .logs
    }

    /// Shows one run's log (a card in "运行记录").
    public func showRunLog(_ runId: RunID, of ref: ServiceRef) {
        openLogs(ref)
        chooseRun(runId, for: ref)
    }

    // MARK: Runs

    /// `runsKeptPerService` (3 unless the daemon says otherwise).
    public var runsKept: Int { daemon?.limits.runsKeptPerService ?? 3 }

    /// Runs of a service, newest first, at most `runsKept`: the fetched list merged with the
    /// service view's current / last run (which is fresher).
    public func runs(for ref: ServiceRef) -> [RunSummary] {
        guard let service = project(ref.projectId)?.service(ref.serviceId) else { return [] }
        return RunLabels.merge(inspector.fetchedRuns[ref] ?? [], service: service, serviceId: ref.serviceId, limit: runsKept)
    }

    /// The newest run: the current one, else the last one.
    public func latestRunId(for ref: ServiceRef) -> RunID? {
        guard let service = project(ref.projectId)?.service(ref.serviceId) else { return nil }
        return service.currentRun?.id ?? service.lastRun?.id
    }

    /// The run the log view shows: the chosen older run while it is still kept, else the
    /// newest (so a restart switches to the new run automatically).
    public func viewedRunId(for ref: ServiceRef) -> RunID? {
        if let chosen = inspector.runChoice[ref], runs(for: ref).contains(where: { $0.id == chosen }) {
            return chosen
        }
        return latestRunId(for: ref)
    }

    /// Looking at an older run ("正在查看历史运行").
    public func isViewingHistory(_ ref: ServiceRef) -> Bool {
        guard let viewed = viewedRunId(for: ref) else { return false }
        return viewed != latestRunId(for: ref)
    }

    /// nil or the newest run → follow the newest run again.
    public func chooseRun(_ runId: RunID?, for ref: ServiceRef) {
        if let runId, runId != latestRunId(for: ref) {
            inspector.runChoice[ref] = runId
        } else {
            inspector.runChoice[ref] = nil
        }
        syncLogSession()
    }

    /// Points the log session at the selected service's viewed run (closes it when nothing is
    /// selected). Safe to call often: re-opening the same run does nothing.
    public func syncLogSession() {
        let logs = inspector.logs
        logs.clientProvider = { [weak self] in
            guard let self, self.isConnected else { return nil }
            return self.client
        }
        if let ref = selection, inspector.tab != .maven && inspector.tab != .git, let runId = viewedRunId(for: ref) {
            logs.open(LogTarget(projectId: ref.projectId, serviceId: ref.serviceId, runId: runId))
        } else if let ref = selectedTaskRef, let runId = viewedRunId(for: ref) {
            logs.open(LogTarget(task: ref, runId: runId))
        } else { logs.open(nil) }
    }

    /// `GET …/services/:id/runs`; responses for another service are dropped.
    public func refreshRuns(_ ref: ServiceRef) async {
        guard isConnected, let client, !inspector.runLoads.contains(ref) else { return }
        inspector.runLoads.insert(ref)
        defer { inspector.runLoads.remove(ref) }
        guard let runs = try? await client.runs(ref.projectId, serviceId: ref.serviceId) else { return }
        guard runs.allSatisfy({ $0.projectId == ref.projectId && $0.serviceId == ref.serviceId }) else { return }
        inspector.fetchedRuns[ref] = runs
    }

    /// `GET /runs/:id`. Ended runs are fetched once; active ones again when `force`.
    public func loadRunDetail(_ runId: RunID, force: Bool = false) async {
        guard isConnected, let client, !inspector.detailLoads.contains(runId) else { return }
        if let cached = inspector.runDetails[runId], !force || cached.endedAt != nil { return }
        inspector.detailLoads.insert(runId)
        defer { inspector.detailLoads.remove(runId) }
        guard let detail = try? await client.run(runId), detail.id == runId else { return }
        inspector.runDetails[runId] = detail
    }
}
