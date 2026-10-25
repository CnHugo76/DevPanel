import Foundation

// Mirrors packages/contract/src/index.ts — "Config" and "Params (v1.1-A)".

/// `string | { secret: true; value?: string }`.
///
/// - Request: `.secret(value: "…")` sets a secret, `.secret(value: nil)` keeps the stored one.
/// - Response: secrets always come back as `.secret(value: nil)`.
public enum EnvValue: Codable, Hashable, Sendable {
    case plain(String)
    case secret(value: String?)

    private enum CodingKeys: String, CodingKey { case secret, value }

    public init(from decoder: any Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            self = .plain(s)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Bool.self, forKey: .secret) else {
            throw DecodingError.dataCorruptedError(
                forKey: .secret, in: c, debugDescription: "EnvValue object must have secret: true")
        }
        self = .secret(value: try c.decodeIfPresent(String.self, forKey: .value))
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .plain(let s):
            var c = encoder.singleValueContainer()
            try c.encode(s)
        case .secret(let value):
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(true, forKey: .secret)
            try c.encodeIfPresent(value, forKey: .value)
        }
    }

    public var isSecret: Bool {
        if case .secret = self { return true }
        return false
    }

    /// Plain value, nil for secrets (never display secret values).
    public var plainValue: String? {
        if case .plain(let s) = self { return s }
        return nil
    }
}

public typealias EnvMap = [String: EnvValue]

public enum ParamType: OpenEnum {
    case string, number, boolean, `enum`
    case other(String)

    public static let known: [ParamType] = [.string, .number, .boolean, .enum]
    public var rawValue: String {
        switch self {
        case .string: "string"
        case .number: "number"
        case .boolean: "boolean"
        case .enum: "enum"
        case .other(let s): s
        }
    }
}

/// Derived from `X-DevPanel-Client`: ui → user, cli → agent.
public enum ParamSetter: OpenEnum {
    case agent, user
    case other(String)

    public static let known: [ParamSetter] = [.agent, .user]
    public var rawValue: String {
        switch self {
        case .agent: "agent"
        case .user: "user"
        case .other(let s): s
        }
    }
}

/// `string | number | boolean`.
public enum ParamValue: Codable, Hashable, Sendable, CustomStringConvertible {
    case string(String)
    case number(Double)
    case bool(Bool)

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else {
            self = .string(try c.decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n):
            // Integers go out as JSON integers (8081, not 8081.0).
            if n.rounded() == n, abs(n) < 9.0e15 {
                try c.encode(Int64(n))
            } else {
                try c.encode(n)
            }
        case .bool(let b): try c.encode(b)
        }
    }

    /// How the daemon substitutes it: numbers in decimal, booleans as true/false.
    public var description: String {
        switch self {
        case .string(let s): s
        case .bool(let b): b ? "true" : "false"
        case .number(let n):
            if n.rounded() == n, abs(n) < 9.0e15 { String(Int64(n)) } else { String(n) }
        }
    }
}

public struct ParamChoice: Codable, Hashable, Sendable {
    public var value: String
    public var label: String?
    public var description: String?

    public init(value: String, label: String? = nil, description: String? = nil) {
        self.value = value
        self.label = label
        self.description = description
    }
}

public struct ParamReference: Codable, Hashable, Sendable {
    public enum Location: OpenEnum {
        case command, env, ready
        case other(String)

        public static let known: [Location] = [.command, .env, .ready]
        public var rawValue: String {
            switch self {
            case .command: "command"
            case .env: "env"
            case .ready: "ready"
            case .other(let s): s
            }
        }
    }

    /// "*" for project-level env.
    public var serviceId: String
    public var `where`: Location
    /// argv index when `where == .command`.
    public var index: Int?
    /// variable name when `where == .env`.
    public var envKey: String?

    public init(serviceId: String, where: Location, index: Int? = nil, envKey: String? = nil) {
        self.serviceId = serviceId
        self.where = `where`
        self.index = index
        self.envKey = envKey
    }

    public var isProjectLevel: Bool { serviceId == "*" }
}

public struct ParamConfig: Codable, Hashable, Sendable, Identifiable {
    public var key: String
    public var label: String
    public var type: ParamType
    /// Absent for secret params in responses.
    public var value: ParamValue?
    public var description: String?
    public var choices: [ParamChoice]?
    public var min: Double?
    public var max: Double?
    public var secret: Bool?
    // response-only
    public var setBy: ParamSetter?
    public var valueUpdatedAt: Timestamp?
    public var describedBy: ParamSetter?
    public var usedBy: [ParamReference]?

    public var id: String { key }
    public var isSecret: Bool { secret == true }

    public init(
        key: String, label: String, type: ParamType, value: ParamValue? = nil,
        description: String? = nil, choices: [ParamChoice]? = nil, min: Double? = nil,
        max: Double? = nil, secret: Bool? = nil, setBy: ParamSetter? = nil,
        valueUpdatedAt: Timestamp? = nil, describedBy: ParamSetter? = nil,
        usedBy: [ParamReference]? = nil
    ) {
        self.key = key
        self.label = label
        self.type = type
        self.value = value
        self.description = description
        self.choices = choices
        self.min = min
        self.max = max
        self.secret = secret
        self.setBy = setBy
        self.valueUpdatedAt = valueUpdatedAt
        self.describedBy = describedBy
        self.usedBy = usedBy
    }

    /// A copy without the response-only fields, suitable for request bodies.
    public var forRequest: ParamConfig {
        var p = self
        p.setBy = nil
        p.valueUpdatedAt = nil
        p.describedBy = nil
        p.usedBy = nil
        return p
    }
}

public struct ServiceConfig: Codable, Hashable, Sendable, Identifiable {
    public var id: ServiceID
    public var name: String
    public var cwd: String
    /// argv, never a shell string.
    public var command: [String]
    public var env: EnvMap?
    public var stopTimeoutSec: Int?
    public var ready: ReadyConfig?

    public init(
        id: ServiceID, name: String, cwd: String, command: [String], env: EnvMap? = nil,
        stopTimeoutSec: Int? = nil, ready: ReadyConfig? = nil
    ) {
        self.id = id
        self.name = name
        self.cwd = cwd
        self.command = command
        self.env = env
        self.stopTimeoutSec = stopTimeoutSec
        self.ready = ready
    }
}

public struct RepositoryConfig: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var path: String
    public init(id: String, name: String, path: String) { self.id = id; self.name = name; self.path = path }
}
public struct MavenProjectConfig: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var path: String
    public var executable: String?
    public init(id: String, name: String, path: String, executable: String? = nil) {
        self.id = id; self.name = name; self.path = path; self.executable = executable
    }
}

public struct ProjectConfig: Codable, Hashable, Sendable {
    public var instance: ProjectInstance?
    public var schemaVersion: Int
    public var name: String
    public var root: String
    public var env: EnvMap?
    public var services: [ServiceConfig]
    /// v1.1-A. Display order = array order.
    public var params: [ParamConfig]?
    public var actions: [ActionConfig]?
    public var maven: MavenConfig?
    public var repositories: [RepositoryConfig]?
    public var mavenProjects: [MavenProjectConfig]?

    public init(
        schemaVersion: Int = 1, name: String, root: String, env: EnvMap? = nil,
        services: [ServiceConfig], params: [ParamConfig]? = nil, actions: [ActionConfig]? = nil, maven: MavenConfig? = nil,
        instance: ProjectInstance? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.name = name
        self.root = root
        self.env = env
        self.services = services
        self.params = params
        self.actions = actions
        self.maven = maven
        self.instance = instance
    }
}

public struct Project: Codable, Hashable, Sendable, Identifiable {
    public var id: ProjectID
    /// Optimistic concurrency token (`ifRevision`).
    public var revision: Int
    public var createdAt: Timestamp
    public var updatedAt: Timestamp
    /// Secrets masked.
    public var config: ProjectConfig

    public init(id: ProjectID, revision: Int, createdAt: Timestamp, updatedAt: Timestamp, config: ProjectConfig) {
        self.id = id
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.config = config
    }
}
