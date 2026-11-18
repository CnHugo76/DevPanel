import Foundation

public enum OverviewStateFilter: String, CaseIterable, Sendable {
    case all = "全部状态", running = "运行中", stopped = "已停止"

    func includes(_ project: ProjectView) -> Bool {
        switch self {
        case .all: true
        case .running: project.runningCount > 0
        case .stopped: project.services.allSatisfy { $0.state.isStartable }
        }
    }
}

public struct CompactProjectList {
    public var attention: [FilteredProject] = []
    public var sections: [ProjectSection] = []
    public var otherCount = 0

    public init(sections: [ProjectSection], filter: OverviewStateFilter) {
        for var section in sections {
            section.projects = section.projects.filter { item in
                if item.firstProblem != nil {
                    attention.append(item)
                    return false
                }
                return filter.includes(item.project)
            }
            otherCount += section.projects.count
            if !section.projects.isEmpty || (section.group != nil && filter == .all) {
                self.sections.append(section)
            }
        }
    }
}

public extension FilteredProject {
    var firstProblem: OverviewProblem? {
        for service in services {
            if let problem = OverviewProblem(projectID: id, service: service) { return problem }
        }
        return nil
    }
}
