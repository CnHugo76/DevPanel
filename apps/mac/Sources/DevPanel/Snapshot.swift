import AppKit
import DevPanelKit
import SwiftUI

/// `DevPanel --snapshot <out.png> [options]` — renders the window content to a PNG and exits.
///
/// Connects like the app (same `AppModel`, `DEVPANEL_HOME` respected), waits for the first
/// snapshot, one `stats` event and every project's config, optionally performs actions, then
/// draws the window's own view hierarchy with `cacheDisplay` (no screen capture, no Screen
/// Recording permission). The window is never shown to the user (alpha 0, ignores the mouse).
///
/// Options:
///   --select <projectId>/<serviceId>   open the inspector on that service (compact overview)
///   --appearance light|dark            default: the system appearance
///   --size <w>x<h>                     window size in points, default 1180x760
///   --perform <action>:<projectId>[/<serviceId>]
///                                      run an action first (start|stop|restart|force-stop) and
///                                      wait for it to finish; repeatable
///   --delay <sec>                      wait this long before drawing (e.g. while a disconnect
///                                      is being simulated), default 0
///   --timeout <sec>                    max wait for connect / stats / operations, default 15
///   --query <text>                     prefill the search field
///   --tab, --log-run, --log-search, --log-scroll-up, --log-bench
///                                      inspector options, see `InspectorSnapshot`
///   --open-editor, --editor-*, --remove-project
///                                      project editor / remove sheets (see EditorSnapshot)
///   --git-layout flat|tree|directories, --git-filter <status>, --git-status-fixture <json>
///                                      read-only Git presentation controls (isolated fixtures)
///
/// Exit codes: 0 written · 1 bad arguments or write failure · 3 not connected (still written).
@MainActor
enum Snapshot {
    struct Options {
        var output: URL
        var select: ServiceRef?
        var projectId: ProjectID?
        var projectTab: ProjectInspectorTab?
        var actionId: String?
        var dark: Bool?
        var size = NSSize(width: 1180, height: 760)
        var perform: [ActionRequest] = []
        var delay: TimeInterval = 0
        var timeout: TimeInterval = 15
        var query = ""
        var inspector = InspectorSnapshot.Options()
        var editor = EditorSnapshot.Options()
    }

    static func main(arguments: [String]) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            let code = await run(arguments: arguments)
            exit(code)
        }
        app.run()
        exit(0)
    }

    static func run(arguments: [String]) async -> Int32 {
        let options: Options
        do {
            options = try parse(arguments)
        } catch {
            err("snapshot: \(error)")
            return 1
        }
        if let dark = options.dark {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        }

        let home = DaemonHome.resolve()
        let model = AppModel(environment: .live(home: home))
        let prefs = ViewPreferences(defaults: nil)
        prefs.detailed = AppSnapshot.value("--layout", arguments) == "detail"
        for i in arguments.indices where arguments[i] == "--collapse" && i + 1 < arguments.count {
            prefs.setCollapsed(arguments[i + 1], true)
        }
        for i in arguments.indices where arguments[i] == "--expand-options" && i + 1 < arguments.count {
            prefs.setOptionsExpanded(arguments[i + 1], true)
        }
        model.inspector.foldStacks = !arguments.contains("--log-expand-all")
        model.inspector.compactPrefixes = !arguments.contains("--log-full-prefix")
        let presenter = EditorPresenter(model: model)
        let optionPresenter = OptionPresenter(model: model)
        let appController = AppController(model: model, editor: presenter, prefs: prefs, defaults: nil)
        let window = makeWindow(model: model, prefs: prefs, presenter: presenter, optionPresenter: optionPresenter, appController: appController, options: options)
        var renderWindow = window
        var benchFocus: SnapshotBenchFocus?
        defer { benchFocus?.stop() }
        model.start()

        let deadline = Date().addingTimeInterval(options.timeout)
        await waitUntil(deadline) {
            // The daemon only samples while something runs.
            let needsStats = model.projects.contains { $0.services.contains { $0.currentRun != nil } || $0.actions.contains { $0.currentRun != nil } || $0.maven?.currentRun != nil }
            return model.isConnected && (!needsStats || model.lastStatsAt != nil) && model.configsLoaded
        }
        out("status:  \(model.connection.status.rawValue) · \(model.projects.count) 个项目 · stats \(model.lastStatsAt == nil ? "无" : "有") · 配置 \(model.configsLoaded ? "已读取" : "未齐")")

        if let raw = AppSnapshot.value("--before-actions-delay", arguments), let seconds = Double(raw), seconds > 0 {
            try? await Task.sleep(for: .seconds(seconds))
        }
        for request in options.perform {
            await model.runAction(request)
            let opDeadline = Date().addingTimeInterval(options.timeout)
            await waitUntil(opDeadline) {
                model.actionResults[request.projectId]?.error != nil
                    || model.finishedOperation(for: request.projectId) != nil
            }
            let op = model.finishedOperation(for: request.projectId)
            out("perform: \(request.action.rawValue) \(request.projectId)\(request.serviceIds.map { "/" + $0.joined(separator: ",") } ?? "") → \(op?.state.rawValue ?? model.actionResults[request.projectId]?.error?.code.rawValue ?? "未结束")")
        }
        if let id = options.projectId {
            model.selectProject(id, tab: options.projectTab)
            if let action = options.actionId { model.projectInspector.actionChoice[id] = action }
            prefs.setProjectInspectorWidth(580)
            await MavenSnapshot.apply(arguments, model: model, projectId: id)
            if options.projectTab == .git {
                await model.refreshGit(id)
                await model.refreshGitCounts(id, files: Set(model.git.orderedFiles(id).prefix(16)))
                do { try GitSnapshot.apply(arguments, model: model, projectId: id) }
                catch { err("snapshot: \(error.localizedDescription)"); return 1 }
                if let message = AppSnapshot.value("--git-message", arguments) { model.git.messages[id] = message }
                if let path = AppSnapshot.value("--git-diff", arguments), let project = model.project(id) {
                    let diff = appController.gitWindows.open(project: project, file: GitFileKey(path: path, staged: arguments.contains("--git-staged")), show: false)
                    diff.unified = arguments.contains("--git-unified")
                    await diff.load(replace: true)
                    if arguments.contains("--git-expand-all"), let value = diff.diff { diff.expanded = Set(GitDiffLayout(value).chunks.map(\.id)) }
                    if let diffWindow = diff.window {
                        diffWindow.alphaValue = 0; diffWindow.ignoresMouseEvents = true; diffWindow.orderFrontRegardless(); renderWindow = diffWindow
                    }
                }
            }
            await InspectorSnapshot.apply(options.inspector, model: model, timeout: options.timeout)
        }
        if let select = options.select {
            model.select(select)
            if model.selection != select { err("snapshot: 找不到服务 \(select.projectId)/\(select.serviceId)") }
            await InspectorSnapshot.apply(options.inspector, model: model, timeout: options.timeout)
        }
        for line in await EditorSnapshot.apply(options.editor, model: model, presenter: presenter, timeout: options.timeout) {
            out(line)
        }
        await AppSnapshot.apply(arguments, controller: appController)
        try? await OptionSnapshot.apply(arguments, model: model, presenter: optionPresenter)
        // Explicit acceptance harness only; ordinary snapshots remain invisible.
        if arguments.contains("--bench-visible") || arguments.contains("--bench-hidden") {
            benchFocus = SnapshotBenchFocus(window: renderWindow)
        }
        if arguments.contains("--bench-visible") {
            NSApp.setActivationPolicy(.regular)
            renderWindow.alphaValue = 1; renderWindow.ignoresMouseEvents = false
            renderWindow.center()
            renderWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        }
        if arguments.contains("--bench-hidden") { renderWindow.orderOut(nil); NSApp.hide(nil) }
        if arguments.contains("--bench-background"), ProcessInfo.processInfo.environment["DEVPANEL_HOME"] != nil { renderWindow.orderOut(nil) }
        if arguments.contains("--bench-minimized") { renderWindow.miniaturize(nil) }
        benchFocus?.record("before-delay")
        if options.delay > 0 {
            try? await Task.sleep(for: .seconds(options.delay))
            out("after delay: \(model.connection.status.rawValue)")
        }
        benchFocus?.record("after-delay")
        await InspectorSnapshot.beforeRender(options.inspector, model: model)
        // Let SwiftUI apply the latest state.
        try? await Task.sleep(for: .milliseconds(400))

        if arguments.contains("--verify-layout-switch") {
            let before = LogTextController.active?.coordinatorForBench
            let selection = model.selection
            let run = model.inspector.logs.target
            let query = model.inspector.search.query
            prefs.detailed.toggle()
            try? await Task.sleep(for: .milliseconds(200))
            prefs.detailed.toggle()
            try? await Task.sleep(for: .milliseconds(200))
            let same = before != nil && before === LogTextController.active?.coordinatorForBench
            out("layout-switch: same-text-view \(same) · same-selection \(selection == model.selection) · same-run \(run == model.inspector.logs.target) · same-search \(query == model.inspector.search.query)")
        }
        if arguments.contains("--verify-folding") || arguments.contains("--log-expand-first") {
            if let report = LogTextController.active?.verifyFolding(expandFirst: arguments.contains("--log-expand-first")) { out(report) }
        }
        let connected = model.isConnected
        do {
            try OverviewSnapshot.scroll(arguments, window: renderWindow)
            try? await Task.sleep(for: .milliseconds(200))
            try render(renderWindow, to: options.output)
        } catch {
            err("snapshot: \(error.localizedDescription)")
            return 1
        }
        benchFocus?.record("after-render")
        out("written: \(options.output.path)")
        if let second = options.inspector.second {
            try? await Task.sleep(for: .seconds(options.inspector.secondDelay))
            do {
                try render(renderWindow, to: second)
                out("written: \(second.path) (+\(options.inspector.secondDelay) s, \(model.connection.status.rawValue))")
            } catch {
                err("snapshot: \(error.localizedDescription)")
                return 1
            }
        }
        if arguments.contains("--bench-visible") || arguments.contains("--bench-hidden") { out("git-poll-refreshes: \(appController.gitRefresh.refreshCount) · appActive \(NSApp.isActive) · keyWindow \(renderWindow.isKeyWindow) · visible \(renderWindow.isVisible)") }
        AppSnapshot.report(arguments, model: model)
        if arguments.contains("--tool-resources-details") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(model.toolResources.readout(model: model, now: Date())),
               let json = String(data: data, encoding: .utf8) {
                out("tool-resources: \(json)")
            }
        }
        model.stop()
        return connected || options.delay > 0 ? 0 : 3
    }

    private static func makeWindow(
        model: AppModel, prefs: ViewPreferences, presenter: EditorPresenter, optionPresenter: OptionPresenter, appController: AppController, options: Options
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: options.size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        if let dark = options.dark { window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua) }
        let root = SnapshotRoot(model: model, prefs: prefs, query: options.query, editor: presenter, options: optionPresenter)
            .modifier(AppBehaviorHost(controller: appController))
            .frame(width: options.size.width, height: options.size.height)
            .tint(Theme.accent)
            .environment(\.hoverEnabled, false)
            .environment(\.inlineSheets, true)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: options.size)
        window.contentView = host
        window.setContentSize(options.size)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        return window
    }

    private static func render(_ window: NSWindow, to url: URL) throws {
        guard let content = window.contentView else { throw SnapshotError("没有内容视图") }
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        // The frame view also draws the traffic lights; fall back to the content view.
        let view = content.superview ?? content
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw SnapshotError("无法创建位图")
        }
        view.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw SnapshotError("PNG 编码失败") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url)
    }

    private static func waitUntil(_ deadline: Date, _ condition: () -> Bool) async {
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    static func parse(_ args: [String]) throws -> Options {
        func value(_ flag: String) throws -> String? {
            guard let i = args.firstIndex(of: flag) else { return nil }
            guard i + 1 < args.count else { throw SnapshotError("\(flag) 缺少参数") }
            return args[i + 1]
        }
        func values(_ flag: String) -> [String] {
            args.indices.compactMap { i in args[i] == flag && i + 1 < args.count ? args[i + 1] : nil }
        }
        guard let path = try value("--snapshot") else { throw SnapshotError("用法：--snapshot <png路径>") }
        var o = Options(output: URL(fileURLWithPath: path))
        o.projectId = try value("--select-project")
        o.actionId = try value("--action")
        if let t = try value("--project-tab") { o.projectTab = ProjectInspectorTab(rawValue: t) }
        if let s = try value("--select") {
            let parts = s.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { throw SnapshotError("--select 需要 <projectId>/<serviceId>") }
            o.select = ServiceRef(parts[0], parts[1])
        }
        if let a = try value("--appearance") {
            switch a {
            case "dark": o.dark = true
            case "light": o.dark = false
            default: throw SnapshotError("--appearance 只能是 light 或 dark")
            }
        }
        if let s = try value("--size") {
            let parts = s.lowercased().split(separator: "x").compactMap { Double($0) }
            guard parts.count == 2, parts[0] >= 300, parts[1] >= 200 else { throw SnapshotError("--size 形如 1180x760") }
            o.size = NSSize(width: parts[0], height: parts[1])
        }
        for p in values("--perform") {
            let parts = p.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { throw SnapshotError("--perform 形如 stop:<projectId>[/<serviceId>]") }
            let action = ActionKind(raw: parts[0])
            guard action.isKnown else { throw SnapshotError("未知操作 \(parts[0])") }
            let target = parts[1].split(separator: "/", maxSplits: 1).map(String.init)
            o.perform.append(ActionRequest(
                projectId: target[0], serviceIds: target.count > 1 ? [target[1]] : nil, action: action))
        }
        if let d = try value("--delay") {
            guard let t = TimeInterval(d), t >= 0 else { throw SnapshotError("--delay 需要秒数") }
            o.delay = t
        }
        if let d = try value("--timeout") {
            guard let t = TimeInterval(d), t > 0 else { throw SnapshotError("--timeout 需要秒数") }
            o.timeout = t
        }
        if let q = try value("--query") { o.query = q }
        o.inspector = try InspectorSnapshot.parse(args)
        o.editor = try EditorSnapshot.parse(args)
        return o
    }

    private static func out(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    private static func err(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

struct SnapshotError: Error, CustomStringConvertible, LocalizedError {
    let description: String
    init(_ d: String) { description = d }
    var errorDescription: String? { description }
}

/// `RootView` with a fixed search text (the window's own `@State` cannot be set from outside).
private struct SnapshotRoot: View {
    let model: AppModel
    let prefs: ViewPreferences
    let query: String
    let editor: EditorPresenter
    let options: OptionPresenter

    var body: some View {
        RootView(model: model, prefs: prefs, initialQuery: query, editor: editor, options: options)
    }
}

/// Acceptance-only focus evidence. No timer and no repeated activation.
@MainActor private final class SnapshotBenchFocus {
    private weak var window: NSWindow?
    private let start = ProcessInfo.processInfo.systemUptime
    private var observers: [NSObjectProtocol] = []
    init(window: NSWindow) {
        self.window = window
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            observers.append(center.addObserver(forName: name, object: NSApp, queue: .main) { [weak self] note in
                let event = note.name.rawValue
                MainActor.assumeIsolated { self?.record(event) }
            })
        }
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                let event = note.name.rawValue
                MainActor.assumeIsolated { self?.record(event) }
            })
        }
        record("begin")
    }
    func record(_ event: String) {
        let elapsed = String(format: "%.3f", ProcessInfo.processInfo.systemUptime - start)
        let absolute = String(format: "%.3f", ProcessInfo.processInfo.systemUptime)
        let line = "bench-focus: +\(elapsed)s uptime=\(absolute) event=\(event) appActive=\(NSApp.isActive) keyWindow=\(window?.isKeyWindow == true) visible=\(window?.isVisible == true) occluded=\(window?.occlusionState.contains(.visible) != true) minimized=\(window?.isMiniaturized == true) onScreen=\(window.map { w in NSScreen.screens.contains { $0.visibleFrame.contains(w.frame) } } == true)\n"
        FileHandle.standardOutput.write(Data(line.utf8))
    }
    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }
}
