import Foundation
import Testing
@testable import DevPanelKit

@Suite("项目接入指引") struct OnboardingTests {
    @Test func verificationUsesChosenEntryAndIsolatedHome() throws {
        let directory = URL(fileURLWithPath: "/tmp/选定目录's $(not-a-command)/bin")
        let guide = OnboardingGuide(runtime: URL(fileURLWithPath: "/tmp/DevPanel.app/runtime"),
                                    directory: directory, isolatedHome: "/tmp/development home")
        let commands = guide.verificationCommand.components(separatedBy: "\n")
        // Parsing the last command must recover exactly one executable path, including metacharacters.
        #expect(ShellWords.split(commands.last!).argv == [directory.appendingPathComponent("devpanel").path, "daemon", "status", "--json"])
        #expect(commands[0] == "export DEVPANEL_HOME='/tmp/development home'")
        #expect(guide.bundledCLI?.path == "/tmp/DevPanel.app/runtime/bin/devpanel")
        #expect(guide.installedCLI != guide.bundledCLI)
        #expect(guide.agentInstruction.contains("DEVPANEL_HOME='/tmp/development home'"))
    }

    @Test func sourceGuideNeverUsesStableCLIAndKeepsOneDevelopmentHome() {
        let guide = OnboardingGuide(runtime: nil, directory: URL(fileURLWithPath: "/tmp/bin"))
        #expect(guide.verificationCommand.contains("mktemp -d /tmp/dp-dev."))
        #expect(guide.verificationCommand.contains("node packages/cli/src/main.ts daemon status --json"))
        #expect(guide.sourceStartCommand.contains("DEVPANEL_HOME:?"))
        #expect(!guide.sourceStartCommand.contains("mktemp"))
        #expect(!guide.agentInstruction.contains(".local/bin"))
        let isolated = OnboardingGuide(runtime: nil, directory: URL(fileURLWithPath: "/tmp/bin"), isolatedHome: "/tmp/dp-test")
        #expect(isolated.sourceStartCommand.hasPrefix("export DEVPANEL_HOME=/tmp/dp-test\n"))
    }

    @Test func directoryValidationPrecedesURLNormalization() throws {
        for path in ["", "relative/bin", "~/bin", "/tmp/\0bin"] {
            #expect(throws: CLIInstallation.Failure.self) { try CLIInstallation.directory(from: path) }
        }
        #expect(try CLIInstallation.directory(from: "/tmp/chosen dir/../bin").path == "/tmp/bin")
    }

    @Test func bundledGuideUsesLocalSkillAndQuickstartWhenPresent() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("dp-guide-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let resources = home.appendingPathComponent("Contents/Resources")
        let guide = OnboardingGuide(runtime: resources.appendingPathComponent("runtime"), directory: home.appendingPathComponent("bin"))
        #expect(guide.bundledSkill == nil)
        #expect(guide.bundledQuickstart == nil)
        let skill = resources.appendingPathComponent("skills/devpanel/SKILL.md")
        try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("skill".utf8).write(to: skill)
        try Data("quickstart".utf8).write(to: resources.appendingPathComponent("quickstart.zh-CN.md"))
        #expect(guide.bundledSkill == skill.deletingLastPathComponent())
        #expect(guide.bundledQuickstart == resources.appendingPathComponent("quickstart.zh-CN.md"))
        #expect(guide.agentInstruction.contains(skill.path))
        #expect(!guide.agentInstruction.contains("https://github.com"))
    }

    @Test func installedStatusRequiresBothLinksToThisRuntime() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("dp-guide-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let runtime = home.appendingPathComponent("runtime"), directory = home.appendingPathComponent("chosen bin")
        let installer = CLIInstallation(runtime: runtime)
        try FileManager.default.createDirectory(at: runtime.appendingPathComponent("bin"), withIntermediateDirectories: true)
        for name in ["devpanel", "devpaneld"] {
            let executable = runtime.appendingPathComponent("bin/\(name)")
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        #expect(!installer.isLinked(in: directory))
        try installer.install(installer.inspect(directory: directory))
        #expect(installer.isLinked(in: directory))
        let daemonLink = directory.appendingPathComponent("devpaneld")
        try FileManager.default.removeItem(at: daemonLink)
        try FileManager.default.createSymbolicLink(atPath: daemonLink.path,
                                                withDestinationPath: runtime.appendingPathComponent("bin/devpanel").path)
        #expect(!installer.isLinked(in: directory))
        // Checking does not silently repair or replace the mismatched entry.
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: daemonLink.path).hasSuffix("/bin/devpanel"))
    }
}
