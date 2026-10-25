import DevPanelKit
import SwiftUI

/// ui-design v2 §7: daemon not running → prompt + "启动管理服务". Never starts a project.
struct NotRunningView: View {
    let model: AppModel
    private let launcher = DaemonLauncher()
    private let home = DaemonHome.resolve()
    @Environment(AppController.self) private var controller: AppController?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "power.circle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.text3)
            Text("管理服务未运行")
                .font(.title2.weight(.semibold))
            Text("DevPanel 通过管理服务启动和停止项目。启动管理服务不会启动任何项目。")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            if model.connection.staleDiscovery {
                Text("发现文件存在，但无法连接到它记录的端口；管理服务可能已异常退出。")
                    .font(.callout)
                    .foregroundStyle(Theme.amber)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }

            Button {
                Task { await model.startDaemon() }
            } label: {
                HStack(spacing: 6) {
                    if model.daemonLaunch == .launching {
                        ProgressView().controlSize(.small)
                    }
                    Text(model.daemonLaunch == .launching ? "正在启动…" : "启动管理服务")
                }
                .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.daemonLaunch == .launching)
            .padding(.top, 4)

            if !launcher.isInstalled {
                Text(home.isOverridden
                     ? "开发环境未找到可用入口。请按接入指引，使用源码 CLI 启动同一隔离目录的管理服务。"
                     : "没有找到命令行工具。请检查 App 是否完整，或按接入指引配置源码 CLI。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            if let controller {
                Button("查看接入指引…") { controller.showOnboarding = true }
            }
            if case .failed(let message) = model.daemonLaunch {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(Theme.red)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 460)
            }
            if home.isOverridden {
                Text("数据目录：\(home.url.path)（DEVPANEL_HOME）")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(40)
    }
}
