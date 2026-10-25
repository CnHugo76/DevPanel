import Foundation
import Testing
@testable import DevPanelKit

struct ReadyTests {
    @Test func readyConfigRoundTripAndInlinePreview() throws {
        let json = #"{"schemaVersion":1,"name":"ready","root":"/tmp","services":[{"id":"app","name":"App","cwd":".","command":["node","app.js"],"ready":{"check":{"kind":"port","port":"${port}"},"timeoutSec":12}}],"params":[{"key":"port","label":"Port","type":"number","value":8080,"usedBy":[{"serviceId":"app","where":"ready"}]}]}"#
        let config = try JSONDecoder().decode(ProjectConfig.self, from: Data(json.utf8))
        let draft = ProjectDraft(config: config)
        #expect(draft.services[0].readyKind == "port")
        #expect(draft.services[0].readyPortText == "${port}")
        let built = draft.build(.save)
        #expect(built.errors.isEmpty)
        #expect(built.config.services[0].ready == config.services[0].ready)
        let preview = OptionRules.references(config.params![0], config: config, inline: true)
        #expect(preview.count == 1)
        #expect(preview[0].location.contains("就绪端口"))
    }
    @Test func readyEditorValidatesAndPreservesText() {
        var draft = ProjectDraft(name: "ready", root: "/tmp", services: [ServiceDraft(serviceId: "app", idAuto: false, name: "App", commandText: "node app.js")])
        draft.services[0].readyKind = "log"
        draft.services[0].readyContainsText = "Ready\nStarted Demo"
        #expect(draft.build(.save).config.services[0].ready?.check.contains == ["Ready", "Started Demo"])
        draft.services[0].readyTimeoutText = "901"
        #expect(draft.build(.save).errors["services[0].ready.timeoutSec"] != nil)
    }
    @Test func readyPresentationAndForwardCompatibility() throws {
        let json = #"{"state":"ready","at":"now","afterMs":12300,"evidence":{"kind":"log","seq":214}}"#
        let ready = try JSONDecoder().decode(ReadyInfo.self, from: Data(json.utf8))
        #expect(ready.label == "已就绪")
        #expect(ready.explanation == "启动后 12.3 秒就绪 · 依据：日志第 214 行")
        let future = try JSONDecoder().decode(ReadyInfo.self, from: Data(#"{"state":"future"}"#.utf8))
        #expect(future.label == nil)
        #expect(future.state == .other("future"))
    }
}
