import AppKit
import DevPanelKit
import SwiftUI

// The log body: an AppKit `NSTextView` on TextKit 2 (ui-design v2 §1), so 50 000 lines scroll and
// select natively. Lines are appended / trimmed incrementally by diffing the session's buffer
// against what is on screen; only the viewport is laid out.

/// Colors and fonts of the log view (docs/ui-mockup-v2.html `.logs`, `.ln`).
enum LogStyle {
    static let fontSize: CGFloat = 11.5
    nonisolated(unsafe) static let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    nonisolated(unsafe) static let boldFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
    nonisolated(unsafe) static let italicFont: NSFont = italic(font)
    nonisolated(unsafe) static let boldItalicFont: NSFont = italic(boldFont)

    static let background = dynamic(dark: 0x121216, light: 0xF6F6F8)
    static let text = dynamic(dark: 0xECECF1, light: 0x1C1C22)
    static let text2 = dynamic(dark: 0xA3A3AE, light: 0x5D5D68)
    static let text3 = dynamic(dark: 0x6F6F7B, light: 0x8E8E99)
    static let red = dynamic(dark: 0xF0605A, light: 0xB42D28)
    static let green = dynamic(dark: 0x75C991, light: 0x237541)
    static let amber = dynamic(dark: 0xEAB765, light: 0x875700)
    /// Search hits (`mark`), and the current hit.
    static let match = dynamicAlpha(dark: (0xF0A43A, 0.30), light: (0xF0A43A, 0.32))
    static let currentMatch = dynamicAlpha(dark: (0xF0A43A, 0.85), light: (0xF0A43A, 0.75))

    static let ansi: [NSColor] = (0..<16).map { dynamic(dark: AnsiPalette.dark[$0], light: AnsiPalette.light[$0]) }

    nonisolated(unsafe) static let paragraph: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 4.5
        p.firstLineHeadIndent = 12
        p.headIndent = 12
        p.tailIndent = -14
        p.lineBreakMode = .byCharWrapping
        return p
    }()

    static func color(_ c: AnsiColor) -> NSColor {
        switch c {
        case .palette(let n) where n < 16: return ansi[max(n, 0)]
        case .palette(let n):
            let (r, g, b) = AnsiColor.xterm(n)
            return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        case .rgb(let r, let g, let b):
            return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        }
    }

    private static func italic(_ f: NSFont) -> NSFont {
        let d = f.fontDescriptor.withSymbolicTraits(f.fontDescriptor.symbolicTraits.union(.italic))
        return NSFont(descriptor: d, size: f.pointSize) ?? f
    }

    private static func dynamic(dark: UInt32, light: UInt32) -> NSColor {
        NSColor(name: nil) { a in
            a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(rgb: dark) : NSColor(rgb: light)
        }
    }

    private static func dynamicAlpha(dark: (UInt32, CGFloat), light: (UInt32, CGFloat)) -> NSColor {
        NSColor(name: nil) { a in
            a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(rgb: dark.0, alpha: dark.1) : NSColor(rgb: light.0, alpha: light.1)
        }
    }
}

extension NSAttributedString.Key {
    /// Marks the paragraph of a `stream == err` line (red bar on the left).
    static let logErrLine = NSAttributedString.Key("devpanel.log.err")
}

/// Commands from SwiftUI into the text view (scroll, reveal a hit, read the selection).
@MainActor
final class LogTextController {
    fileprivate weak var coordinator: LogTextView.Coordinator?
    /// The controller of the log view on screen (`--snapshot` options reach the view through it).
    static weak var active: LogTextController?

    func scrollToBottom() { coordinator?.scrollToBottom() }
    func reveal(_ match: LogMatch) { coordinator?.reveal(match) }
    var selectedText: String? { coordinator?.selectedText }
    /// Diagnostics for `--snapshot --log-bench`.
    var coordinatorForBench: LogTextView.Coordinator? { coordinator }

    func verifyFolding(expandFirst: Bool) -> String? { coordinator?.verifyFolding(expandFirst: expandFirst) }
}

struct LogTextView: NSViewRepresentable {
    let buffer: LogBuffer
    let epoch: Int
    let revision: Int
    let compactPrefixes: Bool
    let foldStacks: Bool
    let wrap: Bool
    let follow: Bool
    let matches: [LogMatch]
    let currentMatch: LogMatch?
    let searchVersion: Int
    let controller: LogTextController
    /// The user scrolled: at the bottom (follow again) or away from it (stop following).
    let onUserScroll: @MainActor (_ atBottom: Bool) -> Void
    /// Scrolled near the top: load the older page.
    let onNearTop: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeView()
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        controller.coordinator = c
        LogTextController.active = controller
        c.apply(self)
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: LogTextView?
        let scrollView = NSScrollView()
        private(set) var textView: NSTextView!
        private var layoutManager: NSTextLayoutManager!
        private var contentStorage: NSTextContentStorage!
        private let fragments = LogFragmentProvider()

        /// What is on screen: seqs and UTF-16 lengths (newline included) per line, oldest first.
        private var renderedEpoch = -1
        private var foldEpoch = -1
        private var foldRevision = -1
        private var folding = true
        private var compactPrefixes = false
        private var fullTextSeqs: Set<Int> = []
        private var expanded: Set<Int> = []
        private var regions: [LogFold] = []
        private var collapsed: [LogFold] = []
        private var displayBuffer = LogBuffer()
        private var placeholderSeqs: Set<Int> = []
        private(set) var seqs: [Int] = []
        private var lengths: [Int] = []
        /// Widest line in "cells" (non-ASCII counts 2), for the no-wrap width.
        private var widestLine = 0
        private var appliedWrap: Bool?
        private var following = true
        private var programmatic = 0
        private var highlightedRevision = -1
        private var highlightedSearch = -1
        private var highlightedCurrent: LogMatch?
        private var highlighted = false
        /// Time of the last full rebuild / incremental sync, slowest sync, sync count (diagnostics).
        private(set) var lastRebuild: Duration?
        private(set) var lastSync: Duration = .zero
        private(set) var slowestSync: Duration = .zero
        private(set) var syncCount = 0

        static let maxHighlights = 20_000

        func makeView() -> NSScrollView {
            let tv = LogNSTextView(usingTextLayoutManager: true)
            textView = tv
            layoutManager = tv.textLayoutManager
            contentStorage = tv.textContentStorage
            layoutManager.delegate = fragments
            tv.isEditable = false
            tv.isSelectable = true
            tv.isRichText = true
            tv.importsGraphics = false
            tv.allowsUndo = false
            tv.usesFindBar = false
            tv.isIncrementalSearchingEnabled = false
            tv.isAutomaticLinkDetectionEnabled = false
            tv.isAutomaticDataDetectionEnabled = false
            tv.drawsBackground = true
            tv.backgroundColor = LogStyle.background
            tv.textContainerInset = NSSize(width: 0, height: 8)
            tv.textContainer?.lineFragmentPadding = 0
            tv.textContainer?.widthTracksTextView = true
            tv.isVerticallyResizable = true
            tv.isHorizontallyResizable = false
            tv.autoresizingMask = [.width]
            tv.minSize = .zero
            tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            tv.font = LogStyle.font
            tv.delegate = self
            tv.copyText = { [weak self] in self?.selectedText }
            tv.setAccessibilityLabel("日志")

            scrollView.documentView = tv
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.drawsBackground = true
            scrollView.backgroundColor = LogStyle.background
            scrollView.borderType = .noBorder
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView)
            // Keep the bottom in view while following when the viewport shrinks (banner, footer)
            // or TextKit 2 replaces estimated line heights with real ones.
            scrollView.contentView.postsFrameChangedNotifications = true
            tv.postsFrameChangedNotifications = true
            for view in [scrollView.contentView, tv] as [NSView] {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(geometryChanged), name: NSView.frameDidChangeNotification, object: view)
            }
            return scrollView
        }

        func teardown() {
            NotificationCenter.default.removeObserver(self)
        }

        // MARK: Apply

        func apply(_ p: LogTextView) {
            following = p.follow
            if appliedWrap != p.wrap { setWrap(p.wrap) }
            let changed = syncProjection(p)
            if changed || p.searchVersion != highlightedSearch || p.revision != highlightedRevision {
                applyHighlights(p.matches, current: p.currentMatch)
                highlightedSearch = p.searchVersion
                highlightedRevision = p.revision
            }
            if changed, p.follow { scrollToBottom() }
        }

        private func syncProjection(_ p: LogTextView) -> Bool {
            let reset = foldEpoch != p.epoch
            if reset || folding != p.foldStacks { expanded.removeAll() }
            let searchSeqs = Set(p.matches.map(\.seq))
            let presentationChanged = compactPrefixes != p.compactPrefixes || fullTextSeqs != searchSeqs
            compactPrefixes = p.compactPrefixes
            fullTextSeqs = searchSeqs
            let linesChanged = reset || foldRevision != p.revision
            if linesChanged {
                regions = LogFolding.regions(in: p.buffer)
                expanded = expanded.intersection(Set(regions.map(\.first)))
                foldEpoch = p.epoch
                foldRevision = p.revision
            }
            folding = p.foldStacks
            if let match = p.currentMatch, let region = regions.first(where: { $0.contains(match.seq) }) {
                expanded.insert(region.first)
            }
            let next = folding ? regions.filter { !expanded.contains($0.first) } : []
            let foldsChanged = next != collapsed
            collapsed = next
            if linesChanged || foldsChanged || presentationChanged {
                placeholderSeqs = Set(collapsed.map(\.first))
                displayBuffer = LogFolding.project(p.buffer, collapsed: collapsed)
                if compactPrefixes {
                    let entries = displayBuffer.entries.map {
                        placeholderSeqs.contains($0.seq) || fullTextSeqs.contains($0.seq) ? $0 : $0.compacted
                    }
                    displayBuffer.reset(entries)
                }
            }
            if foldsChanged || presentationChanged {
                let anchor = captureAnchor()
                rebuild(displayBuffer, epoch: p.epoch)
                if let anchor { restore(anchor) }
                return true
            }
            return sync(displayBuffer, epoch: p.epoch)
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL, url.scheme == "devpanel-fold",
                  let seq = Int(url.host ?? ""), let p = parent else { return false }
            expanded.insert(seq)
            following = false
            p.onUserScroll(false)
            _ = syncProjection(p)
            applyHighlights(p.matches, current: p.currentMatch)
            return true
        }

        /// Brings the text in line with `buffer`. Returns whether the text changed.
        private func sync(_ buffer: LogBuffer, epoch: Int) -> Bool {
            let entries = buffer.entries
            guard let bFirst = entries.first?.seq, let bLast = entries.last?.seq else {
                if seqs.isEmpty && renderedEpoch == epoch { return false }
                rebuild(buffer, epoch: epoch)
                return true
            }
            guard renderedEpoch == epoch, let rFirst = seqs.first, let rLast = seqs.last,
                  bFirst <= rLast, bLast >= rFirst else {
                rebuild(buffer, epoch: epoch)
                return true
            }
            if bFirst == rFirst, bLast == rLast, seqs.count == buffer.count { return false }

            let syncStarted = ContinuousClock.now
            let anchor = following ? nil : captureAnchor()
            programmatic += 1
            defer { programmatic -= 1 }
            guard let storage = textView.textStorage else { return false }
            contentStorage.performEditingTransaction {
                storage.beginEditing()
                // Newest lines dropped (an older page overflowed the cap).
                if bLast < rLast {
                    var k = 0
                    var chars = 0
                    while k < seqs.count, seqs[seqs.count - 1 - k] > bLast {
                        chars += lengths[lengths.count - 1 - k]
                        k += 1
                    }
                    storage.deleteCharacters(in: NSRange(location: storage.length - chars, length: chars))
                    seqs.removeLast(k)
                    lengths.removeLast(k)
                }
                // Oldest lines dropped (cap).
                if bFirst > rFirst {
                    var k = 0
                    var chars = 0
                    while k < seqs.count, seqs[k] < bFirst {
                        chars += lengths[k]
                        k += 1
                    }
                    storage.deleteCharacters(in: NSRange(location: 0, length: chars))
                    seqs.removeFirst(k)
                    lengths.removeFirst(k)
                }
                // New lines at the end.
                if let last = seqs.last, bLast > last {
                    let from = buffer.firstIndex(seqAtLeast: last + 1)
                    let built = build(buffer.suffix(from: from))
                    storage.append(built.text)
                    seqs.append(contentsOf: built.seqs)
                    lengths.append(contentsOf: built.lengths)
                }
                // Older lines at the top.
                if let first = seqs.first, bFirst < first {
                    let n = buffer.firstIndex(seqAtLeast: first)
                    let built = build(buffer.prefix(n))
                    storage.insert(built.text, at: 0)
                    seqs.insert(contentsOf: built.seqs, at: 0)
                    lengths.insert(contentsOf: built.lengths, at: 0)
                }
                storage.endEditing()
            }
            if !appliedWrap! { updateNoWrapWidth() }
            if let anchor { restore(anchor) }
            lastSync = ContinuousClock.now - syncStarted
            slowestSync = max(slowestSync, lastSync)
            syncCount += 1
            return true
        }

        private func rebuild(_ buffer: LogBuffer, epoch: Int) {
            let started = ContinuousClock.now
            programmatic += 1
            defer { programmatic -= 1 }
            renderedEpoch = epoch
            widestLine = 0
            let built = build(buffer.entries)
            seqs = built.seqs
            lengths = built.lengths
            // Replacing a large text in place is pathologically slow on TextKit 2 (seconds for
            // 50 000 lines); emptying it first keeps a full rebuild well under a second.
            if highlighted { layoutManager.removeRenderingAttribute(.backgroundColor, for: contentStorage.documentRange) }
            if let storage = textView.textStorage, storage.length > 0 {
                contentStorage.performEditingTransaction { storage.setAttributedString(NSAttributedString()) }
            }
            contentStorage.performEditingTransaction {
                textView.textStorage?.setAttributedString(built.text)
            }
            highlighted = false
            highlightedCurrent = nil
            if !appliedWrap! { updateNoWrapWidth() }
            lastRebuild = ContinuousClock.now - started
        }

        // MARK: Building

        private struct Built {
            var text: NSMutableAttributedString
            var seqs: [Int]
            var lengths: [Int]
        }

        private static let outAttributes: [NSAttributedString.Key: Any] = [
            .font: LogStyle.font, .foregroundColor: LogStyle.text2, .paragraphStyle: LogStyle.paragraph,
        ]
        private static let errAttributes: [NSAttributedString.Key: Any] = [
            .font: LogStyle.font, .foregroundColor: LogStyle.text, .paragraphStyle: LogStyle.paragraph,
            .logErrLine: true,
        ]
        private static let sysAttributes: [NSAttributedString.Key: Any] = [
            .font: LogStyle.italicFont, .foregroundColor: LogStyle.text3, .paragraphStyle: LogStyle.paragraph,
            .obliqueness: LogStyle.italicFont == LogStyle.font ? 0.18 : 0,
        ]

        private func build(_ entries: some Collection<LogEntry>) -> Built {
            var string = ""
            var seqs: [Int] = []
            var lengths: [Int] = []
            seqs.reserveCapacity(entries.count)
            lengths.reserveCapacity(entries.count)
            for e in entries {
                let prefix = e.prefix
                string += prefix
                string += e.text.plain
                string += "\n"
                var units = 0
                var cells = 0
                for u in prefix.utf16 { units += 1; cells += u < 0x80 ? 1 : 2 }
                for u in e.text.plain.utf16 { units += 1; cells += u < 0x80 ? 1 : 2 }
                lengths.append(units + 1)
                seqs.append(e.seq)
                if cells > widestLine { widestLine = cells }
            }
            let text = NSMutableAttributedString(string: string, attributes: Self.outAttributes)
            var offset = 0
            var i = 0
            for e in entries {
                let length = lengths[i]
                let lineRange = NSRange(location: offset, length: length)
                switch e.line.stream {
                case .err: text.setAttributes(Self.errAttributes, range: lineRange)
                case .sys: text.setAttributes(Self.sysAttributes, range: lineRange)
                default: break
                }
                if placeholderSeqs.contains(e.seq), let url = URL(string: "devpanel-fold://\(e.seq)") {
                    text.addAttribute(.link, value: url, range: NSRange(location: offset, length: length - 1))
                }
                text.addAttribute(.toolTip, value: Ansi.parse(e.line.text).plain, range: NSRange(location: offset, length: length - 1))
                if !e.text.runs.isEmpty {
                    let base = offset + (e.line.stream == .sys ? LogEntry.sysPrefix.utf16.count : 0)
                    for run in e.text.runs {
                        apply(run.style, to: text, range: NSRange(location: base + run.location, length: run.length), stream: e.line.stream)
                    }
                }
                if e.line.stream != .sys, !placeholderSeqs.contains(e.seq), let level = e.presentation.level,
                   let range = e.presentation.levelRange {
                    let color: NSColor
                    switch level {
                    case .info: color = LogStyle.green
                    case .warn: color = LogStyle.amber
                    case .error: color = LogStyle.red
                    case .debug, .trace: color = LogStyle.text2
                    }
                    text.addAttributes([.foregroundColor: color, .font: LogStyle.boldFont],
                                       range: NSRange(location: offset + range.location, length: range.length))
                }
                offset += length
                i += 1
            }
            return Built(text: text, seqs: seqs, lengths: lengths)
        }

        private func apply(_ style: AnsiStyle, to text: NSMutableAttributedString, range: NSRange, stream: LogStream) {
            var attrs: [NSAttributedString.Key: Any] = [:]
            let italic = style.italic || stream == .sys
            if style.bold {
                attrs[.font] = italic ? LogStyle.boldItalicFont : LogStyle.boldFont
            } else if style.italic {
                attrs[.font] = LogStyle.italicFont
            }
            var fg = style.foreground.map(LogStyle.color)
            var bg = style.background.map(LogStyle.color)
            if style.inverse {
                let base = stream == .err ? LogStyle.text : LogStyle.text2
                (fg, bg) = (bg ?? LogStyle.background, fg ?? base)
            }
            if style.dim { fg = (fg ?? (stream == .err ? LogStyle.text : LogStyle.text2)).withAlphaComponent(0.6) }
            if let fg { attrs[.foregroundColor] = fg }
            if let bg { attrs[.backgroundColor] = bg }
            if style.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if style.strikethrough { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if !attrs.isEmpty { text.addAttributes(attrs, range: range) }
        }

        // MARK: Wrap

        private func setWrap(_ wrap: Bool) {
            appliedWrap = wrap
            guard let container = textView.textContainer else { return }
            if wrap {
                scrollView.hasHorizontalScroller = false
                textView.isHorizontallyResizable = false
                textView.autoresizingMask = [.width]
                container.widthTracksTextView = true
                let width = scrollView.contentSize.width
                textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
                container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            } else {
                scrollView.hasHorizontalScroller = true
                container.widthTracksTextView = false
                textView.isHorizontallyResizable = true
                textView.autoresizingMask = []
                updateNoWrapWidth()
            }
            if !seqs.isEmpty, following { scrollToBottom() }
        }

        private func updateNoWrapWidth() {
            guard let container = textView.textContainer else { return }
            let cell = ("0" as NSString).size(withAttributes: [.font: LogStyle.font]).width
            let width = max(scrollView.contentSize.width, min(CGFloat(widestLine) * cell + 12 + 24, 400_000))
            if abs(container.size.width - width) > 0.5 {
                container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
                textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
            }
        }

        // MARK: Search highlights

        private func applyHighlights(_ matches: [LogMatch], current: LogMatch?) {
            guard let tlm = layoutManager, let tcs = contentStorage else { return }
            if highlighted {
                tlm.removeRenderingAttribute(.backgroundColor, for: tcs.documentRange)
                highlighted = false
            }
            highlightedCurrent = nil
            guard !matches.isEmpty, !seqs.isEmpty else { return }
            var line = 0
            var lineStart = 0
            var previous = tcs.documentRange.location
            var previousOffset = 0
            var count = 0
            func range(_ loc: Int, _ len: Int) -> NSTextRange? {
                guard let start = tcs.location(previous, offsetBy: loc - previousOffset),
                      let end = tcs.location(start, offsetBy: len) else { return nil }
                previous = start
                previousOffset = loc
                return NSTextRange(location: start, end: end)
            }
            // Beyond the cap, highlight the hits around the current one (else the newest).
            var window = matches[...]
            if matches.count > Self.maxHighlights {
                let center = current.flatMap { matches.firstIndex(of: $0) } ?? matches.count - 1
                let lo = min(max(0, center - Self.maxHighlights / 2), matches.count - Self.maxHighlights)
                window = matches[lo..<(lo + Self.maxHighlights)]
            }
            for m in window {
                while line < seqs.count, seqs[line] < m.seq {
                    lineStart += lengths[line]
                    line += 1
                }
                guard line < seqs.count else { break }
                guard !placeholderSeqs.contains(m.seq), seqs[line] == m.seq, m.location + m.length < lengths[line] else { continue }
                let isCurrent = m == current
                if let r = range(lineStart + m.location, m.length) {
                    tlm.addRenderingAttribute(.backgroundColor, value: isCurrent ? LogStyle.currentMatch : LogStyle.match, for: r)
                    count += 1
                    if isCurrent { highlightedCurrent = m }
                }
            }
            highlighted = count > 0
        }

        /// Character range of a hit in the text, nil when the line is not on screen.
        private func characterRange(_ m: LogMatch) -> NSRange? {
            guard let i = lineIndex(seq: m.seq) else { return nil }
            var offset = 0
            for k in 0..<i { offset += lengths[k] }
            return NSRange(location: offset + m.location, length: m.length)
        }

        func reveal(_ m: LogMatch) {
            if let region = collapsed.first(where: { $0.contains(m.seq) }), let p = parent {
                expanded.insert(region.first)
                _ = syncProjection(p)
                applyHighlights(p.matches, current: m)
            }
            guard let r = characterRange(m) else { return }
            // Jumping to a hit stops following (new lines would scroll it away).
            if following, let parent {
                following = false
                let callback = parent.onUserScroll
                DispatchQueue.main.async { callback(false) }
            }
            programmatic += 1
            defer { programmatic -= 1 }
            textView.scrollRangeToVisible(r)
            // Leave some context above and below the hit.
            if let tcs = contentStorage, let tlm = layoutManager,
               let loc = tcs.location(tcs.documentRange.location, offsetBy: r.location),
               let frag = tlm.textLayoutFragment(for: loc) {
                let clip = scrollView.contentView
                let y = frag.layoutFragmentFrame.midY + textView.textContainerOrigin.y - clip.bounds.height / 2
                scroll(toY: y)
            }
        }

        // MARK: Scrolling

        private var documentHeight: CGFloat { textView.frame.height }

        var isAtBottom: Bool {
            let clip = scrollView.contentView
            return clip.bounds.maxY >= documentHeight - 24
        }

        func scrollToBottom() {
            guard let tlm = layoutManager, let tcs = contentStorage else { return }
            programmatic += 1
            defer { programmatic -= 1 }
            tlm.ensureLayout(for: NSTextRange(location: tcs.documentRange.endLocation))
            textView.scrollToEndOfDocument(nil)
            let clip = scrollView.contentView
            let maxY = max(0, documentHeight - clip.bounds.height)
            if clip.bounds.minY < maxY - 1 { scroll(toY: maxY) }
        }

        private func scroll(toY y: CGFloat) {
            let clip = scrollView.contentView
            let maxY = max(0, documentHeight - clip.bounds.height)
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(max(0, y), maxY)))
            scrollView.reflectScrolledClipView(clip)
        }

        private var stickScheduled = false

        @objc private func geometryChanged() {
            guard following, !stickScheduled, !seqs.isEmpty else { return }
            stickScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.stickScheduled = false
                if self.following, !self.isAtBottomExactly { self.scrollToBottom() }
            }
        }

        private var isAtBottomExactly: Bool {
            scrollView.contentView.bounds.maxY >= documentHeight - 1
        }

        @objc private func boundsChanged() {
            guard programmatic == 0, let parent else { return }
            let atBottom = isAtBottom
            if atBottom != following {
                following = atBottom
                let callback = parent.onUserScroll
                DispatchQueue.main.async { callback(atBottom) }
            }
            if scrollView.contentView.bounds.minY < 240 {
                let callback = parent.onNearTop
                DispatchQueue.main.async { callback() }
            }
        }

        // MARK: Anchor (keep the visible lines still while lines come and go above them)

        private struct Anchor {
            var seq: Int
            var delta: CGFloat
        }

        private func lineIndex(seq: Int) -> Int? {
            var lo = 0
            var hi = seqs.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if seqs[mid] < seq { lo = mid + 1 } else { hi = mid }
            }
            return lo < seqs.count && seqs[lo] == seq ? lo : nil
        }

        private func captureAnchor() -> Anchor? {
            guard let tlm = layoutManager, let tcs = contentStorage, !seqs.isEmpty else { return nil }
            let clip = scrollView.contentView.bounds
            let origin = textView.textContainerOrigin
            guard let frag = tlm.textLayoutFragment(for: CGPoint(x: 0, y: max(0, clip.minY - origin.y))) else { return nil }
            let offset = tcs.offset(from: tcs.documentRange.location, to: frag.rangeInElement.location)
            var acc = 0
            var i = 0
            while i < lengths.count, acc + lengths[i] <= offset {
                acc += lengths[i]
                i += 1
            }
            guard i < seqs.count else { return nil }
            return Anchor(seq: seqs[i], delta: clip.minY - (frag.layoutFragmentFrame.minY + origin.y))
        }

        private func restore(_ anchor: Anchor) {
            guard let tlm = layoutManager, let tcs = contentStorage else { return }
            let i = lineIndex(seq: anchor.seq) ?? 0
            var offset = 0
            for k in 0..<min(i, lengths.count) { offset += lengths[k] }
            guard let loc = tcs.location(tcs.documentRange.location, offsetBy: offset) else { return }
            tlm.ensureLayout(for: NSTextRange(location: loc))
            guard let frag = tlm.textLayoutFragment(for: loc) else { return }
            programmatic += 1
            defer { programmatic -= 1 }
            scroll(toY: frag.layoutFragmentFrame.minY + textView.textContainerOrigin.y + (lineIndex(seq: anchor.seq) == nil ? 0 : anchor.delta))
        }

        // MARK: Selection / tooltips

        var selectedText: String? {
            let r = textView.selectedRange()
            guard r.length > 0, let storage = textView.textStorage, NSMaxRange(r) <= storage.length else { return nil }
            guard let parent else { return nil }
            return LogFolding.selectedText(range: r, display: displayBuffer, raw: parent.buffer, collapsed: collapsed)
        }

        func textView(_ textView: NSTextView, willDisplayToolTip tooltip: String, forCharacterAt characterIndex: Int) -> String? {
            guard let date = Timestamps.date(tooltip) else { return tooltip }
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            return "采集于 " + f.string(from: date)
        }

        // MARK: Bench (diagnostics)

        /// Snapshot smoke uses the same delegate path as clicking a fold link.
        func verifyFolding(expandFirst: Bool) -> String? {
            guard let parent, let storage = textView.textStorage else { return nil }
            let expected = parent.buffer.entries.map { $0.displayText + "\n" }.joined()
            textView.setSelectedRange(NSRange(location: 0, length: storage.length))
            let copyOK = selectedText == expected
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            let before = collapsed.count
            var clicked = false
            if expandFirst, let region = collapsed.first, let url = URL(string: "devpanel-fold://\(region.first)") {
                clicked = self.textView(textView, clickedOnLink: url, at: 0)
            }
            let hitVisible = parent.currentMatch.map { lineIndex(seq: $0.seq) != nil && !placeholderSeqs.contains($0.seq) } ?? true
            return "folds: \(before) → \(collapsed.count) · click \(clicked) · raw-copy \(copyOK) · search-visible \(hitVisible) · rendered \(seqs.count)/\(parent.buffer.count)"
        }

        /// Scrolls like the user would (not programmatic: following stops).
        func scrollUp(by points: CGFloat) {
            scroll(toY: scrollView.contentView.bounds.minY - points)
        }

        /// Rebuilds the whole text from `buffer` (diagnostics).
        func benchRebuild(_ buffer: LogBuffer) -> Duration? {
            displayBuffer = LogFolding.project(buffer, collapsed: collapsed)
            rebuild(displayBuffer, epoch: renderedEpoch)
            if following { scrollToBottom() }
            return lastRebuild
        }

        /// Applies search highlights once (diagnostics).
        func benchHighlights(_ matches: [LogMatch], current: LogMatch?) -> Duration {
            let started = ContinuousClock.now
            applyHighlights(matches, current: current)
            return ContinuousClock.now - started
        }

        /// Scrolls through the document in `steps` jumps and forces a display each time.
        func benchScroll(steps: Int) -> Duration {
            let started = ContinuousClock.now
            let clip = scrollView.contentView
            for s in 0...steps {
                let y = (documentHeight - clip.bounds.height) * CGFloat(s) / CGFloat(max(steps, 1))
                programmatic += 1
                scroll(toY: y)
                programmatic -= 1
                scrollView.layoutSubtreeIfNeeded()
                scrollView.displayIfNeeded()
            }
            return ContinuousClock.now - started
        }
    }
}

/// `NSTextView` without the find panel and with copy limited to plain text.
final class LogNSTextView: NSTextView {
    var copyText: (() -> String?)?
    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard let text = copyText?() else { return false }
        pboard.clearContents()
        return pboard.setString(text, forType: .string)
    }

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }
}

/// Picks the layout fragment class: `err` lines get a red bar on the left.
final class LogFragmentProvider: NSObject, NSTextLayoutManagerDelegate {
    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        if let p = textElement as? NSTextParagraph, p.attributedString.length > 0,
           p.attributedString.attribute(.logErrLine, at: 0, effectiveRange: nil) != nil {
            return ErrLineFragment(textElement: textElement, range: textElement.elementRange)
        }
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }
}

/// A line from stderr: 2 pt red bar at the leading edge (mockup `.ln.err`).
final class ErrLineFragment: NSTextLayoutFragment {
    /// The bar sits at the container's leading edge, left of the paragraph indent.
    override var renderingSurfaceBounds: CGRect {
        super.renderingSurfaceBounds.union(CGRect(x: -layoutFragmentFrame.minX, y: 0, width: 2, height: layoutFragmentFrame.height))
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        context.saveGState()
        context.setFillColor(LogStyle.red.cgColor)
        let x = point.x - layoutFragmentFrame.minX
        context.fill(CGRect(x: x, y: point.y, width: 2, height: max(layoutFragmentFrame.height, 1)))
        context.restoreGState()
        super.draw(at: point, in: context)
    }
}
