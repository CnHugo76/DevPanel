import DevPanelKit
import Foundation

/// `--snapshot` options for the project editor (F5). Sheets render inline in snapshots.
///
///   --open-editor new|<projectId>     open the add / edit sheet (waits for the config)
///   --editor-set <field>=<value>      fill a field, repeatable, applied in order:
///                                     name, root, instance.group, instance.name, env.<NAME>, s<N>.name, s<N>.id, s<N>.cwd,
///                                     s<N>.command, s<N>.shell (on|off), s<N>.stop,
///                                     s<N>.env.<NAME>, s<N>.secret.<NAME>  (N from 0; a new N adds a service)
///   --editor-expand <what>            open a section: env, s<N> (card), s<N>.advanced; repeatable
///   --editor-collapse s<N>            collapse a card; repeatable
///   --editor-scroll top|bottom|s<N>   scroll the sheet
///   --editor-bump                     before saving, change the project from another request
///                                     (stop wait of its first service +1) to provoke REVISION_MISMATCH
///   --editor-save                     press 保存 (the result banner / toast is captured)
///   --remove-project <projectId>      open the remove confirmation
///   --toast <text>                    show a result toast (sticky)
///
/// After filling, the form is validated (`/config/validate`) like on blur.
@MainActor
enum EditorSnapshot {
    enum Open: Equatable {
        case new
        case edit(ProjectID)
    }

    struct Options {
        var open: Open?
        var sets: [(String, String)] = []
        var expand: [String] = []
        var collapse: [String] = []
        var scroll: String?
        var bump = false
        var save = false
        var removeProject: ProjectID?
        var toast: String?

        var isEmpty: Bool { open == nil && removeProject == nil }
    }

    static func parse(_ args: [String]) throws -> Options {
        func values(_ flag: String) throws -> [String] {
            try args.indices.compactMap { i in
                guard args[i] == flag else { return nil }
                guard i + 1 < args.count else { throw SnapshotError("\(flag) 缺少参数") }
                return args[i + 1]
            }
        }
        var o = Options()
        if let v = try values("--open-editor").last {
            o.open = v == "new" ? .new : .edit(v)
        }
        for s in try values("--editor-set") {
            guard let eq = s.firstIndex(of: "=") else { throw SnapshotError("--editor-set 形如 s0.command=pnpm dev") }
            o.sets.append((String(s[..<eq]), String(s[s.index(after: eq)...])))
        }
        o.expand = try values("--editor-expand")
        o.collapse = try values("--editor-collapse")
        o.scroll = try values("--editor-scroll").last
        o.bump = args.contains("--editor-bump")
        o.save = args.contains("--editor-save")
        o.removeProject = try values("--remove-project").last
        o.toast = try values("--toast").last
        if (o.bump || o.save || !o.sets.isEmpty) && o.open == nil {
            throw SnapshotError("--editor-* 需要和 --open-editor 一起使用")
        }
        return o
    }

    /// Opens and fills the sheet; returns log lines.
    static func apply(_ o: Options, model: AppModel, presenter: EditorPresenter, timeout: TimeInterval) async -> [String] {
        var log: [String] = []
        if let t = o.toast { presenter.show(.init(tone: .warn, text: t, sticky: true)) }
        if let id = o.removeProject {
            presenter.remove(id)
            let check = model.project(id).map(RemovalCheck.init)
            log.append("remove:  \(id) · \(check.map { $0.allowed ? "可以移除" : "已禁用（\($0.blocking.map(\.id).joined(separator: ","))）" } ?? "找不到项目")")
        }
        guard let open = o.open else { return log }
        switch open {
        case .new: presenter.openNew()
        case .edit(let id): presenter.edit(id)
        }
        guard case .editor(let editor, let state) = presenter.sheet else { return log + ["editor:  未打开"] }
        let deadline = Date().addingTimeInterval(timeout)
        while editor.loadState == .loading, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        // Let `edit()` apply its post-load view state before we change it.
        try? await Task.sleep(for: .milliseconds(100))
        log.append("editor:  \(editor.title) · \(editor.loadState)")

        for (key, value) in o.sets {
            if let error = set(key, value, editor: editor) { log.append("editor-set: \(key) → \(error)") }
        }
        for e in o.expand {
            if e == "env" {
                state.projectEnvOpen = true
            } else if let (i, rest) = serviceIndex(e), editor.draft.services.indices.contains(i) {
                let id = editor.draft.services[i].id
                state.collapsed.remove(id)
                if rest == "advanced" { state.advancedOpen.insert(id) }
            }
        }
        for c in o.collapse {
            if let (i, _) = serviceIndex(c), editor.draft.services.indices.contains(i) {
                state.collapsed.insert(editor.draft.services[i].id)
            }
        }
        await editor.validate()
        log.append("validate: \(editor.validation.map { "\($0.issues.count) 个问题" } ?? "未校验")")

        if o.bump, let id = editor.mode.projectId {
            do {
                var p = try await model.fetchProject(id)
                if !p.config.services.isEmpty {
                    p.config.services[0].stopTimeoutSec = (p.config.services[0].stopTimeoutSec ?? 10) + 1
                }
                p.config.params = p.config.params?.map(\.forRequest)
                let r = try await model.updateProject(id, ifRevision: p.revision, config: p.config)
                log.append("bump:    \(id) → r\(r.project.revision)")
            } catch {
                log.append("bump:    失败 \(error)")
            }
        }
        if o.save {
            if let outcome = await editor.save() {
                presenter.finish(outcome, editor: editor)
                log.append("save:    \(outcome.project.id) r\(outcome.project.revision)")
            } else {
                log.append("save:    \(editor.notice.map { "\($0.title)" } ?? "未保存")")
            }
        }
        if let s = o.scroll {
            if s == "top" || s == "bottom" {
                state.scrollTarget = s
            } else if let (i, _) = serviceIndex(s), editor.draft.services.indices.contains(i) {
                state.scrollTarget = editor.draft.services[i].id.uuidString
            }
        }
        return log
    }

    private static func serviceIndex(_ s: String) -> (Int, String)? {
        guard s.hasPrefix("s") else { return nil }
        let body = s.dropFirst()
        let parts = body.split(separator: ".", maxSplits: 1).map(String.init)
        guard let first = parts.first, let i = Int(first) else { return nil }
        return (i, parts.count > 1 ? parts[1] : "")
    }

    private static func set(_ key: String, _ value: String, editor: ProjectEditor) -> String? {
        switch key {
        case "name": editor.draft.name = value
        case "root": editor.draft.root = value
        case "instance.group": editor.draft.instanceGroup = value
        case "instance.name": editor.draft.instanceName = value
        default:
            if key.hasPrefix("env.") {
                var row = EnvRow()
                row.rename(String(key.dropFirst(4)))
                row.value = value
                editor.draft.env.append(row)
                return nil
            }
            guard let (i, field) = serviceIndex(key) else { return "未知字段" }
            while editor.draft.services.count <= i { editor.addService() }
            let taken = editor.draft.takenIds(except: editor.draft.services[i].id)
            if field.hasPrefix("env.") || field.hasPrefix("secret.") {
                let secret = field.hasPrefix("secret.")
                let name = String(field.split(separator: ".", maxSplits: 1)[1])
                if let j = editor.draft.services[i].env.firstIndex(where: { $0.name == name }) {
                    editor.draft.services[i].env[j].value = value
                    if secret { editor.draft.services[i].env[j].setSecret(true) }
                } else {
                    var row = EnvRow()
                    row.rename(name)
                    if secret { row.setSecret(true) }
                    row.value = value
                    editor.draft.services[i].env.append(row)
                }
                return nil
            }
            switch field {
            case "name": editor.draft.services[i].rename(value, taken: taken)
            case "id": editor.draft.services[i].setServiceId(value)
            case "cwd": editor.draft.services[i].cwd = value
            case "command": editor.draft.services[i].commandText = value
            case "shell": editor.draft.services[i].viaShell = value == "on" || value == "true"
            case "stop": editor.draft.services[i].stopTimeoutText = value
            default: return "未知字段"
            }
        }
        return nil
    }
}
