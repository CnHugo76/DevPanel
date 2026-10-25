import Foundation

/// A piece of a streamed HTTP response.
public enum StreamPart: Sendable {
    case response(HTTPURLResponse)
    case data(Data)
}

/// The network seam of `DaemonClient`. Production uses `URLSessionTransport`; tests inject fakes.
public protocol HTTPTransport: Sendable {
    /// Plain request/response.
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)

    /// Streaming request: delivers `.response` once, then `.data` chunks until the server closes
    /// (returns) or an error / cancellation occurs (throws). Chunks may split lines or UTF-8
    /// sequences anywhere.
    func stream(_ request: URLRequest, receive: (StreamPart) async throws -> Void) async throws
}

/// `URLSession`-backed transport: no proxies, no cache, no cookies (auth is the bearer token).
public final class URLSessionTransport: HTTPTransport {
    public let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]  // never route 127.0.0.1 through a proxy
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        // /events + several log streams + requests must not starve each other (default is 6).
        config.httpMaximumConnectionsPerHost = 16
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    public init(session: URLSession) { self.session = session }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    public func stream(_ request: URLRequest, receive: (StreamPart) async throws -> Void) async throws {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        try await receive(.response(http))
        var buffer = Data()
        buffer.reserveCapacity(8192)
        // Flush at every LF so SSE events are delivered as soon as their blank line arrives.
        for try await byte in bytes {
            buffer.append(byte)
            if byte == 0x0A || buffer.count >= 64 * 1024 {
                try await receive(.data(buffer))
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty { try await receive(.data(buffer)) }
    }
}
