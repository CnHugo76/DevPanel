import Foundation
import Testing

@testable import DevPanelKit

@Suite("Memory accounting")
struct MemoryTests {
    @Test("footprint survives stats decoding, service projection, and encoding")
    func footprintRoundTrip() throws {
        let data = Data(#"""
            {"sampledAt":"2026-10-21T00:00:00Z","intervalMs":2000,"projects":{"p":{
              "total":{"status":"ok","rssBytes":1048576,"footprintBytes":2147483648,"processCount":2},
              "services":{"s":{"runId":"r","status":"ok","rssBytes":1048576,
                "footprintBytes":2147483648,"processCount":2}}
            }}}
            """#.utf8)
        let snapshot = try ContractCoding.decoder().decode(StatsSnapshot.self, from: data)
        let project = try #require(snapshot.projects["p"])
        let service = try #require(project.services["s"])
        #expect(project.total.footprintBytes == 2_147_483_648)
        #expect(service.footprintBytes == project.total.footprintBytes)
        #expect(service.sample.footprintBytes == project.total.footprintBytes)
        #expect(service.sample.rssBytes == 1_048_576)
        let encoded = try JSONEncoder().encode(snapshot)
        #expect(try ContractCoding.decoder().decode(StatsSnapshot.self, from: encoded) == snapshot)
    }

    @Test("older daemons and null footprint decode without inventing zero")
    func optionalFootprint() throws {
        let old = try Fixture.decode(ProjectStats.self, "recorded/v1.0-project-stats-no-listening.json")
        #expect(old.total.footprintBytes == nil)
        #expect(old.services.values.allSatisfy { $0.footprintBytes == nil && $0.sample.footprintBytes == nil })
        let data = Data(#"{"runId":"r","status":"partial","rssBytes":1048576,"footprintBytes":null}"#.utf8)
        let service = try ContractCoding.decoder().decode(ServiceStats.self, from: data)
        #expect(service.sample.footprintBytes == nil)
        #expect(Metrics.memory(service.sample, active: true).text == "1 MiB RSS")
    }

    @Test("memory prefers footprint and keeps RSS as auxiliary information")
    func footprintPreference() {
        let sample = ResourceSample(status: .ok, rssBytes: 1_048_576, footprintBytes: 2_147_483_648)
        let memory = Metrics.memory(sample, active: true)
        #expect(memory.text == "2.00 GiB")
        #expect(memory.kind == .value)
        #expect(memory.help?.contains("footprint") == true)
        #expect(memory.help?.contains("压缩及换出") == true)
        #expect(memory.help?.contains("RSS：1 MiB") == true)
        #expect(Metrics.memory(sample, active: false) == .notRunning)
    }

    @Test("missing footprint explicitly falls back to RSS including partial samples")
    func rssFallback() {
        let sample = ResourceSample(status: .partial, rssBytes: 1_048_576, note: "一个进程无法读取")
        let memory = Metrics.memory(sample, active: true)
        #expect(memory.text == "1 MiB RSS")
        #expect(memory.partial)
        #expect(memory.help?.contains("footprint 暂不可用") == true)
        #expect(memory.help?.contains("一个进程无法读取") == true)
    }

    @Test("first CPU sample can already show memory; unknown memory stays unknown")
    func samplingAndUnknown() {
        #expect(Metrics.memory(ResourceSample(status: .sampling, footprintBytes: 1_048_576), active: true).text == "1 MiB")
        #expect(Metrics.memory(ResourceSample(status: .sampling), active: true).text == "采样中")
        #expect(Metrics.memory(ResourceSample(status: .partial), active: true).text == "不可用")
        // An unavailable sample must never display stale numeric fields.
        #expect(Metrics.memory(ResourceSample(status: .unavailable, rssBytes: 1, footprintBytes: 1), active: true).text == "不可用")
        #expect(Metrics.memory(ResourceSample(status: .ok, footprintBytes: 0), active: true).text == "0 B")
    }
}
