import DevPanelKit
import Foundation

/// Read-only controls for the existing isolated snapshot renderer.
@MainActor enum GitSnapshot {
    static func apply(_ arguments: [String], model: AppModel, projectId: ProjectID) throws {
        if let target = AppSnapshot.value("--git-repository", arguments) { model.git.repositorySelections[projectId] = target }
        if let layout = AppSnapshot.value("--git-layout", arguments), let value = GitFileListLayout(rawValue: layout) {
            model.git.fileLayout = value
        }
        if let filter = AppSnapshot.value("--git-filter", arguments) {
            model.git.changeFilter = GitChangeKind(rawValue: filter)
        }
        if let path = AppSnapshot.value("--git-status-fixture", arguments), ProcessInfo.processInfo.environment["DEVPANEL_HOME"] != nil {
            model.git.statuses[model.gitScope(projectId).key] = try ContractCoding.decoder().decode(GitStatus.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        }
    }
}
