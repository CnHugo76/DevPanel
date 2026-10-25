import AppKit
import DevPanelKit
import SwiftUI

/// A repeatable handoff from local installation to the user's existing coding Agent.
struct OnboardingSheet: View {
    let controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("接入第一个项目").font(.title2.weight(.semibold))
            Text("先确认命令入口，再让你的编程 Agent 登记项目。")
                .foregroundStyle(Theme.text2)
            ScrollView { OnboardingContent(controller: controller).padding(.vertical, 2) }
                .frame(maxHeight: 480)
            HStack {
                if controller.hasBundledCLI {
                    Button("安装设置…") {
                        controller.showOnboarding = false
                        controller.openInstallationAfterGuide = true
                    }
                }
                Spacer()
                Button("完成") { controller.showOnboarding = false }.keyboardShortcut(.defaultAction)
            }
        }
        .font(.system(size: 12.5)).foregroundStyle(Theme.text)
        .padding(24).frame(width: 600).background(Theme.card)
    }
}

struct OnboardingContent: View {
    let controller: AppController
    @State private var linked = false
    private var guide: OnboardingGuide { controller.onboardingGuide }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                step("1", "在终端确认 CLI")
                if guide.isSourceBuild {
                    Text("这是源码开发包，未内置 CLI。在 DevPanel 仓库根目录运行下面的命令，使用隔离数据目录。")
                        .foregroundStyle(Theme.text2)
                    SetupCommandBlock(text: guide.verificationCommand)
                    DisclosureGroup("管理服务未运行时") {
                        Text("在同一个终端启动隔离管理服务，再打开继承同一 DEVPANEL_HOME 的开发 App。")
                            .foregroundStyle(Theme.text2).padding(.vertical, 4)
                        SetupCommandBlock(text: guide.sourceStartCommand)
                    }
                } else {
                    HStack(spacing: 8) {
                        Label(linked ? "CLI 入口已链接到此 App" : "CLI 入口尚未链接到此 App",
                              systemImage: linked ? "checkmark.circle" : "exclamationmark.circle")
                            .foregroundStyle(linked ? Theme.green : Theme.amber)
                        Spacer(minLength: 8)
                        Button("重新检查", action: checkLinks).controlSize(.small)
                    }
                    DisclosureGroup("CLI 位置") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("终端入口：\(guide.installedCLI.path)")
                            if let bundled = guide.bundledCLI { Text("App 内置入口：\(bundled.path)") }
                        }.font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .foregroundStyle(Theme.text2).padding(.vertical, 4)
                    }
                    SetupCommandBlock(text: guide.verificationCommand)
                    Text("export PATH 只调整当前终端，不写 shell 配置。command -v 的结果应是上面的终端入口；状态查询不会启动项目。")
                        .foregroundStyle(Theme.text2)
                    Text("找不到命令：返回安装设置检查目录。管理服务未运行：回到主窗口点“启动管理服务”。Agent 仍找不到命令时，检查它自己的 PATH 并重新加载。")
                        .foregroundStyle(Theme.text2)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                step("2", "为 Agent 安装 DevPanel skill")
                if let skill = guide.bundledSkill {
                    Text("App 已附带 devpanel skill。复制整个目录并保留 references/，放入所用 Agent 支持的 skill 目录。")
                        .foregroundStyle(Theme.text2)
                    Button("在 Finder 中显示随包 skill") { NSWorkspace.shared.activateFileViewerSelecting([skill]) }
                } else {
                    Text("从仓库下载 skills/devpanel 整个目录，保留 references/，放入所用 Agent 支持的 skill 目录。")
                        .foregroundStyle(Theme.text2)
                    Link("打开 DevPanel skill 与接入说明 ↗", destination: OnboardingGuide.skillURL)
                }
                Text("在 Agent 自身配置中设置 DEVPANEL_AGENT，例如 codex 或 claude-code，让面板显示操作来源。名称为自报信息。")
                    .foregroundStyle(Theme.text2)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                step("3", "让 Agent 登记当前项目")
                Text("在项目对应的对话中粘贴指令。登记完成后，面板会出现同一项目；再明确要求启动，查看启动结果与日志。")
                    .foregroundStyle(Theme.text2)
                SetupCopyButton(text: guide.agentInstruction, label: "复制接入指令")
                    .buttonStyle(.borderedProminent)
                DisclosureGroup("查看接入指令") {
                    Text(guide.agentInstruction).textSelection(.enabled)
                        .foregroundStyle(Theme.text2).padding(.vertical, 4)
                }
            }
            Text("只有经 DevPanel 启动的服务会出现在面板中。保存、校验和登记配置均不执行项目命令；普通终端或 Agent 自己启动的进程不会自动接管。")
                .foregroundStyle(Theme.text2)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.card2, in: RoundedRectangle(cornerRadius: 8))
            if let quickstart = guide.bundledQuickstart {
                VStack(alignment: .leading, spacing: 8) {
                    Text("想先试用？随包示例使用内置 Node，不需要安装额外运行时。")
                        .foregroundStyle(Theme.text2)
                    Button("打开随包快速开始") { NSWorkspace.shared.open(quickstart) }
                }
            } else {
                Link("打开源码构建与试用说明 ↗", destination: OnboardingGuide.sourceURL)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: checkLinks)
    }

    private func checkLinks() {
        guard let runtime = guide.runtime else { linked = false; return }
        linked = CLIInstallation(runtime: runtime).isLinked(in: guide.directory)
    }

    private func step(_ number: String, _ title: String) -> some View {
        HStack(spacing: 8) {
            Text(number).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent2)
                .frame(width: 20, height: 20).background(Theme.accentSoft, in: Circle())
                .accessibilityHidden(true)
            Text(title).font(.system(size: 13, weight: .semibold))
        }
    }
}

struct SetupCommandBlock: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); SetupCopyButton(text: text, label: "复制命令").controlSize(.small) }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card2, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct SetupCopyButton: View {
    let text: String
    let label: String
    @State private var copied = false

    var body: some View {
        Button(copied ? "已复制" : label) { copy(text); copied = true }
            .help(label)
            .task(id: copied) {
                guard copied else { return }
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled { copied = false }
            }
    }
}
