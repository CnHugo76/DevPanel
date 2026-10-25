import Foundation
import Testing

@testable import DevPanelKit

// MARK: - Fixtures

/// Fixtures/recorded: captured from tools/mock-daemon (v1.1) with curl; paths sanitized.
/// Fixtures/handwritten: written by hand from packages/contract (cases the mock cannot produce
/// on demand: unknown enum values, stop timeouts, listening null/[]/other, truncated/gap, …).
enum Fixture {
    static func url(_ name: String) throws -> URL {
        let parts = name.split(separator: "/", maxSplits: 1).map(String.init)
        let base = try #require(Bundle.module.resourceURL).appendingPathComponent("Fixtures")
        return base.appendingPathComponent(parts[0]).appendingPathComponent(parts[1])
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }

    static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try ContractCoding.decoder().decode(T.self, from: data(name))
    }

    static func names(in folder: String) throws -> [String] {
        let dir = try #require(Bundle.module.resourceURL)
            .appendingPathComponent("Fixtures").appendingPathComponent(folder)
        return try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }
}

func json(_ value: some Encodable) throws -> [String: Any] {
    let data = try ContractCoding.encoder().encode(value)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// Splits data into pseudo-random chunks (deterministic per seed) to exercise reassembly.
func chunked(_ data: Data, seed: UInt64, maxChunk: Int = 37) -> [Data] {
    var rng = SplitMix64(seed: seed)
    var chunks: [Data] = []
    var i = data.startIndex
    while i < data.endIndex {
        let n = Int(rng.next() % UInt64(maxChunk)) + 1
        let j = data.index(i, offsetBy: n, limitedBy: data.endIndex) ?? data.endIndex
        chunks.append(data[i..<j])
        i = j
    }
    return chunks
}

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Locked box

final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    var current: Value { withLock { $0 } }
}

// MARK: - Fake transport

/// A controllable SSE stream handed to the client for one streaming request.
final class FakeStream: Sendable {
    let status: Int
    let chunks: AsyncThrowingStream<Data, any Error>
    let continuation: AsyncThrowingStream<Data, any Error>.Continuation

    init(status: Int = 200) {
        self.status = status
        (chunks, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
    }

    func send(_ text: String) { continuation.yield(Data(text.utf8)) }
    func send(_ data: Data) { continuation.yield(data) }

    /// Sends one SSE event for a JSON fixture (its `type` field is used as the event name).
    func sendEvent(fixture name: String) throws {
        let data = try Fixture.data(name)
        let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let type = try #require(obj["type"] as? String)
        let compact = try JSONSerialization.data(withJSONObject: obj)
        send("event: \(type)\ndata: \(String(decoding: compact, as: UTF8.self))\n\n")
    }

    func finish(throwing error: (any Error)? = nil) { continuation.finish(throwing: error) }
}

/// Routes requests to closures; records every request.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Data)
    typealias StreamHandler = @Sendable (URLRequest) throws -> FakeStream

    let requests = Locked<[URLRequest]>([])
    private let handler: Locked<Handler>
    private let streamHandler: Locked<StreamHandler>

    init(
        handler: @escaping Handler = { _ in (404, Data(#"{"error":{"code":"INTERNAL","message":"no route"}}"#.utf8)) },
        stream: @escaping StreamHandler = { _ in throw URLError(.cannotConnectToHost) }
    ) {
        self.handler = Locked(handler)
        self.streamHandler = Locked(stream)
    }

    func setHandler(_ h: @escaping Handler) { handler.withLock { $0 = h } }
    func setStream(_ h: @escaping StreamHandler) { streamHandler.withLock { $0 = h } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.withLock { $0.append(request) }
        let (status, body) = try handler.current(request)
        return (body, Self.response(request, status))
    }

    func stream(_ request: URLRequest, receive: (StreamPart) async throws -> Void) async throws {
        requests.withLock { $0.append(request) }
        let stream = try streamHandler.current(request)
        try await receive(.response(Self.response(request, stream.status)))
        for try await chunk in stream.chunks {
            try await receive(.data(chunk))
        }
    }

    static func response(_ request: URLRequest, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }
}

let testDiscovery = DaemonDiscovery(
    pid: 1, version: "test", socketPath: "/tmp/x.sock", httpPort: 47999, token: "tok", startedAt: "2026-10-20T00:00:00.000Z")

func testClient(_ transport: FakeTransport) -> DaemonClient {
    DaemonClient(discovery: testDiscovery, transport: transport)
}

/// Polls a main-actor condition (the model runs on the main actor).
@MainActor
func eventually(
    timeout: Duration = .seconds(3), _ condition: @MainActor () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        if clock.now >= deadline {
            Issue.record("condition not met within \(timeout)", sourceLocation: sourceLocation)
            return
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
}
