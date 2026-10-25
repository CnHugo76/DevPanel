import DevPanelKit
import Foundation

@MainActor enum MavenSnapshot {
    /// Read-only selection controls for stage B acceptance. Execution remains an explicit CLI/API action.
    static func apply(_ args: [String], model: AppModel, projectId: ProjectID) async {
        guard model.projectInspector.tabs[projectId] == .maven else { return }
        func value(_ flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
            return args[index + 1]
        }
        if let target = value("--maven-project") { model.maven.targetSelections[projectId] = target }
        await model.loadMaven(projectId)
        var selection = MavenSelection()
        selection.moduleId = value("--maven-module") ?? "."
        selection.phases = Set((value("--maven-goals") ?? "install").split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init))
        model.maven.selections[model.maven.key(projectId)] = selection
        var options = model.maven.options[model.maven.key(projectId), default: MavenOptions()]
        options.skipTests = args.contains("--maven-skip-tests")
        options.offline = args.contains("--maven-offline")
        options.alsoMake = args.contains("--maven-also-make")
        // Snapshot settings are deliberately in-memory.
        model.maven.options[model.maven.key(projectId)] = options
        if let profiles = value("--maven-profiles") {
            for profile in profiles.split(separator: ",").map(String.init) {
                let disabled = profile.hasPrefix("!")
                model.maven.profileStates[model.maven.key(projectId), default: [:]][disabled ? String(profile.dropFirst()) : profile] = disabled ? .disabled : .enabled
            }
        }
    }
}
