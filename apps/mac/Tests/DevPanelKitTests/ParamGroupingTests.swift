import Testing
@testable import DevPanelKit

@Suite("Overview option grouping")
struct ParamGroupingTests {
    private func project() throws -> ProjectView {
        guard case .snapshot(let snapshot) = try Fixture.decode(DaemonEvent.self, "recorded/event-snapshot.json") else {
            throw ApiError(code: .internal, message: "Expected snapshot")
        }
        return snapshot.projects[0]
    }

    @Test func referencesDetermineGroupsWithoutDuplicatingSharedOptions() throws {
        let project = try project()
        func param(_ key: String, _ label: String, _ ids: [String]) -> ParamConfig {
            ParamConfig(key: key, label: label, type: .string, value: .string("value"),
                        usedBy: ids.map { ParamReference(serviceId: $0, where: .env, envKey: "VALUE") })
        }
        let params = [
            param("front", "前端页面端口", ["frontend"]),
            param("back", "后端数据库环境", ["backend", "backend"]),
            param("both", "后端接口地址", ["backend", "frontend"]),
            param("global", "全局环境", ["*"]),
            param("unused", "前端未引用", []),
            param("unknown", "未知服务", ["removed"]),
        ]
        let groups = ParamChips.groups(params, project: project)
        #expect(groups.map(\.title) == ["后端", "前端", "共用", "未引用"])
        #expect(groups.map { $0.chips.map(\.key) } == [["back"], ["front"], ["both", "global", "unknown"], ["unused"]])
        #expect(groups.flatMap(\.chips).map(\.label) == ["数据库环境", "页面端口", "后端接口地址", "全局环境", "未知服务", "前端未引用"])
        #expect(groups[0].chips[0].help.contains("后端数据库环境：value"))
        #expect(params[1].label == "后端数据库环境")
    }

    @Test func shorteningPreservesMeaningAndSecretMasking() throws {
        var project = try project()
        project.services[0].name = "API"
        let params = ["API", "APIKey", "API port", "访问 API", "API：令牌"].enumerated().map { index, label in
            ParamConfig(key: "p\(index)", label: label, type: .string, value: .string("hidden"), secret: true,
                        usedBy: [ParamReference(serviceId: "backend", where: .command)])
        }
        let chips = ParamChips.groups(params, project: project).flatMap(\.chips)
        #expect(chips.map(\.label) == ["API", "APIKey", "port", "访问 API", "令牌"])
        #expect(chips.allSatisfy { $0.value == "••••" && !$0.help.contains("hidden") })
    }
}
