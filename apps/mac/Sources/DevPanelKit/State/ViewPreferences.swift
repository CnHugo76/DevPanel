import Foundation
import Observation

/// Remembered view state: collapsed project cards and the inspector width (ui-design v2 §2–§3).
/// Backed by `UserDefaults`; pass `nil` for an in-memory instance (tests, `--snapshot`).
@Observable
@MainActor
public final class ViewPreferences {
    public static let inspectorDefault = 470.0
    public static let inspectorRange = 380.0...640.0
    /// The overview keeps at least this much width next to the inspector.
    public static let overviewMinWidth = 520.0

    static let expandedKey = "overview.expandedProjects"
    static let expandedOptionsKey = "overview.expandedOptions"
    static let inspectorKey = "inspector.width"

    public var detailed = false {
        didSet { defaults?.set(detailed, forKey: "window.detailed") }
    }
    /// Secondary table display is scoped to this session.
    public var metricProjects: Set<ProjectID> = []
    private var expandedProjects: Set<ProjectID>
    public private(set) var expandedOptions: Set<ProjectID>
    public private(set) var inspectorWidth: Double
    public private(set) var projectInspectorWidth: Double
    public let serviceLinks: ServiceLinkPreferences
    public let organization: ProjectOrganization

    @ObservationIgnored private let defaults: UserDefaults?

    public init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        serviceLinks = ServiceLinkPreferences(defaults: defaults)
        organization = ProjectOrganization(defaults: defaults)
        detailed = defaults?.bool(forKey: "window.detailed") ?? false
        expandedProjects = Set(defaults?.stringArray(forKey: Self.expandedKey) ?? [])
        expandedOptions = Set(defaults?.stringArray(forKey: Self.expandedOptionsKey) ?? [])
        let stored = defaults?.double(forKey: Self.inspectorKey) ?? 0
        inspectorWidth = stored > 0 ? Self.clampInspector(stored) : Self.inspectorDefault
        let projectWidth = defaults?.double(forKey: "inspector.projectWidth") ?? 0
        projectInspectorWidth = projectWidth > 0 ? Self.clampInspector(projectWidth) : 580
    }

    public func isCollapsed(_ id: ProjectID) -> Bool { !expandedProjects.contains(id) }

    public func setCollapsed(_ id: ProjectID, _ value: Bool) {
        if value { expandedProjects.remove(id) } else { expandedProjects.insert(id) }
        defaults?.set(expandedProjects.sorted(), forKey: Self.expandedKey)
    }

    public func toggleCollapsed(_ id: ProjectID) { setCollapsed(id, !isCollapsed(id)) }

    public func optionsExpanded(_ id: ProjectID) -> Bool { expandedOptions.contains(id) }

    public func setOptionsExpanded(_ id: ProjectID, _ value: Bool) {
        if value { expandedOptions.insert(id) } else { expandedOptions.remove(id) }
        defaults?.set(expandedOptions.sorted(), forKey: Self.expandedOptionsKey)
    }

    public func toggleOptionsExpanded(_ id: ProjectID) { setOptionsExpanded(id, !optionsExpanded(id)) }

    /// Live update while dragging; call `commitInspectorWidth()` when the drag ends.
    public func setInspectorWidth(_ width: Double) {
        inspectorWidth = Self.clampInspector(width)
    }

    public func setProjectInspectorWidth(_ width: Double) { projectInspectorWidth = Self.clampInspector(width) }
    public func commitProjectInspectorWidth() { defaults?.set(projectInspectorWidth, forKey: "inspector.projectWidth") }
    public func effectiveProjectInspectorWidth(total: Double) -> Double { max(min(projectInspectorWidth, total - Self.overviewMinWidth), Self.inspectorRange.lowerBound) }
    public func commitInspectorWidth() {
        defaults?.set(inspectorWidth, forKey: Self.inspectorKey)
    }

    public static func clampInspector(_ w: Double) -> Double {
        min(max(w, inspectorRange.lowerBound), inspectorRange.upperBound)
    }

    /// Width actually used in a window of `total` width: the remembered width, shrunk so the
    /// overview keeps `overviewMinWidth` (never below the range's lower bound).
    public func effectiveInspectorWidth(total: Double) -> Double {
        max(min(inspectorWidth, total - Self.overviewMinWidth), Self.inspectorRange.lowerBound)
    }
}
