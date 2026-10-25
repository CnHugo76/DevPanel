import Foundation
import Testing

@testable import DevPanelKit

@Suite("SSE parser")
struct SSEParserTests {
    @Test func singleEvent() {
        var p = SSEParser()
        let out = p.feed("event: ping\ndata: {\"type\":\"ping\"}\n\n")
        #expect(out == [SSEMessage(event: "ping", data: #"{"type":"ping"}"#)])
    }

    @Test("no dispatch until the blank line")
    func waitsForBlankLine() {
        var p = SSEParser()
        #expect(p.feed("event: a\ndata: 1\n").isEmpty)
        #expect(p.feed("\n") == [SSEMessage(event: "a", data: "1")])
    }

    @Test("multi-line data is joined with LF")
    func multiLineData() {
        var p = SSEParser()
        let out = p.feed("data: line1\ndata: line2\ndata:\ndata:  indented\n\n")
        #expect(out == [SSEMessage(event: "message", data: "line1\nline2\n\n indented")])
    }

    @Test("comment lines and unknown fields are ignored")
    func comments() {
        var p = SSEParser()
        let out = p.feed(": hello\n:\nretry: 1000\nfoo: bar\nevent: x\n: mid-event comment\ndata: y\n\n")
        #expect(out == [SSEMessage(event: "x", data: "y")])
    }

    @Test("blank lines without data dispatch nothing; event type resets")
    func blankLines() {
        var p = SSEParser()
        #expect(p.feed("\n\n\nevent: lonely\n\n").isEmpty)
        // The previous event name must not leak into the next event.
        #expect(p.feed("data: z\n\n") == [SSEMessage(event: "message", data: "z")])
    }

    @Test("field without colon, no space after colon, id")
    func fieldForms() {
        var p = SSEParser()
        let out = p.feed("data\nevent:tight\nid: 42\n\n")
        #expect(out == [SSEMessage(event: "tight", data: "", id: "42")])
    }

    @Test("CRLF and bare CR line endings, including CR/LF split across chunks")
    func lineEndings() {
        var p = SSEParser()
        var out = p.feed("event: a\r\ndata: 1\r")
        out += p.feed("\n\r\n")
        out += p.feed("data: 2\r\r")
        #expect(out == [SSEMessage(event: "a", data: "1"), SSEMessage(event: "message", data: "2")])
    }

    @Test("multi-byte UTF-8 split across chunks")
    func utf8Split() {
        let bytes = Array("data: 中文🙂\n\n".utf8)
        for cut in 1..<bytes.count {
            var p = SSEParser()
            var out = p.feed(bytes[..<cut])
            out += p.feed(bytes[cut...])
            #expect(out == [SSEMessage(data: "中文🙂")], "cut at \(cut)")
        }
    }

    @Test("byte-by-byte delivery")
    func byteByByte() {
        var p = SSEParser()
        var out: [SSEMessage] = []
        for b in "event: e\ndata: a\ndata: b\n\n: c\n\nevent: f\ndata: g\n\n".utf8 {
            out += p.feed([b])
        }
        #expect(out == [SSEMessage(event: "e", data: "a\nb"), SSEMessage(event: "f", data: "g")])
    }

    @Test("incomplete trailing event is discarded at end of stream")
    func incompleteTail() {
        var p = SSEParser()
        #expect(p.feed("data: done\n\ndata: partial").count == 1)
        p.finish()
        #expect(p.feed("\n\n").isEmpty)
    }

    @Test("leading BOM is stripped")
    func bom() {
        var p = SSEParser()
        #expect(p.feed([0xEF, 0xBB, 0xBF] + Array("data: x\n\n".utf8)) == [SSEMessage(data: "x")])
    }

    @Test("recorded /events stream: any chunking yields the same events", arguments: [1, 2, 3, 7, 42])
    func recordedEventsChunked(seed: UInt64) throws {
        let data = try Fixture.data("recorded/events.sse")
        var whole = SSEParser()
        let expected = whole.feed(data)
        var p = SSEParser()
        var got: [SSEMessage] = []
        for chunk in chunked(data, seed: seed, maxChunk: Int(seed % 5 + 1) * 13) {
            got += p.feed(chunk)
        }
        #expect(got == expected)
        #expect(got.first?.event == "snapshot")
        let types = Set(got.map(\.event))
        #expect(types.isSuperset(of: ["snapshot", "project.upsert", "project.remove", "operation", "stats", "ping"]))
        // event name equals the JSON type for every event (contract §7)
        for m in got {
            let obj = try JSONSerialization.jsonObject(with: Data(m.data.utf8)) as? [String: Any]
            #expect(obj?["type"] as? String == m.event)
        }
    }

    @Test("handwritten stream with comments, retry, id and unknown type")
    func handwrittenUnknown() throws {
        var p = SSEParser()
        let out = p.feed(try Fixture.data("handwritten/events-unknown-type.sse"))
        #expect(out.map(\.event) == ["future.thing", "ping"])
        #expect(out.first?.id == "17")
        let events = try out.map { try ContractCoding.decoder().decode(DaemonEvent.self, from: Data($0.data.utf8)) }
        #expect(events.first == .unknown(type: "future.thing"))
    }
}
