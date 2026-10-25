import Foundation

/// Config mutations for the add / edit project sheet and "移除项目" (F5).
/// Every successful call stores the returned config in `configs`.
extension AppModel {
    private func connectedClient() throws -> DaemonClient {
        guard let client, isConnected else { throw ApiError.unreachable("管理服务未连接") }
        return client
    }

    /// `POST /config/validate`: checks and resolves only, never saves or runs anything.
    public func validateConfig(_ config: ProjectConfig) async throws -> ValidateResult {
        try await connectedClient().validate(config)
    }

    /// `GET /projects/:id` (fresh, secrets masked).
    public func fetchProject(_ id: ProjectID) async throws -> Project {
        let p = try await connectedClient().project(id)
        storeConfig(p)
        return p
    }

    /// `POST /projects`. 201 → created; 200 → the same config was already registered.
    public func registerProject(_ config: ProjectConfig) async throws -> RegisterResponse {
        let r = try await connectedClient().register(config)
        storeConfig(r.project)
        return r
    }

    /// `PUT /projects/:id` with `ifRevision`. Never starts or restarts anything.
    public func updateProject(_ id: ProjectID, ifRevision: Int, config: ProjectConfig) async throws -> UpdateResponse {
        let r = try await connectedClient().update(id, UpdateRequest(ifRevision: ifRevision, config: config))
        storeConfig(r.project)
        return r
    }

    /// `DELETE /projects/:id`: removes config, runs and logs only, never files under the root.
    /// The `project.remove` event updates `projects`.
    public func removeProject(_ id: ProjectID) async throws {
        try await connectedClient().deleteProject(id)
        if selectedProjectId == id { select(nil) }
    }
}
