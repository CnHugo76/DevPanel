import Foundation

public struct ActionDraft: Identifiable, Hashable, Sendable {
    public var service: ServiceDraft
    public var description: String
    public var timeoutText: String
    public var confirmWhenServicesRunning: Bool
    public var id: UUID { service.id }
    public init(service: ServiceDraft, description: String = "", timeoutText: String = "", confirmWhenServicesRunning: Bool = false) {
        self.service = service; self.description = description; self.timeoutText = timeoutText; self.confirmWhenServicesRunning = confirmWhenServicesRunning
    }
    public init(config: ActionConfig) {
        let draft = ProjectDraft(config: ProjectConfig(name: "", root: "/", services: [ServiceConfig(id: config.id, name: config.name, cwd: config.cwd, command: config.command, env: config.env, stopTimeoutSec: config.stopTimeoutSec)]))
        self.init(service: draft.services[0], description: config.description ?? "", timeoutText: config.timeoutSec.map(String.init) ?? "", confirmWhenServicesRunning: config.confirmWhenServicesRunning == true)
    }
}
