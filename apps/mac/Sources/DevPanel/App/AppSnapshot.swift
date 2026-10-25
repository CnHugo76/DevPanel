import DevPanelKit
import Foundation

@MainActor enum AppSnapshot {
    static func value(_ flag: String, _ args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }; return args[i + 1]
    }
    static func apply(_ args: [String], controller: AppController) async {
        if args.contains("--installation"), ProcessInfo.processInfo.environment["DEVPANEL_HOME"] != nil { controller.showInstallation = true }
        if args.contains("--onboarding"), ProcessInfo.processInfo.environment["DEVPANEL_HOME"] != nil { controller.showOnboarding = true }
        if let query = value("--search-retained", args), ProcessInfo.processInfo.environment["DEVPANEL_HOME"] != nil {
            let model = controller.model
            if let owner = model.selection.map(LogOwner.service) ?? model.selectedTaskRef.map(LogOwner.task),
               let runId = model.viewedRunId(for: owner) {
                model.inspector.retainedSearch = RetainedLogSearchTarget(runId: runId, query: query)
            }
        }
        if ProcessInfo.processInfo.environment["DEVPANEL_HOME"] != nil {
            if let id = value("--export-config", args) {
                controller.editor.portable(.export(id))
                if case .portable(let session) = controller.editor.sheet {
                    await session.loadExport()
                    if let file = value("--export-file", args) {
                        do { try session.saveExport(to: URL(fileURLWithPath: file)) }
                        catch { FileHandle.standardError.write(Data("portable export failed\n".utf8)) }
                    }
                }
            }
            if let file = value("--import-config", args) {
                controller.editor.portable(.importFile)
                if case .portable(let session) = controller.editor.sheet {
                    session.loadDocument(URL(fileURLWithPath: file))
                    if let root = value("--import-root", args) { session.setRoot(URL(fileURLWithPath: root, isDirectory: true)) }
                    if let inputs = value("--import-inputs", args) { session.loadInputs(URL(fileURLWithPath: inputs)) }
                    await session.prepare()
                    if args.contains("--import-save"), let project = await session.save() {
                        controller.editor.show(.init(tone: .ok, text: session.savedMessage ?? "已导入 · 未启动", sticky: true))
                        controller.editor.close()
                        controller.editor.locate(project.id)
                    }
                }
            }
        }
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
