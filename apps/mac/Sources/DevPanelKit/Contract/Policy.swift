import Foundation

public enum AgentForceStop: OpenEnum {
    case allow, deny, other(String)
    public static let known: [Self] = [.allow, .deny]
    public var rawValue: String { switch self { case .allow: "allow"; case .deny: "deny"; case .other(let value): value } }
}
public struct ProjectPolicy: Codable, Hashable, Sendable {
    public var holdAfterUserStop: Bool
    public var agentForceStop: AgentForceStop
    public var lockedServices: [ServiceID]
    public init(holdAfterUserStop: Bool = true, agentForceStop: AgentForceStop = .deny, lockedServices: [ServiceID] = []) {
        self.holdAfterUserStop = holdAfterUserStop; self.agentForceStop = agentForceStop; self.lockedServices = lockedServices
    }
}
public struct ServiceHold: Codable, Hashable, Sendable {
    public var since: Timestamp
    public var operationId: OperationID
}
