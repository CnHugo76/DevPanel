import Foundation

extension AppModel {
    public func patchOption(_ id: ProjectID, key: String, request: PatchParamRequest) async throws -> Project {
        guard isConnected, let client else { throw ApiError.unreachable() }
        let p = try await client.patchParam(id, key: key, request)
        storeConfig(p)
        return p
    }

    public func addOption(_ id: ProjectID, revision: Int, param: ParamConfig) async throws -> Project {
        guard isConnected, let client else { throw ApiError.unreachable() }
        let p = try await client.addParam(id, AddParamRequest(ifRevision: revision, param: param))
        storeConfig(p)
        return p
    }

    public func deleteOption(_ id: ProjectID, revision: Int, param: ParamConfig) async throws -> Project {
        guard isConnected, let client else { throw ApiError.unreachable() }
        let p = try await client.deleteParam(id, key: param.key, ifRevision: revision, inline: !(param.usedBy ?? []).isEmpty)
        storeConfig(p)
        return p
    }
}
