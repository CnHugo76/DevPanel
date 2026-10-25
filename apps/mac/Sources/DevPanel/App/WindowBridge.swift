import AppKit
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var controller: AppController?
    func applicationWillTerminate(_ notification: Notification) { controller?.model.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.showWindow()
        return false
    }
}

/// Preserve SwiftUI's window delegate callbacks; intercept only the initial close question.
struct WindowBridge: NSViewRepresentable {
    let controller: AppController
    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }
    func makeNSView(context: Context) -> BridgeView {
        let view = BridgeView(); view.attach = { [weak coordinator = context.coordinator] in coordinator?.attach($0) }; return view
    }
    func updateNSView(_ view: BridgeView, context: Context) { if let window = view.window { context.coordinator.attach(window) } }
    final class BridgeView: NSView {
        var attach: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if let window { attach?(window) } }
    }
    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        let controller: AppController
        nonisolated(unsafe) weak var previous: (any NSWindowDelegate)?
        init(controller: AppController) { self.controller = controller }
        func attach(_ window: NSWindow) {
            controller.window = window
            guard window.delegate !== self else { return }
            previous = window.delegate; window.delegate = self
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            controller.requestClose() && (previous?.windowShouldClose?(sender) ?? true)
        }
        override func responds(to selector: Selector!) -> Bool { super.responds(to: selector) || (previous?.responds(to: selector) == true) }
        override func forwardingTarget(for selector: Selector!) -> Any? { previous?.responds(to: selector) == true ? previous : super.forwardingTarget(for: selector) }
    }
}
