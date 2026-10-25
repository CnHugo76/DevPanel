import DevPanelKit
import SwiftUI

/// One service in the editor: name, ID, working directory, command (with argv and option
/// preview), advanced (env, stop wait), and the daemon's resolution line at the bottom.
struct ServiceEditorCard: View {
    @Bindable var editor: ProjectEditor
    @Bindable var state: EditorViewState
    let rowID: UUID
    let index: Int
    let count: Int
    var focus: FocusState<EditorField?>.Binding

    private static let circled = ["①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨", "⑩"]

    /// Binding by card ID (cards move and disappear; an index binding could go stale).
    private var service: Binding<ServiceDraft> {
        Binding(
            get: { editor.draft.services.first { $0.id == rowID } ?? ServiceDraft(serviceId: "", idAuto: false) },
            set: { new in
                if let i = editor.index(of: rowID) { editor.draft.services[i] = new }
            })
    }

    private var collapsed: Binding<Bool> {
        Binding(
            get: { state.collapsed.contains(rowID) },
            set: { if $0 { state.collapsed.insert(rowID) } else { state.collapsed.remove(rowID) } })
    }

    private var advancedOpen: Binding<Bool> {
        Binding(
            get: { state.advancedOpen.contains(rowID) },
            set: { if $0 { state.advancedOpen.insert(rowID) } else { state.advancedOpen.remove(rowID) } })
    }

    private var at: String { "services[\(index)]" }

    var body: some View {
        let s = service.wrappedValue
        VStack(alignment: .leading, spacing: 0) {
            header(s)
            if collapsed.wrappedValue {
                if hasProblems(s) {
                    HintLine(tone: .bad, text: "此服务有需要处理的问题，展开查看")
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    nameAndId(s)
                    cwdField(s)
                    commandField(s)
                    readiness
                    advanced(s)
                    resolutionLine
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .background(Theme.card2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
    }

    private var readiness: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("就绪条件").font(.system(size: 12, weight: .semibold))
            Picker("类型", selection: service.readyKind) {
                Text("未配置").tag("none")
                Text("日志包含").tag("log")
                Text("端口监听").tag("port")
            }
            if service.wrappedValue.readyKind == "log" {
                Text("任一文字命中即就绪（每行一项，最多 5 项）").font(.caption).foregroundStyle(Theme.text3)
                TextEditor(text: service.readyContainsText).font(.system(size: 12, design: .monospaced)).frame(height: 64)
            } else if service.wrappedValue.readyKind == "port" {
                TextField("端口：留空表示任意，支持 ${port}", text: service.readyPortText)
            }
            if service.wrappedValue.readyKind != "none" {
                HStack {
                    Text("等待上限（秒）").font(.system(size: 12)).foregroundStyle(Theme.text2)
                    TextField("默认 120", text: service.readyTimeoutText).frame(width: 100)
                    Spacer(minLength: 0)
                }
                FieldHints(local: nil, issues: editor.validation?.issues(row: rowID, field: "ready") ?? [])
                ForEach(editor.localErrors.keys.filter { $0.hasPrefix(at + ".ready") }.sorted(), id: \.self) { key in
                    HintLine(tone: .bad, text: editor.localErrors[key] ?? "")
                }
            }
        }
    }

    // MARK: Header

    private func header(_ s: ServiceDraft) -> some View {
        let view = editor.serviceView(s)
        let blocked = editor.deleteBlockedReason(s)
        return HStack(spacing: 8) {
            Button {
                collapsed.wrappedValue.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: collapsed.wrappedValue ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.text3)
                        .frame(width: 10)
                    Text("\(index < Self.circled.count ? Self.circled[index] : "\(index + 1).") \(s.name.isEmpty ? "未命名服务" : s.name)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel("服务 \(index + 1)：\(s.name.isEmpty ? "未命名服务" : s.name)")
            .accessibilityValue(collapsed.wrappedValue ? "已折叠" : "已展开")
            Text("id: \(s.serviceId.isEmpty ? "—" : s.serviceId)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.text3)
                .lineLimit(1)
            if let view, view.state.blocksRemoval {
                Text(view.state == .unknown ? "状态未知" : "运行中 · 不能删除")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.amber)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Theme.amberSoft, in: Capsule())
                    .help(blocked ?? "")
            } else if s.origId == nil, editor.mode != .create {
                Text("新服务")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.accent2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Theme.accentSoft, in: Capsule())
            }
            Spacer(minLength: 4)
            CardIconButton(systemImage: "arrow.up", label: "上移", help: "上移（更早启动）", enabled: index > 0) {
                editor.moveService(rowID, by: -1)
            }
            CardIconButton(systemImage: "arrow.down", label: "下移", help: "下移（更晚启动）", enabled: index < count - 1) {
                editor.moveService(rowID, by: 1)
            }
            CardIconButton(
                systemImage: "xmark", label: "删除服务", help: blocked ?? "删除服务", enabled: blocked == nil
            ) {
                editor.removeService(rowID)
                editor.fieldDidBlur()
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
    }

    private func hasProblems(_ s: ServiceDraft) -> Bool {
        if editor.localErrors.keys.contains(where: { $0.hasPrefix(at + ".") }) { return true }
        if case .invalid = s.command { return true }
        guard let v = editor.validation else { return false }
        if let p = v.prefix(for: rowID), v.issues(under: p).contains(where: { $0.severity == .error }) { return true }
        if let r = v.resolution(for: rowID), ResolutionLine(r).isProblem { return true }
        return false
    }

    // MARK: Fields

    private func nameAndId(_ s: ServiceDraft) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                FieldTitle(text: "名称", required: true) { focus.wrappedValue = .serviceName(rowID) }
                EditorTextField(
                    label: "服务名称",
                    text: Binding(
                        get: { service.wrappedValue.name },
                        set: { service.wrappedValue.rename($0, taken: editor.draft.takenIds(except: rowID)) }),
                    prompt: "例如 后端",
                    invalid: editor.localError("\(at).name") != nil, field: .serviceName(rowID), focus: focus)
                FieldHints(local: editor.localError("\(at).name"), issues: editor.validation?.issues(row: rowID, field: "name") ?? [])
            }
            VStack(alignment: .leading, spacing: 4) {
                FieldTitle(text: s.idAuto ? "ID（随名称生成）" : "ID", required: true) { focus.wrappedValue = .serviceId(rowID) }
                let formatBad = !s.serviceId.isEmpty && !Slug.isValidServiceID(s.serviceId)
                EditorTextField(
                    label: "服务 ID",
                    text: Binding(get: { service.wrappedValue.serviceId }, set: { service.wrappedValue.setServiceId($0) }),
                    prompt: "backend", monospaced: true,
                    invalid: editor.localError("\(at).id") != nil || formatBad, field: .serviceId(rowID), focus: focus)
                FieldHints(local: editor.localError("\(at).id"), issues: editor.validation?.issues(row: rowID, field: "id") ?? [])
                if formatBad, editor.localError("\(at).id") == nil {
                    HintLine(tone: .bad, text: "小写字母开头，只含小写字母、数字和连字符，最长 32 位")
                } else if let orig = s.origId, orig != s.serviceId, editor.idChangeNeedsConfirm(s) {
                    HintLine(tone: .warn, text: "原 ID \(orig) 的运行记录与日志不会跟随新 ID")
                }
            }
            .frame(width: 220)
        }
    }

    private func cwdField(_ s: ServiceDraft) -> some View {
        let resolution = editor.validation?.resolution(for: rowID)
        let issues = (editor.validation?.issues(row: rowID, field: "cwd") ?? [])
            .filter { !(resolution != nil && $0.code == .error(.cwdUnavailable)) }
        return VStack(alignment: .leading, spacing: 4) {
            FieldTitle(text: "工作目录（相对根目录，或绝对路径）") { focus.wrappedValue = .cwd(rowID) }
            EditorTextField(
                label: "工作目录", text: service.cwd, prompt: ".", monospaced: true,
                field: .cwd(rowID), focus: focus)
            FieldHints(issues: issues)
        }
    }

    private func commandField(_ s: ServiceDraft) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldTitle(text: s.viaShell ? "Shell 脚本" : "启动命令", required: true) { focus.wrappedValue = .command(rowID) }
            EditorTextField(
                label: s.viaShell ? "Shell 脚本" : "启动命令", text: service.commandText,
                prompt: s.viaShell ? "例如 pnpm install && pnpm dev" : "例如 ./mvnw spring-boot:run",
                monospaced: true, invalid: editor.localError("\(at).command") != nil,
                field: .command(rowID), focus: focus)
            // Directly under the input, so it never moves when the preview below changes height.
            EditorCheckbox(
                title: "通过 Shell 运行（\(s.shell) \(s.shellFlag)）",
                isOn: Binding(
                    get: { service.wrappedValue.viaShell },
                    set: {
                        service.wrappedValue.viaShell = $0
                        editor.fieldDidBlur()
                    }),
                help: "保存为 [\"\(s.shell)\", \"\(s.shellFlag)\", 原文]，可使用 &&、管道等 Shell 语法")
            CommandPreviewBox(
                service: s, params: editor.params, local: editor.localError("\(at).command"),
                issues: editor.validation?.issues(row: rowID, field: "command") ?? [],
                hasResolution: editor.validation?.resolution(for: rowID) != nil)
        }
    }

    private func advanced(_ s: ServiceDraft) -> some View {
        let envCount = s.env.filter { !$0.name.isEmpty }.count
        let stop = s.stopTimeoutText.isEmpty ? "\(ServiceDraft.defaultStopTimeout)" : s.stopTimeoutText
        let advancedErrors = editor.localErrors.keys.contains { $0.hasPrefix("\(at).env") || $0 == "\(at).stopTimeoutSec" }
        return VStack(alignment: .leading, spacing: 10) {
            DisclosureHeader(
                title: "高级",
                subtitle: (envCount > 0 ? "环境变量 \(envCount) 个 · " : "") + "停止等待 \(stop) 秒",
                isOpen: advancedOpen)
            if advancedOpen.wrappedValue {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        FieldTitle(text: "环境变量（覆盖项目级同名变量）")
                        EnvTable(
                            editor: editor, rows: service.env, service: s, pathPrefix: "\(at).env",
                            issues: editor.validation?.issues(row: rowID, field: "env") ?? [], focus: focus,
                            onCommit: { editor.fieldDidBlur() })
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        FieldTitle(text: "停止等待（秒）") { focus.wrappedValue = .stopTimeout(rowID) }
                        HStack(spacing: 8) {
                            EditorTextField(
                                label: "停止等待秒数", text: service.stopTimeoutText,
                                prompt: "\(ServiceDraft.defaultStopTimeout)", monospaced: true,
                                invalid: editor.localError("\(at).stopTimeoutSec") != nil,
                                field: .stopTimeout(rowID), focus: focus)
                                .frame(width: 80)
                            Text("发送 SIGTERM 后等待退出的时间，1–300，默认 10")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.text3)
                        }
                        FieldHints(
                            local: editor.localError("\(at).stopTimeoutSec"),
                            issues: editor.validation?.issues(row: rowID, field: "stopTimeoutSec") ?? [])
                    }
                }
                .padding(.leading, 16)
            } else if advancedErrors {
                HintLine(tone: .bad, text: "高级设置中有需要处理的问题，展开查看")
                    .padding(.leading, 16)
            }
        }
    }

    @ViewBuilder private var resolutionLine: some View {
        if let r = editor.validation?.resolution(for: rowID) {
            let line = ResolutionLine(r)
            Rectangle().fill(Theme.line).frame(height: 1)
            HintLine(
                tone: line.isProblem ? .bad : (line == .unresolved(program: r.program) ? .info : .ok),
                text: line.text, monospaced: true)
        }
    }
}

/// argv, the option substitution preview and the command warnings, under the command field.
struct CommandPreviewBox: View {
    let service: ServiceDraft
    let params: [ParamConfig]
    let local: String?
    let issues: [ValidationIssue]
    let hasResolution: Bool

    var body: some View {
        let parse = service.command
        let background = service.backgroundHint
        VStack(alignment: .leading, spacing: 4) {
            switch parse {
            case .invalid(let why):
                HintLine(tone: .bad, text: why)
            case .empty:
                Text(local == nil ? "argv: []" : "")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.text3)
                if let local { HintLine(tone: .bad, text: local) }
            case .argv(let argv):
                let preview = CommandPreview.make(argv, params: params)
                Text(argvText(argv) + (service.viaShell ? "（通过 \(service.shell) \(service.shellFlag) 运行）" : ""))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.text2)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(argvText(argv))
                    .accessibilityLabel("argv 预览")
                    .accessibilityValue(argvText(argv))
                if preview.changesAnything {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("下次启动").foregroundStyle(Theme.text3)
                        Text(substituted(preview))
                            .lineLimit(3)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    .font(.system(size: 11.5, design: .monospaced))
                    .accessibilityElement(children: .combine)
                }
                let unknown = preview.unknownKeys
                if !unknown.isEmpty {
                    HintLine(
                        tone: .bad,
                        text: "引用了不存在的选项：" + unknown.map { "${\($0)}" }.joined(separator: "、")
                            + "。请先在选项面板中添加；字面量请写成 $${…}")
                }
            }
            if let background {
                HintLine(tone: .warn, text: "检测到 \(background)：请使用前台运行方式，后台化的进程无法被管理")
            }
            ForEach(Array(shownIssues(background: background).enumerated()), id: \.offset) { _, issue in
                HintLine(tone: issue.severity == .error ? .bad : .warn, text: issue.message)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.window, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    /// Daemon issues not already said by the local preview / the resolution line.
    private func shownIssues(background: String?) -> [ValidationIssue] {
        issues.filter { i in
            if background != nil, i.code == .warning(.backgroundCommand) { return false }
            if hasResolution, i.code == .error(.commandNotFound) { return false }
            if i.code == .error(.paramUnknown) { return false }
            if local != nil, i.message == local { return false }
            return true
        }
    }

    private func argvText(_ argv: [String]) -> String {
        "argv: [" + argv.map(Self.jsonString).joined(separator: ", ") + "]"
    }

    static func jsonString(_ s: String) -> String {
        let data = (try? JSONEncoder().encode(s)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
    }

    private func substituted(_ p: CommandPreview) -> AttributedString {
        var out = AttributedString()
        for (i, arg) in p.args.enumerated() {
            if i > 0 { out += AttributedString(" ") }
            let needsQuotes = arg.text.isEmpty || arg.text.contains(where: { $0 == " " || $0 == "\t" })
            if needsQuotes { out += styled("\"", Theme.text2) }
            for seg in arg.segments {
                switch seg.kind {
                case .text: out += styled(seg.text, Theme.text)
                case .value: out += styled(seg.text, Theme.accent2, bold: true)
                case .secret: out += styled(seg.text, Theme.purple)
                case .unknown: out += styled(seg.text, Theme.red, bold: true)
                case .escaped: out += styled(seg.text, Theme.text2)
                }
            }
            if needsQuotes { out += styled("\"", Theme.text2) }
        }
        return out
    }

    private func styled(_ s: String, _ color: Color, bold: Bool = false) -> AttributedString {
        var a = AttributedString(s)
        a.foregroundColor = color
        if bold { a.font = .system(size: 11.5, weight: .semibold, design: .monospaced) }
        return a
    }
}
