import Foundation
import Observation

/// Stable per-entity observation identities: updating A does not invalidate B's readers.
private struct ResourceDisplay: Equatable {
    var cpu: MetricText
    var memory: MetricText
    init(_ sample: ResourceSample?) {
        cpu = Metrics.cpu(sample, active: true)
        memory = Metrics.memory(sample, active: true)
    }
}
private struct ServiceDisplay: Equatable {
    var run: RunID?
    var resources: ResourceDisplay
    var ports: PortCell
    var processes: Int?
    init(_ value: ServiceStats?) {
        run = value?.runId
        resources = ResourceDisplay(value?.sample)
        ports = PortCell.make(value?.listening, active: true)
        processes = value?.processCount
    }
}
@Observable @MainActor final class ServiceStatsStore {
    @ObservationIgnored private var raw: ServiceStats?
    private var display = ServiceDisplay(nil)
    var value: ServiceStats? { _ = display; return raw }
    func update(_ value: ServiceStats?) {
        raw = value
        let next = ServiceDisplay(value)
        if display != next { display = next }
    }
}
@Observable @MainActor final class ProjectStatsStore {
    @ObservationIgnored private var raw: ProjectStats?
    private var total = ResourceDisplay(nil)
    private var tasks: [RunID: ServiceDisplay] = [:]
    var value: ProjectStats? { _ = total; _ = tasks; return raw }
    func update(_ value: ProjectStats?) {
        raw = value
        let next = ResourceDisplay(value?.total)
        let tasks = value?.tasks?.mapValues { ServiceDisplay($0) } ?? [:]
        if total != next { total = next }
        if self.tasks != tasks { self.tasks = tasks }
    }
}
@Observable @MainActor final class ParamPresentationStore {
    var pendingServices: Set<ServiceID> = []
    var groups: [ParamChipGroup] = []
    func update(project: ProjectView, params: [ParamConfig], details: [RunID: RunDetail]) {
        let pending = Set(project.services.filter {
            ParamChips.serviceHasPendingParam($0.id, params: params, project: project, details: details)
        }.map(\.id))
        let groups = ParamChips.groups(params, project: project, details: details)
        if pendingServices != pending { pendingServices = pending }
        if self.groups != groups { self.groups = groups }
    }
}
