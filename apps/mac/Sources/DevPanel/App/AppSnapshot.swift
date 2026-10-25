import DevPanelKit
import Foundation

@MainActor enum AppSnapshot {
    static func value(_ flag: String, _ args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }; return args[i + 1]
    }
    static func apply(_ args: [String], controller: AppController) async {
        if args.contains("--installation"), ProcessInfo.processInfo.environment["DEVPANEL_HOME"] != nil { controller.showInstallation = true }
        if let dialog = value("--app-dialog", args) { controller.dialog = AppController.Dialog(rawValue: dialog) }
        if let target = value("--notification-open", args) {
            let parts = target.split(separator: "/", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                // Routes through the notification click handler without contacting Notification Center.
                controller.openNotification(ServiceRef(parts[0], parts[1]))
                controller.model.syncLogSession()
            }
        }
        if args.contains("--confirm-remove"), let id = value("--remove-project", args) {
            do { try await controller.model.removeProject(id); controller.editor.close() }
            catch { controller.editor.show(.init(tone: .warn, text: error.localizedDescription, sticky: true)) }
        }
        if args.contains("--shutdown-daemon") { await controller.shutdown() }
        if args.contains("--start-daemon") { await controller.model.startDaemon() }
        if let path = value("--launch-cli", args) {
            // Explicit temporary shim for acceptance, uses the production launcher.
            do {
                _ = try await DaemonLauncher(cliPath: URL(fileURLWithPath: path)).start()
                controller.model.retryNow()
            } catch { controller.editor.show(.init(tone: .warn, text: error.localizedDescription, sticky: true)) }
        }
    }
    static func report(_ args: [String], model: AppModel) {
        struct Report: Encodable {
            var status: String
            var projects: [ProjectView]
            var stats: StatsSnapshot?
            var runs: [RunID: RunDetail]
            var badge: Int
            var viewedRun: RunID?
            var logLines: Int
        }
        guard let path = value("--report-state", args) else { return }
        let report = Report(status: model.connection.status.rawValue, projects: model.projects, stats: model.stats,
                            runs: model.inspector.runDetails, badge: model.abnormalServiceCount,
                            viewedRun: model.selection.flatMap { model.viewedRunId(for: $0) }, logLines: model.inspector.logs.buffer.count)
        do { try ContractCoding.encoder().encode(report).write(to: URL(fileURLWithPath: path)) }
        catch { FileHandle.standardError.write(Data("report: \(error.localizedDescription)\n".utf8)) }
    }
}
