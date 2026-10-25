import AppKit
import DevPanelKit
import SwiftUI

/// NSView.visibleRect includes scroll clipping; no periodic geometry timer is needed.
struct GitVisibility: NSViewRepresentable {
    let coordinator: GitRefreshCoordinator?
    let project: ProjectID
    var page = false
    var file: GitFileKey?
    func makeNSView(context: Context) -> Probe { let v = Probe(); configure(v); return v }
    func updateNSView(_ view: Probe, context: Context) { configure(view) }
    private func configure(_ view: Probe) {
        let token = view.token
        view.callback = { visible in coordinator?.set(token, project: project, page: page, file: file, visibility: visible) }
        view.evaluate()
    }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.callback?(.hidden); view.callback = nil; view.stop() }
    final class Probe: NSView {
        let token = UUID()
        var callback: ((GitSurfaceVisibility) -> Void)?
        private var observers: [NSObjectProtocol] = []
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); observe(); evaluate() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); observe(); evaluate() }
        override func layout() { super.layout(); evaluate() }
        func stop() { observers.forEach(NotificationCenter.default.removeObserver); observers = [] }
        private func observe() {
            stop()
            var parent = superview
            while let v = parent { if let clip = v as? NSClipView { clip.postsBoundsChangedNotifications = true }; parent = v.superview }
            for name in [NSView.boundsDidChangeNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification, NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.evaluate() }
                })
            }
        }
        func evaluate() {
            let visible = GitSurfaceVisibility(viewportVisible: !isHiddenOrHasHiddenAncestor && !visibleRect.isEmpty,
                windowForeground: window.map { $0.isVisible && $0.isKeyWindow && !$0.isMiniaturized } == true, applicationActive: NSApp.isActive)
            callback?(visible)
        }
    }
}
