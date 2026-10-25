import Foundation

extension AppModel {
    public func loadPolicy(_ id: ProjectID) async throws -> ProjectPolicy {
        guard isConnected, let client else { throw ApiError(code: .daemonUnreachable, message: "管理服务未连接") }; return try await client.policy(id)
    }
    public func savePolicy(_ id: ProjectID, policy: ProjectPolicy) async throws {
        guard isConnected, let client else { throw ApiError(code: .daemonUnreachable, message: "管理服务未连接") }
        _ = try await client.setPolicy(id, policy)
        apply(.projectUpsert(try await client.projectView(id)))
    }
    public func setServiceLocked(_ ref: ServiceRef, locked: Bool) async {
        guard isConnected, let client else { return }
        do {
            var policy = try await client.policy(ref.projectId)
            policy.lockedServices.removeAll { $0 == ref.serviceId }
            if locked { policy.lockedServices.append(ref.serviceId) }
            try await savePolicy(ref.projectId, policy: policy)
        } catch { projectInspector.error = error.localizedDescription }
    }
    public func allowAgentStart(_ ref: ServiceRef) async {
        guard isConnected, let client else { return }
        do { try await client.releaseHold(ref.projectId, serviceId: ref.serviceId); apply(.projectUpsert(try await client.projectView(ref.projectId))) }
        catch { projectInspector.error = error.localizedDescription }
    }
}
