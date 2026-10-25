import Foundation
import Testing
@testable import DevPanelKit

struct LogDigestTests {
    @Test func sharedGolden() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("test-fixtures/digest")
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
            let digest = try JSONDecoder().decode(LogDigest.self, from: Data(contentsOf: file))
            let expected = try String(contentsOf: file.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)
            #expect(digest.text + "\n" == expected)
        }
    }
}

extension LogDigestTests {
    @Test func unknownDigestAndReadyKindsRoundTrip() throws {
        let decoder = JSONDecoder()
        let kind = try decoder.decode(LogDigestBlockKind.self, from: Data(#""future-block""#.utf8))
        #expect(kind == .other("future-block"))
        #expect(try decoder.decode(LogDigestBlockKind.self, from: JSONEncoder().encode(kind)) == kind)
        let check = try decoder.decode(ReadyCheck.self, from: Data(#"{"kind":"future-check"}"#.utf8))
        #expect(check.kind == .other("future-check"))
        let evidence = try decoder.decode(ReadyInfo.Evidence.self, from: Data(#"{"kind":"future-evidence"}"#.utf8))
        #expect(evidence.kind == .other("future-evidence"))
        let activity = try decoder.decode(ActivityKind.self, from: Data(#""future-activity""#.utf8))
        #expect(activity == .other("future-activity"))
    }
}
