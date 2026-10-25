import Foundation
import Testing
@testable import DevPanelKit

@Suite("托管规则") struct PolicyTests {
    @Test func oldDaemonAndOpenPolicyEnum() throws {
        let view = try Fixture.decode([ProjectView].self, "recorded/projects.json")
        #expect(view.allSatisfy { $0.policy == nil })
        #expect(view.flatMap(\.services).allSatisfy { $0.hold == nil && $0.locked == nil })
        let policy = try ContractCoding.decoder().decode(ProjectPolicy.self, from: Data(#"{"holdAfterUserStop":true,"agentForceStop":"future","lockedServices":["web"]}"#.utf8))
        #expect(policy.agentForceStop == .other("future"))
    }
    @Test func policyUsesIndependentRouteAndUIHeaders() async throws {
        let transport = FakeTransport { request in
            if request.httpMethod == "DELETE" { return (204, Data()) }
            return (200, Data(#"{"holdAfterUserStop":true,"agentForceStop":"deny","lockedServices":["web"]}"#.utf8))
        }
        let client = testClient(transport)
        _ = try await client.policy("p_1")
        _ = try await client.setPolicy("p_1", ProjectPolicy(lockedServices: ["web"]))
        try await client.releaseHold("p_1", serviceId: "web")
        let requests = transport.requests.current
        #expect(requests.map { $0.url?.path } == ["/api/v1/projects/p_1/policy", "/api/v1/projects/p_1/policy", "/api/v1/projects/p_1/services/web/hold"])
        #expect(requests[1].value(forHTTPHeaderField: "X-DevPanel-Client") == "ui")
        #expect(requests[2].value(forHTTPHeaderField: "X-DevPanel-Client") == "ui")
        let body = try #require(requests[1].httpBody)
        #expect(String(decoding: body, as: UTF8.self).contains("lockedServices"))
        #expect(!String(decoding: body, as: UTF8.self).contains("config"))
    }
}
