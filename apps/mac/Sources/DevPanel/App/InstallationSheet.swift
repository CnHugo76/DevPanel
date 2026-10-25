import AppKit
import DevPanelKit
import SwiftUI

/// 沿用项目编辑 sheet：明确写入路径居前，可选登录启动在后。
struct InstallationSheet: View {
    let controller: AppController
    @State private var installCLI = true
    @State private var login = false
    @State private var directory: String
    @State private var plan: CLIInstallation.Plan?
    @State private var busy = false
    @State private var error: String?
    @State private var result: String?
    @State private var showGuide = false
    private var installer: CLIInstallation { CLIInstallation(runtime: controller.bundledRuntime) }
    private var showingGuide: Bool { showGuide || !controller.hasBundledCLI }
    init(controller: AppController) {
        self.controller = controller
        _directory = State(initialValue: controller.installationDirectory)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(showingGuide ? "接入第一个项目" : "准备好 DevPanel").font(.title2.weight(.semibold))
            Text(showingGuide ? "接下来确认终端入口，再登记你的项目。" : "下面两项都可以跳过，稍后从 DevPanel 菜单重新打开。")
                .foregroundStyle(Theme.text2)
            if showingGuide {
                ScrollView { OnboardingContent(controller: controller).padding(.vertical, 2) }.frame(maxHeight: 480)
            } else if let plan {
                Text("以下路径已存在").font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(plan.destinations.filter { $0.existing != nil }) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.path.path).fontWeight(.semibold)
                                Text(item.existing ?? "").foregroundStyle(Theme.text2)
                            }.font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 200).padding(12).background(Theme.card2)
                Text("确认后将替换为此 App 内的命令入口。原来的稳定版目录不会被修改。")
                    .foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
            } else {
                Toggle("安装命令行工具", isOn: $installCLI)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("安装目录（绝对路径）", text: $directory).textFieldStyle(.roundedBorder)
                        Button("选择…", action: chooseDirectory)
                    }
                    Text("将写入：\(directory)/devpanel\n\(directory)/devpaneld")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text2).textSelection(.enabled)
                    Text("不修改 shell 配置；请在终端或 Agent 的 PATH 中加入此目录。")
                        .font(.caption).foregroundStyle(Theme.text2)
                }.padding(.leading, 20).disabled(!installCLI)
                Divider()
                Toggle("登录时启动管理服务", isOn: $login)
                Text("只启动管理服务，不启动任何项目。默认关闭。")
                    .font(.caption).foregroundStyle(Theme.text2).padding(.leading, 20)
            }
            if let error { Text(error).foregroundStyle(Theme.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            if let result, !showGuide { Text(result).foregroundStyle(Theme.green).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                if plan != nil { Button("返回") { plan = nil; error = nil } }
                Button(result == nil && !showingGuide ? "稍后" : "完成") { controller.finishInstallation() }
                if result == nil, !showGuide, controller.hasBundledCLI {
                    Button(plan == nil ? "安装所选项" : "确认替换并安装") { prepareOrInstall() }
                        .buttonStyle(.borderedProminent).disabled(!installCLI && !login)
                } else if result != nil, !showGuide {
                    Button("下一步：接入项目") { showGuide = true }.buttonStyle(.borderedProminent)
                }
            }
        }
        .font(.system(size: 12.5)).padding(24).frame(width: showingGuide ? 600 : 520)
        .background(Theme.card).disabled(busy).interactiveDismissDisabled(busy)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: directory)
        if panel.runModal() == .OK, let url = panel.url { directory = url.path }
    }
    private func prepareOrInstall() {
        error = nil
        do {
            let candidate = try installCLI ? (plan ?? installer.inspect(directory: CLIInstallation.directory(from: directory))) : nil
            if let candidate, candidate.needsConfirmation, plan == nil { plan = candidate; return }
            busy = true
            Task { @MainActor in
                defer { busy = false }
                do {
                    if let candidate {
                        try installer.install(candidate, confirmedReplacement: plan != nil)
                        controller.rememberInstallationDirectory(candidate.directory)
                    }
                    if login {
                        let launcher = DaemonLauncher(cliPath: controller.bundledRuntime.appendingPathComponent("bin/devpanel"))
                        _ = try await launcher.installLoginItem()
                    }
                    result = "\(installCLI ? "CLI 已安装。" : "")\(login ? "登录启动已启用。" : "")"
                    plan = nil
                } catch { self.error = error.localizedDescription; plan = nil }
            }
        } catch { self.error = error.localizedDescription; plan = nil }
    }
}
