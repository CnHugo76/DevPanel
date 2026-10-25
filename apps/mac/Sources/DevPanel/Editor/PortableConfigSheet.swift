import AppKit
import DevPanelKit
import SwiftUI
import UniformTypeIdentifiers

struct PortableConfigSheet: View {
    let session: PortableConfigSession
    let presenter: EditorPresenter
    @State private var fileNotice: String?
    @State private var inputsExpanded = true
    private var exporting: Bool { if case .export = session.mode { true } else { false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(exporting ? "导出共享配置" : "导入共享配置").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("关闭") { session.cancel(); presenter.close() }.keyboardShortcut(.cancelAction).disabled(session.busy)
            }.padding(18)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("仓库文件与面板配置通过显式导入、导出同步；不会后台同步或执行项目命令。")
                        .font(.system(size: 12)).foregroundStyle(Theme.text3)
                    if exporting { exportContent } else { importContent }
                    if let notice = session.notice ?? fileNotice {
                        Label(notice, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12)).foregroundStyle(Theme.amber).textSelection(.enabled)
                    }
                }.padding(18)
            }
            Divider()
            HStack {
                if session.busy { ProgressView().controlSize(.small) }
                Text(exporting ? "建议文件名 devpanel.json" : "本机输入仅用于当前预览，不回显、不写入共享文件。")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                Spacer()
                if exporting {
                    Button("另存为…", action: saveExport).disabled(session.document == nil || session.busy)
                } else {
                    Button("预览导入") { Task { await session.prepare() } }
                        .disabled(session.document == nil || session.root == nil || session.busy)
                    Button("保存导入") {
                        Task {
                            if let project = await session.save() {
                                presenter.show(.init(tone: .ok, text: session.savedMessage ?? "已导入 · 未启动", sticky: true))
                                presenter.close()
                                presenter.locate(project.id)
                            }
                        }
                    }.disabled(!session.canSave)
                }
            }.padding(16)
        }
        .background(Theme.card)
        .interactiveDismissDisabled(session.busy)
        .task { if exporting { await session.loadExport() } }
        .onChange(of: session.preview != nil) { _, ready in if ready { inputsExpanded = false } }
        .onDisappear { session.cancel() }
    }

    @ViewBuilder private var exportContent: some View {
        Text("已标记的敏感值与本机绝对路径会移到待填写输入；请在分享前审阅未标记的普通文本。")
            .font(.system(size: 12.5)).foregroundStyle(Theme.text2)
        if let document = session.document {
            Text("\(document.project["name"]?.stringValue ?? "项目") · \(document.inputs.count) 项本机输入")
                .font(.system(size: 13, weight: .medium))
            CodeBlock(text: session.exportText)
            Text("只写入所选新文件，不覆盖已有文件。输入文件应单独保存，并加入仓库忽略规则。")
                .font(.system(size: 11.5)).foregroundStyle(Theme.text3)
        } else if session.busy {
            ProgressView("读取项目并生成共享配置…").controlSize(.small)
        }
    }

    private var importContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            fileRow("共享配置", path: session.documentURL?.path, button: "选择 JSON…", action: chooseDocument)
            fileRow("本机根目录", path: session.root, button: "选择目录…", action: chooseRoot)
            fileRow("本机输入", path: session.inputsURL?.lastPathComponent, button: "选择输入文件…", action: chooseInputs)
            if let document = session.document {
                DisclosureGroup("本机输入 · \(document.inputs.count) 项，\(session.missing.count) 项待提供", isExpanded: $inputsExpanded) {
                    if document.inputs.isEmpty {
                        Text("此配置无需额外输入。")
                            .font(.system(size: 12)).foregroundStyle(Theme.text3)
                    }
                    ForEach(document.inputs) { input in
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(input.label).font(.system(size: 12, weight: .medium))
                                Text(input.id + " · " + input.target)
                                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.text3).textSelection(.enabled)
                            }
                            Spacer()
                            Text(session.suppliedIds.contains(input.id) ? "已提供 · 隐藏" : "必填 · 待提供")
                                .font(.system(size: 11)).foregroundStyle(session.suppliedIds.contains(input.id) ? Theme.text3 : Theme.amber)
                        }
                    }
                    if !document.inputs.isEmpty {
                        Text("输入文件格式为 {\"输入 ID\": 标量值}，上限 64 KiB。缺少秘密值时不会保存或清空已有值。")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                    }
                }
                .font(.system(size: 12)).tint(Theme.text3)
            }
            if let preview = session.preview { previewContent(preview) }
        }
    }

    private func previewContent(_ preview: PortableConfigSession.Preview) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Divider()
            Text(preview.existingId == nil ? "将登记新项目 · \(preview.name)" : "将更新 \(preview.name) · 预览版本 v\(preview.revision ?? 0)")
                .font(.system(size: 13, weight: .semibold))
            if let id = preview.existingId { Text(id).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text3) }
            Text("服务：" + preview.serviceNames.joined(separator: "、") + " · 快捷操作 \(preview.actionCount) 项")
                .font(.system(size: 12)).foregroundStyle(Theme.text2)
            if preview.existingId != nil {
                Text(preview.changedPaths.isEmpty ? "未发现配置字段变化。" : "变更字段（最多 100 项；值不回显）：")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                if !preview.changedPaths.isEmpty { CodeBlock(text: preview.changedPaths.joined(separator: "\n")) }
                if !preview.protectedParamKeys.isEmpty {
                    Text("这些选项受用户值保护，导入不会覆盖其当前值：" + preview.protectedParamKeys.joined(separator: "、"))
                        .font(.system(size: 11.5)).foregroundStyle(Theme.amber)
                }
            }
            Text(preview.validation.ok ? "校验通过 · 可以保存；不会启动或重启" : "校验未通过 · 修正后重新预览")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(preview.validation.ok ? Theme.green : Theme.red)
            ForEach(Array(preview.validation.issues.enumerated()), id: \.offset) { _, issue in
                Text(issue.path + " · " + issue.code.rawValue)
                    .font(.system(size: 11.5)).foregroundStyle(Theme.amber)
            }
        }
    }

    private func fileRow(_ title: String, path: String?, button: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title).font(.system(size: 12, weight: .medium)).frame(width: 90, alignment: .leading)
            Text(path ?? "尚未选择").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(path == nil ? Theme.text3 : Theme.text2)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button(button, action: action).disabled(session.busy)
        }
    }

    private func chooseDocument() {
        if let url = chooseFile(message: "选择 devpanel.project v1 共享配置（不超过 1 MiB）") { session.loadDocument(url) }
    }
    private func chooseInputs() {
        if let url = chooseFile(message: "选择本机输入 JSON（不超过 64 KiB，内容不回显）") { session.loadInputs(url) }
    }
    private func chooseFile(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]; panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }
    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = "选择此配置在本机对应的项目根目录"
        if panel.runModal() == .OK, let url = panel.url { session.setRoot(url) }
    }
    private func saveExport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "devpanel.json"
        panel.message = "选择新文件名；已有文件不会被覆盖"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try session.saveExport(to: url)
            presenter.show(.init(tone: .ok, text: "共享配置已导出到 \(url.path)"))
            presenter.close()
        } catch { fileNotice = "导出未完成。请选择不存在的新文件名，并检查目录写入权限。" }
    }
}
