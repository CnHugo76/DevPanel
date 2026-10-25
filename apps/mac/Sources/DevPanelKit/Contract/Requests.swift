import Foundation

// Mirrors packages/contract/src/index.ts — "Requests / responses".

public typealias RegisterRequest = ProjectConfig

public struct RegisterResponse: Codable, Hashable, Sendable {
    /// false = identical config already registered at this root.
    public var created: Bool
    public var project: Project
}

public struct UpdateRequest: Codable, Hashable, Sendable {
    public var ifRevision: Int
    public var config: ProjectConfig
    /// v1.1-A. true lets the request overwrite values a user set.
    public var overrideUserValues: Bool?

    public init(ifRevision: Int, config: ProjectConfig, overrideUserValues: Bool? = nil) {
        self.ifRevision = ifRevision
        self.config = config
        self.overrideUserValues = overrideUserValues
    }
}

/// `Project & { keptUserValues?: string[] }` — flat on the wire.
public struct UpdateResponse: Codable, Hashable, Sendable {
    public var project: Project
    /// Param keys whose user-set value was preserved.
    public var keptUserValues: [String]?

    private enum CodingKeys: String, CodingKey { case keptUserValues }

    public init(project: Project, keptUserValues: [String]? = nil) {
        self.project = project
        self.keptUserValues = keptUserValues
    }

    public init(from decoder: any Decoder) throws {
        project = try Project(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keptUserValues = try c.decodeIfPresent([String].self, forKey: .keptUserValues)
    }

    public func encode(to encoder: any Encoder) throws {
        try project.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(keptUserValues, forKey: .keptUserValues)
    }
}

/// v1.1-A. POST /projects/:id/params
public struct AddParamRequest: Codable, Hashable, Sendable {
    public var ifRevision: Int
    public var param: ParamConfig

    public init(ifRevision: Int, param: ParamConfig) {
        self.ifRevision = ifRevision
        self.param = param.forRequest
    }
}

/// v1.1-A. PATCH /projects/:id/params/:key — only non-nil fields are sent and changed.
public struct PatchParamRequest: Codable, Hashable, Sendable {
    public var ifRevision: Int
    public var value: ParamValue?
    public var label: String?
    public var description: String?
    public var choices: [ParamChoice]?
    public var min: Double?
    public var max: Double?

    public init(
        ifRevision: Int, value: ParamValue? = nil, label: String? = nil, description: String? = nil,
        choices: [ParamChoice]? = nil, min: Double? = nil, max: Double? = nil
    ) {
        self.ifRevision = ifRevision
        self.value = value
        self.label = label
        self.description = description
        self.choices = choices
        self.min = min
        self.max = max
    }
}

public struct ShutdownRequest: Codable, Hashable, Sendable {
    /// Must be true if anything is running, otherwise PROJECT_RUNNING.
    public var stopServices: Bool

    public init(stopServices: Bool) { self.stopServices = stopServices }
}

public struct ConfigDiffEntry: Codable, Hashable, Sendable {
    public var path: String
    public var existing: JSONValue?
    public var incoming: JSONValue?
}
