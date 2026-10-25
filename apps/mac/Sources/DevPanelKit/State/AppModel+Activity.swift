import Foundation

extension AppModel {
    public func scheduleActivityRefresh(_ id: ProjectID) {
        guard activityVisible == id, isConnected else { return }
        activityPending.insert(id)
        guard activityRefreshes[id] == nil else { return }
        activityRefreshes[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(70))
            guard let self else { return }
            while self.activityPending.remove(id) != nil, self.activityVisible == id, self.isConnected {
                while self.activityLoads.contains(id), self.activityVisible == id { try? await Task.sleep(for: .milliseconds(10)) }
                await self.refreshActivity(id)
            }
            self.activityRefreshes[id] = nil
        }
    }
    public func refreshActivity(_ id: ProjectID, more: Bool = false) async {
        guard isConnected, let client, activityVisible == id, !activityLoads.contains(id) else { return }
        activityLoads.insert(id)
        defer { activityLoads.remove(id) }
        do {
            let page = try await client.activity(id, before: more ? activityEntries[id]?.last?.id : nil)
            guard activityVisible == id else { return }
            let old = more ? activityEntries[id, default: []] : []
            var seen = Set<String>()
            activityEntries[id] = (old + page.entries).filter { seen.insert($0.id).inserted }
            activityHasMore[id] = page.hasMore
            activityError = nil
        } catch { activityError = error.localizedDescription }
    }
    public func openActivityRun(_ entry: ActivityEntry, runId: RunID) async {
        guard let client else { return }
        do {
            if entry.kind == .taskRun {
                let run = try await client.taskRun(runId)
                let ref = TaskRef(entry.projectId, run.kind == .maven ? .maven : .action(run.actionId ?? ""))
                selectProject(entry.projectId, tab: run.kind == .maven ? .maven : .actions)
                projectInspector.actionChoice[entry.projectId] = run.actionId
                chooseRun(runId, for: ref)
            } else {
                let run = try await client.run(runId)
                showRunLog(runId, of: ServiceRef(entry.projectId, run.serviceId))
            }
        } catch { activityError = error.localizedDescription }
    }
}
