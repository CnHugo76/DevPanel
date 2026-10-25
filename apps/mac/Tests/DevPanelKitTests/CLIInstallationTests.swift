import Foundation
import Testing
@testable import DevPanelKit

@Suite("发布包命令安装") struct CLIInstallationTests {
    @Test func bundledPreferenceAndDevelopmentFallback() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("dp-bundle-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let app = home.appendingPathComponent("DevPanel.app")
        let path = app.appendingPathComponent("Contents/Resources/runtime/bin/devpanel")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        #expect(DaemonLauncher.preferredCLIPath(bundleURL: app, environment: [:], userHome: home) == path)
        #expect(DaemonLauncher.preferredCLIPath(bundleURL: app, environment: ["DEVPANEL_HOME": "/tmp/dev"], userHome: home) == home.appendingPathComponent(".local/bin/devpanel"))
    }

    @Test func replacementRequiresReviewAndDetectsChanges() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("dp-install-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let runtime = home.appendingPathComponent("runtime"), bin = home.appendingPathComponent("chosen bin")
        try FileManager.default.createDirectory(at: runtime.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in ["devpanel", "devpaneld"] {
            let path = runtime.appendingPathComponent("bin/\(name)")
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }
        let target = bin.appendingPathComponent("devpanel")
        try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: "/missing/stable/devpanel")
        let installer = CLIInstallation(runtime: runtime)
        let plan = try installer.inspect(directory: bin)
        #expect(plan.needsConfirmation)
        #expect(plan.destinations[0].existing?.contains("/missing/stable/devpanel") == true)
        #expect(throws: (any Error).self) { try installer.install(plan) }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target.path) == "/missing/stable/devpanel")
        try Data("existing foreign command".utf8).write(to: bin.appendingPathComponent("devpaneld"))
        #expect(throws: (any Error).self) { try installer.install(plan, confirmedReplacement: true) }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target.path) == "/missing/stable/devpanel")
        let reviewed = try installer.inspect(directory: bin)
        #expect(reviewed.destinations[1].existing == "existing foreign command")
        try installer.install(reviewed, confirmedReplacement: true)
        for name in ["devpanel", "devpaneld"] {
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: bin.appendingPathComponent(name).path) == runtime.appendingPathComponent("bin/\(name)").path)
        }
    }
}
