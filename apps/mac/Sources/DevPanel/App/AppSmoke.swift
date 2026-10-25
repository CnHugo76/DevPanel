import AppKit
import DevPanelKit
import Foundation

/// Exercises the real SwiftUI scene/menu/window delegate without keyboard automation.
/// Only enabled explicitly, and only in a development home; never sends service actions.
@MainActor enum AppSmoke {
    private static var ran = false
    static func runIfRequested(_ c: AppController) async {
        let args = CommandLine.arguments
        if args.contains("--bench-background"), Foundation.ProcessInfo.processInfo.environment["DEVPANEL_HOME"] != nil {
            for _ in 0..<150 {
                if c.model.isConnected && c.window != nil { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            // Keep the normal scene and connection alive in the baseline's offscreen state.
            c.window?.orderOut(nil)
            return
        }
        guard !ran, let path = AppSnapshot.value("--app-smoke", args), Foundation.ProcessInfo.processInfo.environment["DEVPANEL_HOME"] != nil else { return }
        ran = true
        for _ in 0..<150 {
            if c.model.isConnected && c.window != nil { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let window = c.window else { return }
        c.showWindow()
        let before = c.model.projects.flatMap { $0.services.compactMap { $0.currentRun?.id } }
        if let p = c.model.projects.first, let s = p.services.first { c.model.select(ServiceRef(p.id, s.id)) }
        try? await Task.sleep(for: .milliseconds(300))
        var rows: [String] = ["connected=\(c.model.isConnected) selected=\(c.selected?.id ?? "nil") key-window=\(window.isKeyWindow) toggle-enabled=\(c.toggleEnabled)"]
        func visit(_ menu: NSMenu) {
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.delegate?.menuWillOpen?(menu)
            menu.update()
            for item in menu.items {
                rows.append("\(item.title) | key=\(item.keyEquivalent.debugDescription) modifiers=\(item.keyEquivalentModifierMask.rawValue) enabled=\(item.isEnabled)")
                if let child = item.submenu { visit(child) }
            }
        }
        if let menu = NSApp.mainMenu { visit(menu) }
        c.model.select(nil)
        try? await Task.sleep(for: .milliseconds(200))
        rows.append("--- no selection ---")
        if let menu = NSApp.mainMenu { visit(menu) }
        window.performClose(nil)
        rows.append("first-close-prompt=\(c.dialog == .firstClose) window-visible=\(window.isVisible)")
        c.confirmClose()
        try? await Task.sleep(for: .milliseconds(300))
        rows.append("closed=\(!window.isVisible) connected=\(c.model.isConnected)")
        c.showWindow()
        try? await Task.sleep(for: .milliseconds(300))
        rows.append("reopened=\(window.isVisible) same-runs=\(before == c.model.projects.flatMap { $0.services.compactMap { $0.currentRun?.id } })")
        rows.append("badge=\(c.model.abnormalServiceCount) dock=\(NSApp.dockTile.badgeLabel ?? "empty")")
        try? rows.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }
}
