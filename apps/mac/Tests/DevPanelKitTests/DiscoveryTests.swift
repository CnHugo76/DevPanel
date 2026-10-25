import Foundation
import Testing

@testable import DevPanelKit

@Suite("Discovery")
struct DiscoveryTests {
    private func tempHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpanel-mac-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("home: default under Application Support, DEVPANEL_HOME overrides")
    func homeResolution() {
        let user = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        let def = DaemonHome.resolve(environment: [:], userHome: user)
        #expect(def.url.path == "/Users/someone/Library/Application Support/DevPanel")
        #expect(def.discoveryFile.path == "/Users/someone/Library/Application Support/DevPanel/daemon.json")
        #expect(!def.isOverridden)
        let empty = DaemonHome.resolve(environment: ["DEVPANEL_HOME": ""], userHome: user)
        #expect(empty == def)
        let over = DaemonHome.resolve(environment: ["DEVPANEL_HOME": "/repo/.devpanel-dev/mock"], userHome: user)
        #expect(over.url.path == "/repo/.devpanel-dev/mock")
        #expect(over.discoveryFile.lastPathComponent == "daemon.json")
        #expect(over.isOverridden)
    }

    @Test("missing file → nil (not running)")
    func missing() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(try DiscoveryReader(home: DaemonHome(url: home)).read() == nil)
        let gone = DaemonHome(url: home.appendingPathComponent("does-not-exist"))
        #expect(try DiscoveryReader(home: gone).read() == nil)
    }

    @Test func readsDiscovery() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Fixture.data("handwritten/discovery.json").write(to: home.appendingPathComponent("daemon.json"))
        let d = try #require(try DiscoveryReader(home: DaemonHome(url: home)).read())
        #expect(d.httpPort == 47823)
        #expect(d.token == "handwritten-fixture-token-not-a-secret")
    }

    @Test("garbage → unreadable; other apiVersion → incompatible")
    func badFiles() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("daemon.json")
        try Data("{\"pid\": 1, ".utf8).write(to: file)
        #expect {
            _ = try DiscoveryReader(home: DaemonHome(url: home)).read()
        } throws: { e in
            if case .unreadable = e as? DiscoveryError { return true }
            return false
        }
        var obj = try #require(try JSONSerialization.jsonObject(with: Fixture.data("handwritten/discovery.json")) as? [String: Any])
        obj["apiVersion"] = 2
        try JSONSerialization.data(withJSONObject: obj).write(to: file)
        #expect(throws: DiscoveryError.incompatibleAPI(2)) {
            _ = try DiscoveryReader(home: DaemonHome(url: home)).read()
        }
    }
}
