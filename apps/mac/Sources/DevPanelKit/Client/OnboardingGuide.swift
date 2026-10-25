import Foundation

/// Read-only setup instructions. Generating or copying them never launches a command.
public struct OnboardingGuide: Sendable {
    public static let skillURL = URL(string: "https://github.com/CnHugo76/DevPanel/tree/main/skills/devpanel")!
    public static let sourceURL = URL(string: "https://github.com/CnHugo76/DevPanel/blob/main/README.zh-CN.md")!

    public let runtime: URL?
    public let directory: URL
    public let isolatedHome: String?

    public init(runtime: URL?, directory: URL, isolatedHome: String? = nil) {
        self.runtime = runtime
        self.directory = directory
        self.isolatedHome = isolatedHome
    }

    public var isSourceBuild: Bool { runtime == nil }
    public var installedCLI: URL { directory.appendingPathComponent("devpanel") }
    public var bundledCLI: URL? { runtime?.appendingPathComponent("bin/devpanel") }
    public var bundledSkill: URL? { bundledResource("skills/devpanel/SKILL.md")?.deletingLastPathComponent() }
    public var bundledQuickstart: URL? { bundledResource("quickstart.zh-CN.md") }

    private func bundledResource(_ path: String) -> URL? {
        guard let runtime else { return nil }
        let url = runtime.deletingLastPathComponent().appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The absolute installed path makes the status check independent of another CLI on PATH.
    public var verificationCommand: String {
        if isSourceBuild {
            return sourceEnvironment + "\nnode packages/cli/src/main.ts daemon status --json"
        }
        let home = isolatedHome.map { "export DEVPANEL_HOME=" + ShellWords.quote($0) + "\n" } ?? ""
        return home + "export PATH=" + ShellWords.quote(directory.path) + ":\"$PATH\"\ncommand -v devpanel\n"
            + ShellWords.quote(installedCLI.path) + " daemon status --json"
    }

    public var sourceStartCommand: String {
        let home = isolatedHome.map { "export DEVPANEL_HOME=" + ShellWords.quote($0) }
            ?? ": \"${DEVPANEL_HOME:?请先在同一终端运行上面的确认命令}\""
        return home + "\nnode packages/cli/src/main.ts daemon start --json"
    }

    private var sourceEnvironment: String {
        if let isolatedHome { return "export DEVPANEL_HOME=" + ShellWords.quote(isolatedHome) }
        return "export DEVPANEL_HOME=\"$(mktemp -d /tmp/dp-dev.XXXXXX)\""
    }

    public var agentInstruction: String {
        let environment = isolatedHome.map {
            "本次使用隔离数据目录，所有 DevPanel 命令都必须设置 DEVPANEL_HOME=" + ShellWords.quote($0) + "。\n"
        } ?? ""
        let entry = isSourceBuild
            ? "这是源码开发包，请先确认 DevPanel 源码 CLI 和隔离数据目录；不要调用用户稳定版 CLI。"
            : "DevPanel CLI 的已选安装路径是 \(installedCLI.path)。先确认该入口可用，不要换用其他安装。"
        let skill = bundledSkill?.appendingPathComponent("SKILL.md").path ?? Self.skillURL.absoluteString
        return """
        请把当前项目加入 DevPanel，先完成配置，不启动服务。
        \(environment)\(entry)
        先读取 DevPanel skill（\(skill)），确认管理服务可达，并在你自己的环境配置中设置 DEVPANEL_AGENT 为你的名称。
        根据项目实际文件识别长期运行服务，登记工作目录、前台启动命令、常改参数和日志或端口就绪条件。校验后注册；已有项目则检查差异并更新，保留用户设置和敏感值。
        把统一使用 DevPanel 启停和读日志的规则合并到项目的 Agent 规则文件。最后报告项目 ID、服务、校验结果、未满足的环境要求；等待我明确要求后再启动。
        """
    }
}
