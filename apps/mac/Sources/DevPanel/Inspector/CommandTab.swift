import DevPanelKit
import SwiftUI

/// "命令与环境" (ui-design v2 §4), read-only: the saved command (placeholders as written, plus a
/// preview with the current param values), working directory, environment (secrets hidden) and
/// stop timeout. Editing is the project sheet's job (F5).
struct CommandTab: View {
    let model: AppModel
    let ref: ServiceRef
    let project: ProjectView
    @Environment(EditorPresenter.self) private var editor: EditorPresenter?
    @Environment(\.isStale) private var stale

    var body: some View {
        if let config = model.serviceConfig(ref.projectId, ref.serviceId) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    commandSection(config)
                    InspectorSection(title: "工作目录") {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(config.cwd)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Theme.text)
                                .textSelection(.enabled)
                            Text(Format.tildePath(resolvedCwd(config.cwd)))
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(Theme.text3)
                                .textSelection(.enabled)
                                .help(resolvedCwd(config.cwd))
                        }
                    }
                    envSection(config)
                    InspectorSection(title: "停止等待") {
                        Text(stopTimeout(config))
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.text)
                    }
                    footer
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        } else {
            ProgressView("配置读取中…")
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func commandSection(_ config: ServiceConfig) -> some View {
        let params = model.params(ref.projectId)
        return InspectorSection(title: "命令") {
            CodeBlock(text: CommandText.join(config.command))
            if CommandText.hasPlaceholders(config.command) {
                Text("按当前选项值，下次启动将执行：")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text3)
                    .padding(.top, 4)
                CodeBlock(text: CommandText.join(CommandText.substitute(config.command, params: params)), muted: true)
            }
        }
    }

    private func envSection(_ config: ServiceConfig) -> some View {
        let rows = EnvDisplayRow.make(
            project: model.configs[ref.projectId]?.config.env, service: config.env, params: model.params(ref.projectId))
        return InspectorSection(title: "环境变量") {
            if rows.isEmpty {
                Text("没有设置环境变量（使用管理服务的基础环境）")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                        if i > 0 { Rectangle().fill(Theme.line).frame(height: 1) }
                        envRow(row)
                    }
                }
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.line))
            }
        }
    }

    private func envRow(_ row: EnvDisplayRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(row.key)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                if row.source == .project {
                    Text("项目")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.text3)
                        .padding(.horizontal, 4)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.line2))
                        .help("项目级环境变量，所有服务共用")
                }
                Spacer(minLength: 8)
                if row.secret {
                    Label("敏感值已隐藏", systemImage: "lock.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.text3)
                }
            }
            Text(row.value)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(row.secret ? Theme.text3 : Theme.text2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let preview = row.preview, preview != row.value {
                Text("→ \(preview)")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.text3)
                    .textSelection(.enabled)
                    .help("按当前选项值")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("编辑…") { editor?.edit(ref.projectId) }
                .disabled(editor == nil || stale)
                .help(stale ? "与管理服务的连接中断，暂时不能编辑" : "编辑项目配置")
            Text("改动只在下次启动时生效。")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.text3)
        }
        .padding(.top, 4)
    }

    private func resolvedCwd(_ cwd: String) -> String {
        if cwd.hasPrefix("/") { return cwd }
        let root = project.root as NSString
        return (root.appendingPathComponent(cwd) as NSString).standardizingPath
    }

    private func stopTimeout(_ config: ServiceConfig) -> String {
        if let s = config.stopTimeoutSec { return "\(s) 秒后仍未退出则提示强制停止" }
        let d = model.daemon?.limits.defaultStopTimeoutSec ?? 10
        return "\(d) 秒（默认）后仍未退出则提示强制停止"
    }
}
