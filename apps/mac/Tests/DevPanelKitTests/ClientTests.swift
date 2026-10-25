import Foundation
import Testing

@testable import DevPanelKit

@Suite("DaemonClient")
struct ClientTests {
    private func ok(_ fixture: String, status: Int = 200) -> FakeTransport.Handler {
        let data = (try? Fixture.data(fixture)) ?? Data()
        return { _ in (status, data) }
    }

    @Test("GET: bearer token, JSON accept, no client header, 127.0.0.1 base URL")
    func getHeaders() async throws {
        let t = FakeTransport(handler: ok("recorded/daemon-info.json"))
        let info = try await testClient(t).daemonInfo()
        #expect(info.apiVersion == 1)
        let r = try #require(t.requests.current.first)
        #expect(r.httpMethod == "GET")
        #expect(r.url?.absoluteString == "http://127.0.0.1:47999/api/v1/daemon")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(r.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(r.value(forHTTPHeaderField: "X-DevPanel-Client") == nil)
        #expect(r.httpBody == nil)
    }

    @Test("every non-GET carries X-DevPanel-Client: ui")
    func mutatingHeaders() async throws {
        let t = FakeTransport { r in
            switch (r.httpMethod, r.url?.path) {
            case ("POST", "/api/v1/operations"): (202, try Fixture.data("recorded/operation-created.json"))
            case ("DELETE", "/api/v1/projects/p_x"): (204, Data())
            case ("DELETE", _), ("PATCH", _), ("POST", _), ("PUT", _): (200, try Fixture.data("recorded/param-patch.json"))
            default: (404, Data())
            }
        }
        let c = testClient(t)
        let config = ProjectConfig(name: "n", root: "/r", services: [ServiceConfig(id: "a", name: "A", cwd: ".", command: ["x"])])
        _ = try await c.createOperation(ActionRequest(projectId: "p_x", action: .start))
        _ = try await c.update("p_x", UpdateRequest(ifRevision: 1, config: config))
        _ = try await c.patchParam("p_x", key: "port", PatchParamRequest(ifRevision: 2, value: .number(1)))
        _ = try await c.addParam("p_x", AddParamRequest(ifRevision: 2, param: ParamConfig(key: "k", label: "K", type: .string, value: .string("v"))))
        _ = try await c.deleteParam("p_x", key: "port", ifRevision: 3, inline: true)
        try await c.deleteProject("p_x")
        let requests = t.requests.current
        #expect(requests.count == 6)
        for r in requests {
            #expect(r.value(forHTTPHeaderField: "X-DevPanel-Client") == "ui", "\(r.httpMethod ?? "") \(r.url?.path ?? "")")
            #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        }
        #expect(requests[0].value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(requests.map { $0.httpMethod ?? "" } == ["POST", "PUT", "PATCH", "POST", "DELETE", "DELETE"])
        #expect(requests[2].url?.path == "/api/v1/projects/p_x/params/port")
        let del = try #require(URLComponents(url: requests[4].url!, resolvingAgainstBaseURL: false))
        #expect(del.path == "/api/v1/projects/p_x/params/port")
        #expect(del.queryItems == [URLQueryItem(name: "ifRevision", value: "3"), URLQueryItem(name: "inline", value: "true")])
        #expect(requests[4].httpBody == nil)
    }

    @Test("routes and query strings")
    func routes() async throws {
        let t = FakeTransport { r in
            let path = r.url!.path
            if path.hasSuffix("/wait") { return (200, try Fixture.data("recorded/operation-finished.json")) }
            if path.hasSuffix("/logs") { return (200, try Fixture.data("recorded/logs-page.json")) }
            if path.hasSuffix("/runs") { return (200, try Fixture.data("recorded/runs.json")) }
            if path.hasSuffix("/stats") { return (200, try Fixture.data("recorded/project-stats.json")) }
            if path.hasSuffix("/view") { return (200, try Fixture.data("recorded/project-view.json")) }
            if path.hasPrefix("/api/v1/runs/") { return (200, try Fixture.data("recorded/run-detail.json")) }
            if path == "/api/v1/projects" { return (200, try Fixture.data("recorded/projects.json")) }
            if path == "/api/v1/config/validate" { return (200, try Fixture.data("recorded/validate-ok.json")) }
            if path.hasPrefix("/api/v1/operations/") { return (200, try Fixture.data("recorded/operation-created.json")) }
            return (200, try Fixture.data("recorded/project-order-service.json"))
        }
        let c = testClient(t)
        _ = try await c.projects()
        _ = try await c.project("p_a")
        _ = try await c.projectView("p_a")
        _ = try await c.projectStats("p_a")
        _ = try await c.runs("p_a", serviceId: "backend")
        _ = try await c.run("r_1")
        _ = try await c.logs("r_1", before: 100, limit: 50)
        _ = try await c.operation("op_1")
        _ = try await c.waitOperation("op_1", timeoutMs: 120_000)
        _ = try await c.validate(ProjectConfig(name: "n", root: "/r", services: []))
        let urls = t.requests.current.map { $0.url!.absoluteString.replacingOccurrences(of: "http://127.0.0.1:47999/api/v1", with: "") }
        #expect(urls == [
            "/projects", "/projects/p_a", "/projects/p_a/view", "/projects/p_a/stats",
            "/projects/p_a/services/backend/runs", "/runs/r_1", "/runs/r_1/logs?before=100&limit=50",
            "/operations/op_1", "/operations/op_1/wait?timeoutMs=60000", "/config/validate",
        ])
        // The long poll gets a longer timeout than its wait.
        #expect(t.requests.current[8].timeoutInterval > 60)
    }

    @Test("shutdown: 202 {} → nil, 202 Operation → operation")
    func shutdown() async throws {
        let empty = FakeTransport(handler: ok("handwritten/shutdown-empty.json", status: 202))
        #expect(try await testClient(empty).shutdown(stopServices: false) == nil)
        let body = try #require(empty.requests.current.first?.httpBody)
        #expect(String(decoding: body, as: UTF8.self) == #"{"stopServices":false}"#)
        let op = FakeTransport(handler: ok("recorded/operation-stop-finished.json", status: 202))
        #expect(try await testClient(op).shutdown(stopServices: true)?.action == .stop)
    }

    @Test("errors: ErrorBody passthrough, 401 → UNAUTHORIZED, non-JSON → INTERNAL")
    func errorMapping() async throws {
        let mismatch = FakeTransport(handler: ok("recorded/error-revision-mismatch.json", status: 409))
        await #expect {
            _ = try await testClient(mismatch).project("p_x")
        } throws: { e in
            (e as? ApiError)?.code == .revisionMismatch && (e as? ApiError)?.currentRevision != nil
        }
        let unauth = FakeTransport(handler: ok("recorded/error-unauthorized.json", status: 401))
        await #expect { _ = try await testClient(unauth).projects() } throws: { ($0 as? ApiError)?.code == .unauthorized }
        let bare401 = FakeTransport(handler: { _ in (401, Data("nope".utf8)) })
        await #expect { _ = try await testClient(bare401).projects() } throws: { ($0 as? ApiError)?.code == .unauthorized }
        let html500 = FakeTransport(handler: { _ in (500, Data("<html>".utf8)) })
        await #expect { _ = try await testClient(html500).projects() } throws: { e in
            (e as? ApiError)?.code == .internal && (e as? ApiError)?.details?["status"]?.intValue == 500
        }
        let unknown = FakeTransport(handler: ok("handwritten/error-unknown-code.json", status: 418))
        await #expect { _ = try await testClient(unknown).projects() } throws: {
            ($0 as? ApiError)?.code == .other("SOMETHING_NEW_FROM_A_FUTURE_DAEMON")
        }
    }

    @Test("connection failures → DAEMON_UNREACHABLE; refused is detectable")
    func unreachable() async throws {
        let refused = FakeTransport(handler: { _ in throw URLError(.cannotConnectToHost) })
        await #expect { _ = try await testClient(refused).projects() } throws: { e in
            guard let api = e as? ApiError else { return false }
            return api.code == .daemonUnreachable && api.isConnectionRefused
        }
        let lost = FakeTransport(handler: { _ in throw URLError(.networkConnectionLost) })
        await #expect { _ = try await testClient(lost).projects() } throws: { e in
            (e as? ApiError)?.code == .daemonUnreachable && (e as? ApiError)?.isConnectionRefused == false
        }
        let cancelled = FakeTransport(handler: { _ in throw URLError(.cancelled) })
        await #expect(throws: CancellationError.self) { _ = try await testClient(cancelled).projects() }
    }

    @Test("undecodable 2xx → INTERNAL")
    func decodeFailure() async throws {
        let t = FakeTransport(handler: { _ in (200, Data(#"{"version":1}"#.utf8)) })
        await #expect { _ = try await testClient(t).daemonInfo() } throws: { e in
            (e as? ApiError)?.code == .internal && (e as? ApiError)?.message.contains("version") == true
        }
    }

    @Test("events(): recorded stream in random chunks decodes every event")
    func eventsStream() async throws {
        let data = try Fixture.data("recorded/events.sse")
        let t = FakeTransport(stream: { r in
            #expect(r.url?.path == "/api/v1/events")
            #expect(r.value(forHTTPHeaderField: "Accept") == "text/event-stream")
            #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
            let s = FakeStream()
            for c in chunked(data, seed: 9) { s.send(c) }
            s.finish()
            return s
        })
        var types: [String] = []
        for try await e in testClient(t).events() { types.append(e.type) }
        #expect(types.first == "snapshot")
        #expect(types.count == 30)
        #expect(Set(types) == ["snapshot", "project.upsert", "project.remove", "operation", "stats", "ping"])
    }

    @Test("events(): 401 surfaces as UNAUTHORIZED")
    func eventsUnauthorized() async throws {
        let t = FakeTransport(stream: { _ in
            let s = FakeStream(status: 401)
            s.send(try Fixture.data("recorded/error-unauthorized.json"))
            s.finish()
            return s
        })
        await #expect {
            for try await _ in testClient(t).events() {}
        } throws: { ($0 as? ApiError)?.code == .unauthorized }
    }

    @Test("logStream(): afterSeq query and end event")
    func logStream() async throws {
        let data = try Fixture.data("recorded/logstream.sse")
        let t = FakeTransport(stream: { r in
            #expect(r.url?.query == "afterSeq=0")
            #expect(r.url?.path.hasSuffix("/logs/stream") == true)
            let s = FakeStream()
            for c in chunked(data, seed: 4, maxChunk: 11) { s.send(c) }
            s.finish()
            return s
        })
        var last: LogStreamEvent?
        for try await e in testClient(t).logStream("r_1", afterSeq: 0) { last = e }
        guard case .end = last else { Issue.record("expected end, got \(String(describing: last))"); return }
    }

    #if DEBUG // The parse probe is compiled out of release builds.
    @Test("500 log lines decode without parsing timestamps", arguments: [false, true])
    func logBatchDoesNotParseTimestamps(streaming: Bool) async throws {
        // Different, valid timestamps for each route keep the cache cold in parallel tests.
        let year = streaming ? 2037 : 2038
        let lines: [[String: Any]] = (0..<500).map { index in
            ["seq": index + 1, "ts": String(format: "%d-04-05T06:07:08.%03dZ", year, index),
             "stream": "out", "text": "line \(index)"]
        }
        let payload = try JSONSerialization.data(withJSONObject: streaming
            ? ["type": "lines", "runId": "r_batch", "lines": lines]
            : ["runId": "r_batch", "lines": lines, "hasMoreBefore": false,
               "hasMoreAfter": false, "runEnded": false, "truncated": false])
        let transport = FakeTransport(handler: { _ in (200, payload) }, stream: { _ in
            let stream = FakeStream()
            stream.send("event: lines\ndata: \(String(decoding: payload, as: UTF8.self))\n\n")
            stream.finish()
            return stream
        })
        let parsed = Locked<[Timestamp]>([])
        try await Timestamps.$didParse.withValue({ timestamp in parsed.withLock { $0.append(timestamp) } }) {
            let decoded: [LogLine]
            if streaming {
                var batches: [[LogLine]] = []
                for try await event in testClient(transport).logStream("r_batch") {
                    if case .lines(_, let lines) = event { batches.append(lines) }
                }
                #expect(batches.count == 1)
                decoded = try #require(batches.first)
            } else {
                decoded = try await testClient(transport).logs("r_batch", limit: 500).lines
            }
            #expect(decoded.count == 500)
            try #require(parsed.current.count == 0)
            // Prove the probe sees a real cache miss and subsequent uses hit the cache.
            let timestamp = try #require(decoded.first?.ts)
            #expect(Timestamps.date(timestamp) != nil)
            #expect(Timestamps.date(timestamp) != nil)
            #expect(parsed.current == [timestamp])
        }
    }
    #endif

    @Test("a malformed known event fails the stream with INTERNAL")
    func malformedStream() async throws {
        let t = FakeTransport(stream: { _ in
            let s = FakeStream()
            s.send("event: stats\ndata: {\"type\":\"stats\"}\n\n")
            return s
        })
        await #expect {
            for try await _ in testClient(t).events() {}
        } throws: { ($0 as? ApiError)?.code == .internal }
    }
}
