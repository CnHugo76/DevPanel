import Foundation

// Mirrors packages/contract/src/index.ts — "Resources".

public enum SampleStatus: OpenEnum {
    case sampling, ok, partial, unavailable
    case other(String)

    public static let known: [SampleStatus] = [.sampling, .ok, .partial, .unavailable]
    public var rawValue: String {
        switch self {
        case .sampling: "sampling"
        case .ok: "ok"
        case .partial: "partial"
        case .unavailable: "unavailable"
        case .other(let s): s
        }
    }
}

/// Never substitute 0 for an unknown value. Memory can be available during the first CPU sample.
public struct ResourceSample: Codable, Hashable, Sendable {
    public var status: SampleStatus
    public var sampledAt: Timestamp?
    /// 100 = one logical CPU, not capped.
    public var cpuPercent: Double?
    public var rssBytes: Int?
    /// macOS memory footprint (including compressed/swapped accounting), summed over verified identities.
    /// Not RSS, heap usage, or globally deduplicated physical pages; nil if incomplete/unsupported.
    public var footprintBytes: Int?
    public var processCount: Int?
    public var note: String?

    public init(
        status: SampleStatus, sampledAt: Timestamp? = nil, cpuPercent: Double? = nil,
        rssBytes: Int? = nil, footprintBytes: Int? = nil, processCount: Int? = nil, note: String? = nil
    ) {
        self.status = status
        self.sampledAt = sampledAt
        self.cpuPercent = cpuPercent
        self.rssBytes = rssBytes
        self.footprintBytes = footprintBytes
        self.processCount = processCount
        self.note = note
    }
}

/// v1.1-B. A TCP LISTEN socket held by a verified managed process.
public struct ListeningPort: Codable, Hashable, Sendable {
    public enum Family: OpenEnum {
        case ipv4, ipv6
        case other(String)

        public static let known: [Family] = [.ipv4, .ipv6]
        public var rawValue: String {
            switch self {
            case .ipv4: "ipv4"
            case .ipv6: "ipv6"
            case .other(let s): s
            }
        }
    }

    public enum Scope: OpenEnum {
        case loopback, all
        /// The contract's `'other'` (a specific non-loopback address).
        case specific
        case other(String)

        public static let known: [Scope] = [.loopback, .all, .specific]
        public var rawValue: String {
            switch self {
            case .loopback: "loopback"
            case .all: "all"
            case .specific: "other"
            case .other(let s): s
            }
        }
    }

    public var port: Int
    public var address: String
    public var family: Family
    public var scope: Scope
    public var pid: Int

    public init(port: Int, address: String, family: Family, scope: Scope, pid: Int) {
        self.port = port
        self.address = address
        self.family = family
        self.scope = scope
        self.pid = pid
    }
}

/// `ResourceSample & { runId, listening }`.
public struct ServiceStats: Codable, Hashable, Sendable {
    public var runId: RunID
    public var status: SampleStatus
    public var sampledAt: Timestamp?
    public var cpuPercent: Double?
    public var rssBytes: Int?
    /// macOS memory footprint (including compressed/swapped accounting), summed over verified identities.
    /// Not RSS, heap usage, or globally deduplicated physical pages; nil if incomplete/unsupported.
    public var footprintBytes: Int?
    public var processCount: Int?
    public var note: String?
    /// v1.1-B. nil = not read this cycle (or field absent from an older daemon); [] = confirmed none.
    public var listening: [ListeningPort]?

    public init(
        runId: RunID, status: SampleStatus, sampledAt: Timestamp? = nil, cpuPercent: Double? = nil,
        rssBytes: Int? = nil, footprintBytes: Int? = nil, processCount: Int? = nil, note: String? = nil,
        listening: [ListeningPort]? = nil
    ) {
        self.runId = runId
        self.status = status
        self.sampledAt = sampledAt
        self.cpuPercent = cpuPercent
        self.rssBytes = rssBytes
        self.footprintBytes = footprintBytes
        self.processCount = processCount
        self.note = note
        self.listening = listening
    }

    public var sample: ResourceSample {
        ResourceSample(
            status: status, sampledAt: sampledAt, cpuPercent: cpuPercent, rssBytes: rssBytes,
            footprintBytes: footprintBytes, processCount: processCount, note: note)
    }
}

public struct ProjectStats: Codable, Hashable, Sendable {
    /// Deduplicated by process identity across services.
    public var total: ResourceSample
    /// Only services with a current run.
    public var services: [ServiceID: ServiceStats]
    public var tasks: [RunID: ServiceStats]?

    public init(total: ResourceSample, services: [ServiceID: ServiceStats]) {
        self.total = total
        self.services = services
    }
}

public struct StatsSnapshot: Codable, Hashable, Sendable {
    public var sampledAt: Timestamp
    public var intervalMs: Int
    /// Only projects with at least one current run.
    public var projects: [ProjectID: ProjectStats]

    public init(sampledAt: Timestamp, intervalMs: Int, projects: [ProjectID: ProjectStats]) {
        self.sampledAt = sampledAt
        self.intervalMs = intervalMs
        self.projects = projects
    }
}
