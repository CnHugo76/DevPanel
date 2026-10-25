import AppKit
import DevPanelKit
import SwiftUI

private struct TimeVisibleKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var timeVisible: Bool {
        get { self[TimeVisibleKey.self] }
        set { self[TimeVisibleKey.self] = newValue }
    }
}

/// A window-local visibility bridge. Event reception remains owned by AppModel.
struct TimeVisibility: NSViewRepresentable {
    let model: AppModel
    @Binding var visible: Bool
    func makeNSView(context: Context) -> VisibilityView {
        let view = VisibilityView()
        view.changed = { value in
            if visible != value { visible = value }
            model.toolResources.setVisible(value, model: model)
        }
        return view
    }
    func updateNSView(_ view: VisibilityView, context: Context) {}
    static func dismantleNSView(_ view: VisibilityView, coordinator: ()) { view.stop() }

    final class VisibilityView: NSView {
        var changed: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window else { return }
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification,
                         NSApplication.didHideNotification, NSApplication.didUnhideNotification,
                         NSWorkspace.didWakeNotification] {
                let center = name == NSWorkspace.didWakeNotification ? NSWorkspace.shared.notificationCenter : NotificationCenter.default
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self, weak window] note in
                    let closing = note.name == NSWindow.willCloseNotification && (note.object as? NSWindow) === window
                    MainActor.assumeIsolated { self?.update(closing: closing) }
                })
            }
            // Defer until attachment is complete; avoid mutating SwiftUI state in a view update.
            Task { @MainActor [weak self] in self?.update() }
        }
        private func update(closing: Bool = false) {
            let value = !closing && !NSApp.isHidden && window?.isMiniaturized == false
                && window?.occlusionState.contains(.visible) == true
            changed?(value)
        }
        func stop() {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
                NSWorkspace.shared.notificationCenter.removeObserver(observer)
            }
            observers = []
        }
    }
}
