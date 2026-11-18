import Foundation
import Testing
@testable import DevPanelKit

@Suite("Service shortcut addresses")
@MainActor
struct ServiceLinkTests {
    private let frontend = ServiceRef("project-a", "frontend")

    @Test func hostAndPortPresetsPreserveCustomComponents() {
        let original = "https://old.example:18085/a%20b?q=a%2Fb#part"
        #expect(ServiceLinkSuggestions.address(original, host: "127.0.0.1") == "https://127.0.0.1:18085/a%20b?q=a%2Fb#part")
        #expect(ServiceLinkSuggestions.address(original, port: 5173) == "https://old.example:5173/a%20b?q=a%2Fb#part")
        #expect(ServiceLinkSuggestions.address("", host: "192.168.1.12", defaultPort: 8080) == "http://192.168.1.12:8080/")
        #expect(ServiceLinkSuggestions.address("http://[::1]:8080/path", host: "localhost") == "http://localhost:8080/path")
        #expect(ServiceLinkSuggestions.address("", host: "localhost") == "http://localhost/")
        #expect(ServiceLinkSuggestions.address(original, port: 65536) == original)
    }

    @Test func portsUseListeningAndStoppedServiceReadiness() {
        let config = ServiceConfig(id: "frontend", name: "Front", cwd: ".", command: ["node", "app.js"],
                                   ready: ReadyConfig(check: ReadyCheck(kind: .port, port: .string("${webPort}"))))
        let params = [ParamConfig(key: "webPort", label: "端口", type: .number, value: .number(18085))]
        #expect(ServiceLinkSuggestions.ports(listening: nil, config: config, params: params) == [18085])
        let listening = [ListeningPort(port: 5173, address: "127.0.0.1", family: .ipv4, scope: .loopback, pid: 12),
                         ListeningPort(port: 5173, address: "::1", family: .ipv6, scope: .loopback, pid: 12)]
        #expect(ServiceLinkSuggestions.ports(listening: listening, config: config, params: params) == [5173, 18085])
        var secret = params[0]
        secret.secret = true
        #expect(ServiceLinkSuggestions.ports(listening: nil, config: config, params: [secret]).isEmpty)
        #expect(ServiceLinkSuggestions.ports(listening: nil, config: nil, params: []).isEmpty)
    }

    @Test func privateNetworkSuggestionsExcludeUnusableAddresses() {
        for host in ["10.0.0.2", "172.16.0.1", "172.31.255.1", "192.168.10.20"] {
            #expect(LocalNetworkAddress.isPrivateIPv4(host))
        }
        for host in ["127.0.0.1", "0.0.0.0", "169.254.2.1", "8.8.8.8", "172.15.1.2", "172.32.1.2", "192.168.1.256", "192.168.1", "192.168.1."] {
            #expect(!LocalNetworkAddress.isPrivateIPv4(host))
        }
    }

    @Test func acceptedDestinations() {
        let values = [
            "http://192.168.10.20:18085/",
            "https://dev.example.com/app/index.html?mode=preview#section",
            "http://localhost:5173/",
            "http://[::1]:8080/path",
            "https://example.com/a%20b?q=a%2Fb",
        ]
        for value in values {
            #expect(ServiceShortcutAddress.validationMessage(value) == nil)
            #expect(ServiceShortcutAddress.url(value)?.absoluteString == value)
        }
        #expect(ServiceShortcutAddress.validationMessage("  \n") == nil)
        #expect(ServiceShortcutAddress.url("  https://example.com/  ")?.absoluteString == "https://example.com/")
        #expect(ServiceShortcutAddress.url("https://例子.中国/路径")?.absoluteString == "https://xn--fsqu00a.xn--fiqs8s/%E8%B7%AF%E5%BE%84")
    }

    @Test func invalidDestinations() {
        for value in ["localhost:18085", "/path", "//example.com", "http://", "http:///path",
                      "https://?q=1", "ftp://example.com", "file:///tmp/index.html",
                      "javascript:alert(1)", "https://example.com:0", "http://example.com:65536",
                      "http://example.com:-1", "http://example.com:abc", "http://example.com:999999999999999999999/", "http://bad host/",
                      "https://example.com/a b", "https://example.com/a\nb", "https://example.com/%ZZ"] {
            #expect(ServiceShortcutAddress.url(value) == nil, "Should reject \(value)")
            #expect(ServiceShortcutAddress.validationMessage(value) != nil)
        }
    }

    @Test func overrideIsImmediateAndScopedToService() {
        let links = ServiceLinkPreferences(defaults: nil)
        #expect(links.url(for: frontend, port: 18085).absoluteString == "http://localhost:18085")
        #expect(links.save("http://192.168.10.20:18085/", for: frontend) == nil)
        #expect(links.url(for: frontend, port: 18085).absoluteString == "http://192.168.10.20:18085/")
        // One destination per service, even when it exposes more than one port.
        #expect(links.url(for: frontend, port: 5005).absoluteString == "http://192.168.10.20:18085/")
        #expect(links.url(for: ServiceRef("project-a", "backend"), port: 8080).absoluteString == "http://localhost:8080")
        #expect(links.url(for: ServiceRef("project-b", "frontend"), port: 18085).absoluteString == "http://localhost:18085")
        #expect(links.save("https://", for: frontend) != nil)
        #expect(links.url(for: frontend, port: 18085).absoluteString == "http://192.168.10.20:18085/")
        #expect(links.save("", for: frontend) == nil)
        #expect(links.url(for: frontend, port: 5173).absoluteString == "http://localhost:5173")
    }

    @Test func persistsAcrossPreferenceInstancesAndReset() throws {
        let suite = "devpanel-tests-service-links-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = ViewPreferences(defaults: defaults)
        #expect(first.serviceLinks.save("http://192.168.10.20:18085/", for: frontend) == nil)
        let reopened = ViewPreferences(defaults: UserDefaults(suiteName: suite))
        #expect(reopened.serviceLinks.url(for: frontend, port: 18085).absoluteString == "http://192.168.10.20:18085/")
        #expect(reopened.serviceLinks.save(" \n", for: frontend) == nil)
        let reset = ViewPreferences(defaults: UserDefaults(suiteName: suite))
        #expect(reset.serviceLinks.customURL(for: frontend) == nil)
        #expect(reset.serviceLinks.url(for: frontend, port: 18085).absoluteString == "http://localhost:18085")
    }

    @Test func tooltipMatchesOpenedURLAndKeepsListeningEvidence() throws {
        let links = ServiceLinkPreferences(defaults: nil)
        links.save("http://192.168.10.20:18085/", for: frontend)
        guard case .ports(let chips) = PortCell.make([
            ListeningPort(port: 18085, address: "127.0.0.1", family: .ipv4, scope: .loopback, pid: 123),
        ], active: true) else { Issue.record("Missing port chip"); return }
        let chip = try #require(chips.first)
        let target = links.url(for: frontend, port: chip.port)
        #expect(chip.help(opening: target).contains("监听 127.0.0.1:18085"))
        #expect(chip.help(opening: target).contains("点击在浏览器打开 http://192.168.10.20:18085/"))
        #expect(chip.port == 18085)
        #expect(!chip.lan)
        #expect(chip.url.absoluteString == "http://localhost:18085")
    }
}
