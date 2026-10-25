import Foundation
import Observation

public struct RetainedLogSearchTarget: Identifiable, Sendable {
    public var runId: RunID
    public var query: String
    public var id: RunID { runId }
    public init(runId: RunID, query: String = "") { self.runId = runId; self.query = query }
}

/// Base service tabs plus Git/Maven tools resolved from the service's working directory.
public enum InspectorTab: String, CaseIterable, Sendable, Identifiable {
    case logs
    case options
    case runs
    case command
    case git, maven

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .logs: "日志"
        case .options: "选项"
        case .runs: "运行记录"
        case .command: "命令与环境"
        case .git: "Git"
        case .maven: "Maven"
        }
    }

    /// Tabs shown in v0.2, in order.
    public static let visible: [InspectorTab] = [.logs, .options, .runs, .command]

    /// `--snapshot --tab` names: logs | options | runs | cmd.
    public init?(argument: String) {
        switch argument {
        case "logs", "log": self = .logs
        case "options", "opt": self = .options
        case "runs": self = .runs
        case "git": self = .git
        case "maven": self = .maven
        case "cmd", "command": self = .command
        default: return nil
        }
    }
}

/// View state of the inspector that outlives a single SwiftUI view: selected tab, the run
/// picked in the log view, fetched run lists / details, the log session and its search.
/// Owned by `AppModel` (`model.inspector`); actions live in `AppModel+Inspector.swift`.
@Observable
@MainActor
public final class InspectorState {
    public var tab: InspectorTab = .logs
    /// Wrap long log lines.
    public var wrap = true
    public var foldStacks = true
    public var compactPrefixes = true
    /// Explicitly chosen (older) run per service; absent = follow the newest run.
    public internal(set) var runChoice: [ServiceRef: RunID] = [:]
    /// `GET …/services/:id/runs`, newest first, per service.
    public internal(set) var fetchedRuns: [ServiceRef: [RunSummary]] = [:]
    /// `GET /runs/:id`, by run.
    public internal(set) var runDetails: [RunID: RunDetail] = [:] { didSet { detailsChanged?() } }
    @ObservationIgnored var detailsChanged: (() -> Void)?

    public let logs: LogSession
    public let search: LogSearchModel
    public var retainedSearch: RetainedLogSearchTarget?

    @ObservationIgnored var runLoads: Set<ServiceRef> = []
    @ObservationIgnored var detailLoads: Set<RunID> = []

    public init(logs: LogSession = LogSession(), search: LogSearchModel = LogSearchModel()) {
        self.logs = logs
        self.search = search
        search.bind { [unowned logs] in logs.buffer }
        logs.onLinesChanged = { [unowned search] in search.linesChanged() }
    }
}
