import AppKit
import DevPanelKit
import Observation
import SwiftUI

@MainActor final class GitDiffWindowManager {
    struct Key: Hashable { var project: ProjectID; var file: GitFileKey }
    let model: AppModel
    private var windows: [Key: GitDiffController] = [:]
    init(model: AppModel) { self.model = model }
    @discardableResult func open(project: ProjectView, file: GitFileKey, show: Bool = true) -> GitDiffController {
        let scope = model.gitScope(project.id)
        let key = Key(project: scope.key, file: file)
        if let existing = windows[key] { if show { existing.window?.makeKeyAndOrderFront(nil) }; return existing }
        let controller = GitDiffController(model: model, project: project, file: file, scope: scope)
        windows[key] = controller
        controller.closed = { [weak self, weak controller] in self?.windows = self?.windows.filter { $0.value !== controller } ?? [:] }
        controller.navigate = { [weak self, weak controller] step in
            guard let self, let controller else { return }
            let files = model.git.orderedFiles(scope.key)
            guard let current = files.firstIndex(of: controller.file), files.indices.contains(current + step) else { return }
            let next = files[current + step], nextKey = Key(project: scope.key, file: next)
            if let existing = self.windows[nextKey] { existing.window?.makeKeyAndOrderFront(nil); return }
            self.windows = self.windows.filter { $0.value !== controller }
            controller.state.select(next); controller.updateTitle(); self.windows[nextKey] = controller
            Task { await controller.load(replace: true) }
        }
        controller.sideChanged = { [weak self, weak controller] in
            guard let self, let controller else { return }
            let key = Key(project: scope.key, file: controller.file)
            if let existing = self.windows[key], existing !== controller {
                existing.state.adoptReplacement(from: controller.state)
                controller.window?.close(); existing.window?.makeKeyAndOrderFront(nil); return
            }
            self.windows = self.windows.filter { $0.value !== controller }
            self.windows[key] = controller
        }
        controller.buildWindow()
        if show { controller.window?.makeKeyAndOrderFront(nil) }
        Task { await controller.load(replace: true) }
        return controller
    }
}

@Observable @MainActor final class GitDiffController: NSObject, NSWindowDelegate {
    let model: AppModel
    let project: ProjectView
    let scope: GitScope
    let state: GitDiffState
    var file: GitFileKey { state.file }
    var diff: GitDiff? { state.diff }
    var unified = false
    var expanded: Set<Int> = []
    var changeIndex = -1
    @ObservationIgnored var window: NSWindow?
    @ObservationIgnored var closed: (() -> Void)?
    @ObservationIgnored var navigate: ((Int) -> Void)?
    @ObservationIgnored private var keyMonitor: Any?
    var moveChange = 0
    init(model: AppModel, project: ProjectView, file: GitFileKey, scope: GitScope) { self.model = model; self.project = project; self.scope = scope; self.state = GitDiffState(file: file) }
    func buildWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 700, height: 400); window.isReleasedWhenClosed = false; window.delegate = self
        window.contentView = NSHostingView(rootView: GitDiffView(controller: self).tint(Theme.accent))
        self.window = window; updateTitle(); window.center()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, self.window?.isKeyWindow == true, self.model.isConnected else { return false }
                if event.keyCode == 98 { self.moveChange = event.modifierFlags.contains(.shift) ? -1 : 1; return true }
                if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "]" { self.navigate?(1); return true }
                if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "[" { self.navigate?(-1); return true }
                return false
            }
            return handled ? nil : event
        }
    }
    func updateTitle() { window?.title = "\(URL(fileURLWithPath: file.path).lastPathComponent) — \(project.name)\(scope.repositoryId.map { " / " + $0 } ?? "")（\(file.staged ? "已暂存" : "未暂存")）" }
    func windowDidBecomeKey(_ notification: Notification) { Task { await load(replace: diff == nil) } }
    func windowWillClose(_ notification: Notification) { if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }; state.invalidate(); window?.contentView = nil; window = nil; closed?() }
    @ObservationIgnored var sideChanged: (() -> Void)?
    func fetch(_ file: GitFileKey) async throws -> GitDiff {
        try await model.loadGitDiff(project.id, file: file, scope: scope)
    }
    func load(replace: Bool) async {
        guard model.isConnected else { return }
        await state.load(replace: replace, fetch: fetch)
    }
    func toggleStage() async {
        await state.toggleStage(write: { file in
            await model.stageGit(project.id, files: [file], staged: !file.staged, scope: scope)
        }, fetch: fetch)
        updateTitle(); sideChanged?()
    }

}

struct GitDiffView: View {
    @Bindable var controller: GitDiffController
    private var layout: GitDiffLayout? { controller.diff.map(GitDiffLayout.init) }
    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if !controller.model.isConnected { Text("管理服务已断开，显示上次读取的差异").foregroundStyle(Theme.amber).padding(8) }
            if controller.state.pending != nil {
                HStack { Text("文件已变化"); Button("刷新") { Task { await controller.load(replace: true) } }; Spacer() }.font(.system(size: 12)).padding(10).background(Theme.amber.opacity(0.12))
            }
            if let failure = controller.state.failure { Text(failure).foregroundStyle(Theme.red).textSelection(.enabled).padding(12) }
            if let diff = controller.diff {
                if diff.truncated { Text("差异过大，已截断；这里只显示前部内容").foregroundStyle(Theme.amber).font(.system(size: 12)).padding(8) }
                if diff.binary {
                    ContentUnavailableView("二进制文件已修改", systemImage: "doc", description: Text("旧 \(size(diff.oldSize)) → 新 \(size(diff.newSize))")).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let layout { content(layout) }
            } else {
                VStack {
                    Spacer()
                    if controller.state.failure == nil { ProgressView() } else { Button("重试") { Task { await controller.load(replace: true) } }.disabled(!controller.model.isConnected) }
                    Spacer()
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack { Text(controller.file.path).lineLimit(1).truncationMode(.middle); Spacer(); if let diff = controller.diff { Text("+\(diff.additions) −\(diff.deletions)") } }.font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text3).padding(10)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.card)
            .onChange(of: controller.state.contentGeneration) { _, _ in controller.expanded = []; controller.changeIndex = -1 }
    }
    private var toolbar: some View {
        HStack(spacing: 10) {
            Button("↑") { controller.moveChange = -1 }.help("上一个改动 ⇧F7")
            Button("↓") { controller.moveChange = 1 }.help("下一个改动 F7")
            Text(controller.changeIndex >= 0 ? "\(controller.changeIndex + 1)/\(layout?.changes.count ?? 0)" : "改动").font(.system(size: 11)).foregroundStyle(Theme.text3)
            Divider().frame(height: 16)
            Button("←") { controller.navigate?(-1) }.help("上一个文件 ⌘[")
            Button("→") { controller.navigate?(1) }.help("下一个文件 ⌘]")
            Picker("布局", selection: $controller.unified) { Text("并排").tag(false); Text("统一").tag(true) }.pickerStyle(.segmented).frame(width: 130)
            Spacer()
            if controller.state.loading { ProgressView().controlSize(.small) }
            Button(controller.file.staged ? "取消暂存" : "暂存此文件") {
                Task { await controller.toggleStage() }
            }.disabled(controller.state.mutating || controller.model.git.busy.contains(controller.project.id))
            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: controller.model.git.statuses[controller.project.id]?.repo?.root ?? controller.project.root).appendingPathComponent(controller.file.path)]) }
        }.buttonStyle(.borderless).padding(12).background(Theme.bar).disabled(!controller.model.isConnected)
    }
    private func content(_ layout: GitDiffLayout) -> some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                HStack { Text(controller.file.staged ? "HEAD" : "暂存区"); Spacer(); Text(controller.file.staged ? "暂存区" : "工作区") }.font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text3).padding(.horizontal, 14).padding(.vertical, 7).background(Theme.bar)
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(spacing: 0) {
                        ForEach(layout.chunks) { chunk in
                            if chunk.folded && !controller.expanded.contains(chunk.id) {
                                Button("⋯ 展开 \(chunk.rows.count) 行未改动 ⋯") { controller.expanded.insert(chunk.id) }.buttonStyle(.plain).foregroundStyle(Theme.text3).font(.system(size: 11)).frame(maxWidth: .infinity).padding(8).background(Theme.bar)
                            } else {
                                if chunk.folded { Button("折叠未改动段") { controller.expanded.remove(chunk.id) }.font(.caption).buttonStyle(.plain).padding(5) }
                                ForEach(chunk.rows) { row in diffRow(row).id(row.id) }
                            }
                        }
                    }.frame(minWidth: max(680, (controller.window?.contentView?.bounds.width ?? 1080)))
                }
            }.onChange(of: controller.moveChange) { _, direction in
                guard direction != 0, !layout.changes.isEmpty else { return }
                controller.changeIndex = min(max(controller.changeIndex + direction, 0), layout.changes.count - 1)
                proxy.scrollTo(layout.changes[controller.changeIndex], anchor: .top)
                controller.moveChange = 0
            }
        }
    }
    @ViewBuilder private func diffRow(_ row: GitDiffRow) -> some View {
        if controller.unified {
            if row.changed {
                if let old = row.old { cell(old, other: row.new, old: true, unified: true) }
                if let new = row.new { cell(new, other: row.old, old: false, unified: true) }
            } else { cell(row.new, other: nil, old: false, unified: true) }
        } else {
            HStack(spacing: 0) { cell(row.old, other: row.new, old: true, unified: false); Rectangle().fill(Theme.line).frame(width: 1); cell(row.new, other: row.old, old: false, unified: false) }
        }
    }
    private func cell(_ line: GitDiffLine?, other: GitDiffLine?, old: Bool, unified: Bool) -> some View {
        let changed = line?.kind == .del || line?.kind == .add
        let color = old ? Theme.red : Theme.green
        return HStack(alignment: .top, spacing: 8) {
            Text(unified ? "\(line?.oldNo.map(String.init) ?? "")  \(line?.newNo.map(String.init) ?? "")" : (old ? line?.oldNo : line?.newNo).map(String.init) ?? "")
                .foregroundStyle(Theme.text3).frame(width: unified ? 76 : 38, alignment: .trailing)
            Text(changed ? (old ? "−" : "+") : " ").foregroundStyle(changed ? color : Theme.text3)
            lineText(line, other: other, old: old).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 11.5, design: .monospaced)).padding(.vertical, 2).padding(.trailing, 10)
            .frame(maxWidth: .infinity, alignment: .leading).background(changed ? color.opacity(0.10) : .clear)
    }
    private func lineText(_ line: GitDiffLine?, other: GitDiffLine?, old: Bool) -> Text {
        guard let line else { return Text(" ") }
        guard let other, line.kind == .del || line.kind == .add, other.kind == .del || other.kind == .add else { return Text(line.text.isEmpty ? " " : line.text) }
        let pair = GitInlineText.pair(old ? line.text : other.text, old ? other.text : line.text)
        let split = old ? pair.0 : pair.1
        var changed = AttributedString(split.changed); changed.backgroundColor = (old ? Theme.red : Theme.green).opacity(0.28)
        return Text(split.prefix) + Text(changed) + Text(split.suffix)
    }
    private func size(_ size: Int?) -> String { size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "未知" }
}
