import Foundation

/// One dispatched Server-Sent Event.
public struct SSEMessage: Hashable, Sendable {
    /// `event:` field; "message" when absent.
    public var event: String
    /// `data:` lines joined with "\n".
    public var data: String
    public var id: String?

    public init(event: String = "message", data: String, id: String? = nil) {
        self.event = event
        self.data = data
        self.id = id
    }
}

/// Incremental SSE parser (WHATWG "event stream interpretation"), fed raw bytes in any chunking.
///
/// - Lines end with LF, CRLF or CR; a CR at the end of one chunk followed by LF at the start
///   of the next counts as a single line break.
/// - Lines are decoded as UTF-8 only once complete, so multi-byte characters split across
///   chunks are handled.
/// - `:` lines are comments; an empty line dispatches the pending event (if it has data).
/// - Multiple `data:` lines are joined with "\n".
public struct SSEParser: Sendable {
    private var lineBuffer: [UInt8] = []
    private var lastWasCR = false
    private var eventType = ""
    private var dataLines: [String] = []
    private var hasData = false
    private var lastEventId: String?
    private var atStart = true

    public init() {}

    /// Feed a chunk; returns the events completed by it.
    public mutating func feed<Bytes: Sequence>(_ bytes: Bytes) -> [SSEMessage] where Bytes.Element == UInt8 {
        var out: [SSEMessage] = []
        for byte in bytes {
            switch byte {
            case 0x0A:  // LF
                if lastWasCR {
                    lastWasCR = false  // second half of CRLF
                    continue
                }
                if let m = endLine() { out.append(m) }
            case 0x0D:  // CR
                lastWasCR = true
                if let m = endLine() { out.append(m) }
            default:
                lastWasCR = false
                lineBuffer.append(byte)
            }
        }
        return out
    }

    public mutating func feed(_ string: String) -> [SSEMessage] {
        feed(Array(string.utf8))
    }

    /// End of stream. Per spec an incomplete event (no trailing blank line) is discarded.
    public mutating func finish() {
        lineBuffer.removeAll()
        resetEvent()
    }

    private mutating func endLine() -> SSEMessage? {
        var bytes = lineBuffer
        lineBuffer.removeAll(keepingCapacity: true)
        // Strip a UTF-8 BOM at the very start of the stream.
        if atStart {
            atStart = false
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        }
        if bytes.isEmpty { return dispatch() }
        let line = String(decoding: bytes, as: UTF8.self)
        if line.hasPrefix(":") { return nil }  // comment

        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }

        switch field {
        case "event": eventType = String(value)
        case "data":
            dataLines.append(String(value))
            hasData = true
        case "id":
            if !value.contains("\0") { lastEventId = String(value) }
        default: break  // "retry" and unknown fields are ignored
        }
        return nil
    }

    private mutating func dispatch() -> SSEMessage? {
        defer { resetEvent() }
        guard hasData else { return nil }
        return SSEMessage(
            event: eventType.isEmpty ? "message" : eventType,
            data: dataLines.joined(separator: "\n"),
            id: lastEventId)
    }

    private mutating func resetEvent() {
        eventType = ""
        dataLines.removeAll()
        hasData = false
    }
}
