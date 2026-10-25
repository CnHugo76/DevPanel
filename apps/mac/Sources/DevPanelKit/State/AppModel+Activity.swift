import Foundation

extension AppModel {
    public func scheduleActivityRefresh(_ id: ProjectID) {
        guard activityVisible == id, isConnected else { return }
        activityPending.insert(id)
        guard activityRefreshes[id] == nil else { return }
        activityRefreshes[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(70))
            guard let self else { return }
            while self.activityPending.remove(id) != nil, self.activityVisible == id, self.isConnected, !Task.isCancelled {
                while self.activityLoads[id] != nil, self.activityVisible == id, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
                await self.refreshActivity(id)
            }
            self.activityRefreshes[id] = nil
        }
    }
    public func refreshActivity(_ id: ProjectID, more: Bool = false) async {
        guard isConnected, let client, activityVisible == id, activityLoads[id] == nil else { return }
        if more, activityHasMore[id] != true { return }
        let task = activityTaskFilters[id]
        let generation = activityGeneration[id, default: 0]
        let connection = connectionGeneration
        let request = UUID()
        activityLoads[id] = request
        activityLoading.insert(id)
        defer {
            if activityLoads[id] == request {
                activityLoads[id] = nil
                activityLoading.remove(id)
            }
        }
        do {
            let page = try await client.activity(id, before: more ? activityEntries[id]?.last?.id : nil, task: task)
            guard isConnected, connectionGeneration == connection, activityVisible == id, activityGeneration[id, default: 0] == generation,
                  activityTaskFilters[id] == task, !Task.isCancelled else { return }
            guard page.entries.allSatisfy({
                $0.projectId == id && (task == nil || $0.actor.taskId == task || $0.actor.taskId?.contains("[REDACTED]") == true)
            }) else {
                throw ApiError(code: .internal, message: "动态响应与当前项目或工作筛选不一致。")
            }
            let old = more ? activityEntries[id, default: []] : []
            var seen = Set<String>()
            activityEntries[id] = (old + page.entries).filter { seen.insert($0.id).inserted }
            activityHasMore[id] = page.hasMore
            activityError = nil
        } catch {
            guard isConnected, connectionGeneration == connection, activityVisible == id, activityGeneration[id, default: 0] == generation, !Task.isCancelled else { return }
            activityError = error.localizedDescription
        }
    }
    public func setActivityTaskFilter(_ task: String?, for id: ProjectID) async {
        let value = task?.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = value?.isEmpty == false ? value : nil
        guard next == nil || Actor.isValidTaskId(next!) else {
            activityError = "工作 ID 须为 1–64 位字母、数字、点、下划线或连字符，首位是字母或数字。"
            return
        }
        if activityTaskFilters[id] == next {
            activityError = nil
            await refreshActivity(id)
            return
        }
        activityTaskFilters[id] = next
        activityGeneration[id, default: 0] += 1
        activityLoads[id] = nil
        activityLoading.remove(id)
        activityEntries[id] = []
        activityHasMore[id] = false
        activityError = nil
        await refreshActivity(id)
    }
    public func openActivityRun(_ entry: ActivityEntry, runId: RunID) async {
        guard let client else { return }
        do {
            if entry.kind == .taskRun {
                let run = try await client.taskRun(runId)
                guard run.id == runId, run.projectId == entry.projectId else { return }
                let ref = TaskRef(entry.projectId, run.kind == .maven ? .maven : .action(run.actionId ?? ""))
                selectProject(entry.projectId, tab: run.kind == .maven ? .maven : .actions)
                projectInspector.actionChoice[entry.projectId] = run.actionId
                chooseRun(runId, for: ref)
            } else {
                let run = try await client.run(runId)
                guard run.id == runId, run.projectId == entry.projectId else { return }
                showRunLog(runId, of: ServiceRef(entry.projectId, run.serviceId))
            }
        } catch { activityError = error.localizedDescription }
    }
}
