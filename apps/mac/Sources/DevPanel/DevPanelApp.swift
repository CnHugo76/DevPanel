import DevPanelKit
import SwiftUI

struct DevPanelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var controller: AppController
    init() {
        // Development homes never write the user's persistent UI preferences.
        let defaults: UserDefaults? = ProcessInfo.processInfo.environment["DEVPANEL_HOME"] == nil ? .standard : nil
        let model = AppModel(environment: .live(), preferences: defaults)
        let prefs = ViewPreferences(defaults: defaults)
        _controller = State(initialValue: AppController(model: model, editor: EditorPresenter(model: model), prefs: prefs, defaults: defaults))
    }
    var body: some Scene {
        Window("DevPanel", id: "main") {
            AppWindowContent(controller: controller)
                .frame(minWidth: 900, minHeight: 560).tint(Theme.accent)
                .onAppear { delegate.controller = controller; controller.connectNotifications(); controller.model.start(); controller.offerInstallation() }
        }
        .defaultSize(width: 1180, height: 760)
        .windowStyle(.hiddenTitleBar)
        .commands { AppCommands(controller: controller) }
    }
}

private struct AppWindowContent: View {
    let controller: AppController
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        RootView(model: controller.model, prefs: controller.prefs, editor: controller.editor)
            .modifier(AppBehaviorHost(controller: controller))
            .background(WindowBridge(controller: controller))
            .task { await AppSmoke.runIfRequested(controller) }
            .onAppear { controller.reopen = { openWindow(id: "main") } }
    }
}
