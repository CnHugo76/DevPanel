import AppKit
import DevPanelKit
import SwiftUI

@Observable @MainActor
final class AppController {
    enum Dialog: String, Identifiable { case firstClose, shutdown; var id: String { rawValue } }
    let model: AppModel
    let editor: EditorPresenter
    @ObservationIgnored lazy var gitRefresh = GitRefreshCoordinator(model: model)
    @ObservationIgnored lazy var gitWindows = GitDiffWindowManager(model: model)
    let prefs: ViewPreferences
    var dialog: Dialog?
    var forceStop: ForceStopTarget?
    var shutdownBusy = false
    var shutdownError: String?
    var showInstallation = false
    var showOnboarding = false
    var openInstallationAfterGuide = false
    var installationDirectory: String
    var overviewFocus = 0
    var logFocus = 0
    var revealProject: ProjectID?
    var reopen: (() -> Void)?
    weak var window: NSWindow?
    private var pendingNotification: ServiceRef?
    private var lastSelection: ServiceRef?
    private let defaults: UserDefaults?
    private var closeHintSeen: Bool
    private var notifications: AppNotifications?

    init(model: AppModel, editor: EditorPresenter, prefs: ViewPreferences, defaults: UserDefaults? = .standard) {
        self.model = model; self.editor = editor; self.prefs = prefs; self.defaults = defaults
        closeHintSeen = defaults?.bool(forKey: "window.closeHintSeen") ?? false
        if let home = ProcessInfo.processInfo.environment["DEVPANEL_HOME"] {
            installationDirectory = URL(fileURLWithPath: home).appendingPathComponent("bin").path
        } else {
            installationDirectory = defaults?.string(forKey: "installation.directory")
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path
        }
    }
    func connectNotifications() {
        guard notifications == nil else { return }
        notifications = AppNotifications(controller: self)
        notifications?.start()
    }
    var bundledRuntime: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/runtime") }
    var hasBundledCLI: Bool { FileManager.default.isExecutableFile(atPath: bundledRuntime.appendingPathComponent("bin/devpanel").path) }
    var onboardingGuide: OnboardingGuide {
        OnboardingGuide(runtime: hasBundledCLI ? bundledRuntime : nil,
                        directory: URL(fileURLWithPath: installationDirectory),
                        isolatedHome: ProcessInfo.processInfo.environment["DEVPANEL_HOME"])
    }
    func rememberInstallationDirectory(_ directory: URL) {
        installationDirectory = directory.path
        if ProcessInfo.processInfo.environment["DEVPANEL_HOME"] == nil {
            defaults?.set(directory.path, forKey: "installation.directory")
        }
    }
    func guideDismissed() {
        if openInstallationAfterGuide { openInstallationAfterGuide = false; showInstallation = true }
    }
    func offerInstallation() {
        guard Foundation.ProcessInfo.processInfo.environment["DEVPANEL_HOME"] == nil,
              hasBundledCLI, defaults?.bool(forKey: "installation.seen") != true else { return }
        showInstallation = true
    }
    func finishInstallation() {
        defaults?.set(true, forKey: "installation.seen")
        showInstallation = false
    }
    func requestClose() -> Bool {
        if closeHintSeen { return true }
        dialog = .firstClose
        return false
    }
    func confirmClose() {
        closeHintSeen = true; defaults?.set(true, forKey: "window.closeHintSeen")
        dialog = nil
        window?.close()
    }
    func showWindow() {
        if let window { window.makeKeyAndOrderFront(nil) } else { reopen?() }
        NSApp.activate(ignoringOtherApps: true)
    }
    func openNotification(_ ref: ServiceRef) {
        showWindow(); pendingNotification = ref; resolveNotification()
    }
    func resolveNotification() {
        guard model.isConnected, let ref = pendingNotification else { return }
        pendingNotification = nil
        model.openLogs(ref)
        if model.selection == ref { model.chooseRun(nil, for: ref) }
        else { editor.show(.init(tone: .info, text: "通知对应的服务已被移除")) }
    }
    func requestShutdown() {
        guard model.isConnected, !shutdownBusy else { return }
        shutdownError = nil
        if model.projects.contains(where: { !RemovalCheck($0).allowed }) { dialog = .shutdown }
        else { Task { await shutdown() } }
    }
    func shutdown() async {
        guard !shutdownBusy else { return }
        shutdownBusy = true; shutdownError = nil
        defer { shutdownBusy = false }
        do { try await model.stopAllAndShutdown(); dialog = nil }
        catch { shutdownError = error.localizedDescription; dialog = .shutdown }
    }
    var selected: ServiceView? { model.selection.flatMap { model.project($0.projectId)?.service($0.serviceId) } }
    var toggleAction: ActionKind { selected?.state.isStartable == true ? .start : .stop }
    var toggleEnabled: Bool {
        guard let ref = model.selection else { return false }
        for action in [ActionKind.start, .stop] {
            if model.isPending(ActionRequest(projectId: ref.projectId, serviceIds: [ref.serviceId], action: action)) { return false }
        }
        return enabled(toggleAction)
    }
    func enabled(_ action: ActionKind) -> Bool {
        guard model.isConnected, let service = selected, let ref = model.selection else { return false }
        let a = service.availableActions
        let allowed: Bool
        switch action { case .start: allowed = a.start; case .stop: allowed = a.stop; case .restart: allowed = a.restart; case .forceStop: allowed = a.forceStop; case .other: allowed = false }
        // Stop remains available to cancel a restart, but never resends an in-flight stop.
        if action != .stop && model.hasPendingAction(projectId: ref.projectId, serviceId: ref.serviceId) { return false }
        return allowed && !model.isPending(ActionRequest(projectId: ref.projectId, serviceIds: [ref.serviceId], action: action))
    }
    func run(_ action: ActionKind) {
        guard enabled(action), let ref = model.selection else { return }
        if action == .forceStop { forceStop = ForceStopTarget(projectId: ref.projectId, serviceIds: [ref.serviceId]) }
        else { Task { await model.runAction(ActionRequest(projectId: ref.projectId, serviceIds: [ref.serviceId], action: action)) } }
    }
    func toggleInspector() {
        if let ref = model.selection { lastSelection = ref; model.select(nil) }
        else if model.hasInspectorSelection { model.select(nil); model.syncLogSession() }
        else if let ref = lastSelection { model.select(ref) }
        else if let p = model.projects.first, let s = p.services.first { model.select(ServiceRef(p.id, s.id)) }
    }
    func focusSearch() {
        if model.selectedTaskRef != nil || model.selection != nil && model.inspector.tab == .logs { logFocus += 1 }
        else { overviewFocus += 1 }
    }
}

struct AppDialogView: View {
    @Bindable var controller: AppController
    let dialog: AppController.Dialog
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(dialog == .firstClose ? "关闭窗口后继续管理" : "停止所有服务并退出管理服务？").font(.headline)
            Text(dialog == .firstClose ? "DevPanel 会在后台继续管理项目，可从 Dock 重新打开" : "将等待所有受管服务停止后退出管理服务。停止失败时会保留管理服务，并显示原因。")
                .foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            if let error = controller.shutdownError, dialog == .shutdown { Text(error).foregroundStyle(Theme.red) }
            HStack {
                Spacer()
                if controller.shutdownBusy { ProgressView().controlSize(.small) }
                Button("取消") { controller.dialog = nil }.disabled(controller.shutdownBusy)
                Button(dialog == .firstClose ? "知道了，关闭窗口" : "停止并退出管理服务") {
                    if dialog == .firstClose { controller.confirmClose() }
                    else { Task { await controller.shutdown() } }
                }.disabled(controller.shutdownBusy || (dialog == .shutdown && !controller.model.isConnected))
            }
        }.font(.system(size: 12.5)).padding(20).frame(width: 440).background(Theme.card)
    }
}

struct AppBehaviorHost: ViewModifier {
    @Bindable var controller: AppController
    @Environment(\.inlineSheets) private var inline
    @State private var timeVisible = true
    func body(content: Content) -> some View {
        content.environment(controller)
            .modifier(PolicySnapshotHost(model: controller.model))
            .modifier(RetainedLogSearchHost(model: controller.model))
            .environment(\.timeVisible, timeVisible)
            .background(TimeVisibility(model: controller.model, visible: $timeVisible))
            .onChange(of: controller.model.isConnected) { _, _ in controller.gitRefresh.reconcile() }
            .forceStopConfirmation(model: controller.model, target: $controller.forceStop)
            .sheet(isPresented: inline ? .constant(false) : $controller.showInstallation) { InstallationSheet(controller: controller) }
            .sheet(isPresented: inline ? .constant(false) : $controller.showOnboarding, onDismiss: controller.guideDismissed) { OnboardingSheet(controller: controller) }
            .sheet(item: inline ? .constant(nil) : $controller.dialog) { dialog in AppDialogView(controller: controller, dialog: dialog).interactiveDismissDisabled(controller.shutdownBusy) }
            .overlay {
                if inline, controller.showInstallation {
                    ZStack { Color.black.opacity(0.28); InstallationSheet(controller: controller).clipShape(RoundedRectangle(cornerRadius: 12)) }
                }
                if inline, controller.showOnboarding {
                    ZStack { Color.black.opacity(0.28); OnboardingSheet(controller: controller).clipShape(RoundedRectangle(cornerRadius: 12)) }
                }
                if inline, let dialog = controller.dialog {
                    ZStack { Color.black.opacity(0.28); AppDialogView(controller: controller, dialog: dialog).clipShape(RoundedRectangle(cornerRadius: 12)) }
                }
            }
    }
}
