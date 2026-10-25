import Foundation

public enum TaskTarget: Hashable, Sendable { case action(String), maven }
public struct TaskRef: Hashable, Sendable {
    public var projectId: ProjectID
    public var target: TaskTarget
    public init(_ projectId: ProjectID, _ target: TaskTarget) { self.projectId = projectId; self.target = target }
}
public enum LogOwner: Hashable, Sendable {
    case service(ServiceRef), task(TaskRef)
    public var projectId: ProjectID { switch self { case .service(let r): r.projectId; case .task(let r): r.projectId } }
    public var service: ServiceRef? { if case .service(let r) = self { r } else { nil } }
    public var isTask: Bool { if case .task = self { true } else { false } }
}
