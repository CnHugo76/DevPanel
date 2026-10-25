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
    @State private var actual: RunDetail?
    @State private var loadError: String?
    @State private var loading = false

    private var viewedId: RunID? { model.viewedRunId(for: ref) }

    var body: some View {
        if let config = model.serviceConfig(ref.projectId, ref.serviceId) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let viewedId {
                        RunPicker(model: model, ref: .service(ref), runs: model.runs(for: ref).map(LogRun.service),
                                  viewedId: viewedId, currentId: project.service(ref.serviceId)?.currentRun?.id)
                        Text("对照运行 \(Format.shortRunId(viewedId)) 与下次启动配置 v\(project.revision)")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
                        if let actual, actual.id == viewedId, let saved = model.configs[ref.projectId]?.config {
                            comparison(actual, config: config, projectConfig: saved)
                        } else if loading {
                            ProgressView("读取所选运行的实际配置…").controlSize(.small)
                        } else if let loadError {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(loadError).foregroundStyle(Theme.red)
                                Button("重新读取运行") { Task { await loadActual(viewedId) } }
                            }.font(.system(size: 12))
                        }
                        Divider()
                    } else {
                        Text("尚无运行记录，以下是下次启动使用的保存配置。")
                            .font(.system(size: 12)).foregroundStyle(Theme.text3)
                    }
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
            .task(id: RunLoadKey(id: viewedId, connected: model.isConnected)) { await loadActual(viewedId) }
        } else {
            ProgressView("配置读取中…")
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private struct RunLoadKey: Hashable { var id: RunID?; var connected: Bool }

    private func loadActual(_ id: RunID?) async {
        actual = nil
        loadError = nil
        loading = false
        guard let id else { return }
        guard model.isConnected, let client = model.client else {
            loadError = "尚未连接管理服务，无法读取所选运行的实际配置。"
            return
        }
        loading = true
        do {
            let detail = try await client.run(id)
            guard !Task.isCancelled, viewedId == id else { return }
            guard detail.id == id, detail.projectId == ref.projectId, detail.serviceId == ref.serviceId else {
                throw ApiError(code: .internal, message: "运行详情不匹配，请重新读取。")
            }
            actual = detail
        } catch {
            guard !Task.isCancelled, viewedId == id else { return }
            loadError = error.localizedDescription
        }
        guard !Task.isCancelled, viewedId == id else { return }
        loading = false
    }

    private func comparison(_ run: RunDetail, config: ServiceConfig, projectConfig: ProjectConfig) -> some View {
        let diff = RunComparison(run: run, config: config, project: projectConfig)
        return VStack(alignment: .leading, spacing: 14) {
            Text("实际配置 v\(run.configRevision) · \(run.startedAt)")
                .font(.system(size: 11)).foregroundStyle(Theme.text3).textSelection(.enabled)
            comparedField("命令", actual: CommandText.join(run.command), next: CommandText.join(diff.nextCommand), changed: diff.commandChanged)
            if diff.commandMasked {
                Text("命令含已隐藏内容；仅比较可见部分，无法判断敏感值是否相同。")
                    .font(.system(size: 11)).foregroundStyle(Theme.text3)
            }
            comparedField("工作目录", actual: run.cwd, next: diff.nextCwd, changed: diff.cwdChanged)
            if !diff.params.isEmpty {
                InspectorSection(title: "启动选项 · 实际 → 下次") {
                    ForEach(diff.params) { row in
                        HStack(alignment: .top, spacing: 8) {
                            Text(row.key).frame(width: 100, alignment: .leading)
                            Text(row.actual + "  →  " + row.next).frame(maxWidth: .infinity, alignment: .leading)
                            Text(row.masked ? "无法比较" : row.changed ? "已变化" : "相同")
                                .font(.system(size: 10.5)).foregroundStyle(row.changed ? Theme.amber : Theme.text3)
                        }
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                    }
                }
            }
            InspectorSection(title: "运行时环境变量名") {
                CodeBlock(text: run.envKeys.isEmpty ? "未记录环境变量" : run.envKeys.sorted().joined(separator: ", "))
                Text("实际环境变量值未保存，不能与下次启动值比较。")
                    .font(.system(size: 11)).foregroundStyle(Theme.text3)
            }
        }
    }

    private func comparedField(_ label: String, actual: String, next: String, changed: Bool) -> some View {
        InspectorSection(title: label + (changed ? " · 已变化" : " · 可见内容相同")) {
            Text("所选运行实际使用").font(.system(size: 11)).foregroundStyle(Theme.text3)
            CodeBlock(text: actual)
            Text("下次启动将使用").font(.system(size: 11)).foregroundStyle(changed ? Theme.amber : Theme.text3)
            CodeBlock(text: next, muted: true)
        }
    }

    private func commandSection(_ config: ServiceConfig) -> some View {
        let params = model.params(ref.projectId)
        return InspectorSection(title: "下次启动 · 命令模板") {
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
        return InspectorSection(title: "下次启动 · 环境变量") {
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
