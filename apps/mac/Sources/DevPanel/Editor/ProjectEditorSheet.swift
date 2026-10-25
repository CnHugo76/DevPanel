import AppKit
import DevPanelKit
import SwiftUI

/// "添加项目" / "编辑项目" (ui-design v2 §6): a sheet inside the window. Fields map one to one
/// onto `ProjectConfig`; options are listed read-only (edited in the options panel, F4).
/// Saving never starts anything (there is no "保存并启动").
struct ProjectEditorSheet: View {
    let presenter: EditorPresenter
    @Bindable var editor: ProjectEditor
    @Bindable var state: EditorViewState

    @FocusState private var focus: EditorField?
    @State private var confirm: Confirm?

    enum Confirm: Identifiable, Equatable {
        case discard
        case reload
        case idChange(row: UUID, from: String, to: String, name: String)

        var id: String {
            switch self {
            case .discard: "discard"
            case .reload: "reload"
            case .idChange(let row, _, let to, _): "id-\(row)-\(to)"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.line).frame(height: 1)
            if let notice = editor.notice {
                NoticeBanner(notice: notice, onReload: { confirm = .reload }, onOpenExisting: openExisting) {
                    editor.notice = nil
                }
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle().fill(Theme.line).frame(height: 1)
            footer
        }
        .background(Theme.card)
        .foregroundStyle(Theme.text)
        .interactiveDismissDisabled()
        .onChange(of: focus) { old, _ in
            if let old { didBlur(old) }
        }
        .alert(
            confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { cancelConfirm() } }),
            presenting: confirm
        ) { c in
            switch c {
            case .discard:
                Button("放弃修改", role: .destructive) { presenter.close() }
                Button("继续编辑", role: .cancel) {}
            case .reload:
                Button("丢弃并载入", role: .destructive) { Task { await editor.reloadLatest() } }
                Button("取消", role: .cancel) {}
            case .idChange(let row, _, let to, _):
                Button("仍要修改", role: .destructive) { state.confirmedIdChanges[row] = to }
                Button("恢复原 ID", role: .cancel) { editor.revertServiceId(row) }
            }
        } message: { c in
            Text(confirmMessage(c))
        }
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(editor.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(editor.mode == .create
                     ? "注册后不会启动任何服务。也可以让编程 Agent 运行 devpanel project register。"
                     : "只修改配置，不会启动或重启服务。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if editor.isRunning {
                HStack(spacing: 6) {
                    Circle().fill(Theme.amber).frame(width: 6, height: 6)
                    Text("项目运行中：保存后在下次启动时生效，不会自动重启")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text2)
                        .lineLimit(2)
                }
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 8)
            SheetButton(title: "取消", action: cancel)
                .keyboardShortcut(.cancelAction)
                .help("取消（Esc）")
            SheetButton(
                title: editor.isSaving ? "保存中…" : "保存", kind: .primary,
                enabled: editor.loadState == .loaded && !editor.isSaving, action: save
            )
            .keyboardShortcut(.return, modifiers: .command)
            .help("保存（⌘↩）")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Theme.card2)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch editor.loadState {
        case .loading:
            ProgressView("正在读取配置…").controlSize(.small)
        case .failed(let message):
            VStack(spacing: 10) {
                Text("读取配置失败").font(.system(size: 14, weight: .semibold))
                Text(message).font(.system(size: 12)).foregroundStyle(Theme.text2)
                SheetButton(title: "重试") { Task { await editor.load() } }
            }
        case .loaded:
            ScrollViewReader { proxy in
                ScrollView {
                    form
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                }
                .onChange(of: state.scrollTarget, initial: true) { _, target in
                    guard let target else { return }
                    proxy.scrollTo(target, anchor: target == "bottom" ? .bottom : .top)
                }
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            projectFields
                .id("top")
            projectEnv
            servicesSection
            ActionEditorSection(editor: editor)
            TargetEditorSection(editor: editor)
            VStack(alignment: .leading, spacing: 6) {
                FieldTitle(text: "Maven 可执行文件")
                Picker("Maven 可执行文件", selection: Binding(get: { editor.draft.maven?.executable ?? "auto" }, set: { editor.draft.maven = MavenConfig(executable: $0); editor.fieldDidBlur() })) {
                    Text("自动（优先项目 mvnw）").tag("auto")
                    Text("项目 mvnw").tag("wrapper")
                    Text("PATH 中的 mvn").tag("mvn")
                }.labelsHidden().frame(maxWidth: 300)
            }
            ParamsReadOnlyList(params: editor.params, creating: editor.mode == .create)
            if let other = editor.validation?.otherIssues, !other.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    FieldTitle(text: "其他校验结果")
                    ForEach(Array(other.enumerated()), id: \.offset) { _, issue in
                        HintLine(
                            tone: issue.severity == .error ? .bad : .warn,
                            text: (issue.path.isEmpty ? "" : issue.path + "：") + issue.message)
                    }
                }
            }
            Color.clear.frame(height: 1).id("bottom")
        }
    }

    private var projectFields: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                FieldTitle(text: "项目名称", required: true) { focus = .projectName }
                EditorTextField(
                    label: "项目名称", text: $editor.draft.name, prompt: "例如 order-service",
                    invalid: editor.localError("name") != nil, field: .projectName, focus: $focus)
                FieldHints(local: editor.localError("name"), issues: editor.validation?.issues(under: "name") ?? [])
            }
            .frame(width: 200)
            VStack(alignment: .leading, spacing: 4) {
                FieldTitle(text: "根目录（绝对路径）", required: true) { focus = .root }
                HStack(spacing: 6) {
                    EditorTextField(
                        label: "根目录", text: $editor.draft.root, prompt: "/Users/you/Project/foo", monospaced: true,
                        invalid: editor.localError("root") != nil, field: .root, focus: $focus)
                    SheetButton(title: "选择…", action: chooseRoot)
                        .help("在访达中选择项目根目录")
                        .accessibilityLabel("选择根目录")
                }
                let rootIssues = editor.validation?.issues(under: "root") ?? []
                FieldHints(local: editor.localError("root"), issues: rootIssues)
                if editor.validation != nil, rootIssues.isEmpty, editor.localError("root") == nil,
                   !editor.draft.root.isEmpty {
                    HintLine(tone: .ok, text: "目录存在")
                }
            }
        }
    }

    private var projectEnv: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureHeader(
                title: "项目级环境变量",
                subtitle: editor.draft.env.isEmpty ? "所有服务共享；服务内同名变量优先" : "\(editor.draft.env.count) 个 · 所有服务共享",
                isOpen: $state.projectEnvOpen)
            if state.projectEnvOpen {
                EnvTable(
                    editor: editor, rows: $editor.draft.env, service: nil, pathPrefix: "env",
                    issues: editor.validation?.issues(under: "env") ?? [], focus: $focus,
                    onCommit: { editor.fieldDidBlur() })
                    .padding(.leading, 16)
            }
        }
    }

    private var servicesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("服务").font(.system(size: 13, weight: .semibold))
                Text("顺序即项目的启动顺序").font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                Spacer(minLength: 0)
            }
            ForEach(Array(editor.draft.services.enumerated()), id: \.element.id) { index, service in
                ServiceEditorCard(
                    editor: editor, state: state, rowID: service.id, index: index,
                    count: editor.draft.services.count, focus: $focus)
                    .id(service.id.uuidString)
            }
            HStack(spacing: 8) {
                SheetButton(title: "＋ 添加服务") {
                    editor.addService()
                    if let last = editor.draft.services.last { focus = .serviceName(last.id) }
                }
                if let e = editor.localError("services") { HintLine(tone: .bad, text: e) }
            }
        }
    }

    // MARK: Actions

    private func didBlur(_ field: EditorField) {
        if case .serviceId(let row) = field, let s = editor.draft.services.first(where: { $0.id == row }),
           editor.idChangeNeedsConfirm(s), state.confirmedIdChanges[row] != s.serviceId, confirm == nil {
            confirm = .idChange(
                row: row, from: s.origId ?? "", to: s.serviceId,
                name: editor.serviceView(s)?.name ?? s.name)
        }
        editor.fieldDidBlur()
    }

    private func cancelConfirm() {
        if case .idChange(let row, _, let to, _) = confirm, state.confirmedIdChanges[row] != to {
            editor.revertServiceId(row)
        }
        confirm = nil
    }

    private func cancel() {
        if editor.isDirty {
            confirm = .discard
        } else {
            presenter.close()
        }
    }

    private func save() {
        // An ID change of a service with runs must be confirmed first.
        if let s = editor.draft.services.first(where: {
            editor.idChangeNeedsConfirm($0) && state.confirmedIdChanges[$0.id] != $0.serviceId
        }) {
            confirm = .idChange(row: s.id, from: s.origId ?? "", to: s.serviceId, name: editor.serviceView(s)?.name ?? s.name)
            return
        }
        focus = nil
        Task {
            if let outcome = await editor.save() {
                presenter.finish(outcome, editor: editor)
            } else if editor.notice == .fixFields {
                // Open cards with local errors so the marks are visible.
                for (i, s) in editor.draft.services.enumerated()
                where editor.localErrors.keys.contains(where: { $0.hasPrefix("services[\(i)]") }) {
                    state.collapsed.remove(s.id)
                }
            }
        }
    }

    private func openExisting() {
        guard case .conflict(let id?, _, _) = editor.notice else { return }
        presenter.close()
        presenter.locate(id)
    }

    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "选择"
        panel.message = "选择项目根目录"
        let current = editor.draft.root.trimmingCharacters(in: .whitespaces)
        if !current.isEmpty { panel.directoryURL = URL(fileURLWithPath: current, isDirectory: true) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        editor.draft.root = url.path
        if editor.draft.name.trimmingCharacters(in: .whitespaces).isEmpty {
            editor.draft.name = url.lastPathComponent
        }
        editor.fieldDidBlur()
    }

    // MARK: Confirm texts

    private var confirmTitle: String {
        switch confirm {
        case .discard: "放弃未保存的修改？"
        case .reload: "载入最新配置？"
        case .idChange: "修改服务 ID？"
        case nil: ""
        }
    }

    private func confirmMessage(_ c: Confirm) -> String {
        switch c {
        case .discard: "关闭后，本次在表单中的修改不会保存。"
        case .reload: "将丢弃你尚未保存的修改，改为显示管理服务中的最新配置。"
        case .idChange(_, let from, let to, let name):
            "「\(name)」已有运行记录。修改 ID 等同于删除原服务 \(from) 并新建服务 \(to)：保存后，原服务的运行记录与日志不再属于这个服务。"
        }
    }
}

// MARK: - Banner

struct NoticeBanner: View {
    let notice: EditorNotice
    let onReload: () -> Void
    let onOpenExisting: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        let c = Theme.colors(notice.isWarning ? .amber : .red)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(notice.isWarning ? "⚠" : "✕").foregroundStyle(c.fg)
                Text(notice.title).fontWeight(.semibold).foregroundStyle(c.fg)
                Spacer(minLength: 4)
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.text3)
                        .frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("关闭提示")
                .accessibilityLabel("关闭提示")
            }
            if !notice.detail.isEmpty {
                Text(notice.detail)
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if case .conflict(let projectId, let diff, _) = notice {
                if !diff.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(diff.prefix(6).enumerated()), id: \.offset) { _, d in
                            Text(d.summary)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(Theme.text2)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if diff.count > 6 {
                            Text("… 共 \(diff.count) 处不同").font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                        }
                    }
                    .textSelection(.enabled)
                }
                if projectId != nil {
                    SheetButton(title: "打开已有项目", action: onOpenExisting)
                }
            }
            if case .revisionMismatch = notice {
                SheetButton(title: "载入最新配置", action: onReload)
            }
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(c.bg)
        .overlay(alignment: .bottom) { Rectangle().fill(c.border).frame(height: 1) }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Options (read-only)

struct ParamsReadOnlyList: View {
    let params: [ParamConfig]
    let creating: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("选项").font(.system(size: 13, weight: .semibold))
                Text(creating ? "添加项目后可在选项面板中添加选项" : "只读 · 在选项面板中编辑")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text3)
                Spacer(minLength: 0)
            }
            if params.isEmpty {
                if !creating {
                    Text("这个项目还没有选项。命令中可用 ${key} 引用选项。")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text3)
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(params.enumerated()), id: \.element.key) { i, p in
                        HStack(spacing: 10) {
                            Text(p.label.isEmpty ? p.key : p.label)
                                .font(.system(size: 12.5))
                                .lineLimit(1)
                                .frame(width: 140, alignment: .leading)
                            Text("${\(p.key)}")
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(Theme.text3)
                                .lineLimit(1)
                                .frame(width: 150, alignment: .leading)
                            Text(valueText(p))
                                .font(.system(size: 12.5, design: p.isSecret ? .default : .monospaced))
                                .foregroundStyle(p.isSecret ? Theme.text3 : Theme.text)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(i.isMultiple(of: 2) ? Color.clear : Theme.graySoft)
                        .accessibilityElement(children: .combine)
                    }
                }
                .background(Theme.window, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.line))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private func valueText(_ p: ParamConfig) -> String {
        if p.isSecret { return "••••（敏感）" }
        let shown = p.displayValue
        if case .string(let raw) = p.value, p.type == .enum, shown != raw { return "\(raw)（\(shown)）" }
        return shown
    }
}
