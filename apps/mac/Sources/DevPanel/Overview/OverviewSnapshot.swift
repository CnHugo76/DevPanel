import AppKit

/// Acceptance-only scrolling of the actual overview, after SwiftUI has laid it out.
@MainActor enum OverviewSnapshot {
    static func scroll(_ arguments: [String], window: NSWindow) throws {
        guard let raw = AppSnapshot.value("--overview-scroll", arguments) else { return }
        guard let offset = Double(raw), offset.isFinite, offset >= 0 else {
            throw SnapshotError("--overview-scroll 需要非负的点数")
        }
        guard let content = window.contentView else { throw SnapshotError("没有内容视图") }
        content.layoutSubtreeIfNeeded()
        guard let scroll = firstScrollView(in: content), let document = scroll.documentView else {
            throw SnapshotError("没有可滚动的总览")
        }
        let y = min(offset, max(0, document.frame.height - scroll.contentView.bounds.height))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        content.layoutSubtreeIfNeeded()
        FileHandle.standardOutput.write(Data("overview-scroll: \(scroll.contentView.bounds.origin.y) pt\n".utf8))
    }

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews {
            if let scroll = firstScrollView(in: child) { return scroll }
        }
        return nil
    }
}
