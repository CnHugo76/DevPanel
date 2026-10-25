import Foundation

/// HTTP client for the daemon API (contract §2), over `127.0.0.1` with the bearer token.
///
/// Every method throws `ApiError` (daemon errors as returned, 401 → UNAUTHORIZED,
/// connection failures → DAEMON_UNREACHABLE, undecodable responses → INTERNAL), except that
/// task cancellation surfaces as `CancellationError`.
public struct DaemonClient: Sendable {
    public let endpoint: DaemonEndpoint
    public let transport: any HTTPTransport

    /// Default timeout for ordinary requests.
    public var requestTimeout: TimeInterval = 15

    public init(endpoint: DaemonEndpoint, transport: any HTTPTransport = URLSessionTransport()) {
        self.endpoint = endpoint
        self.transport = transport
    }

    public init(discovery: DaemonDiscovery, transport: any HTTPTransport = URLSessionTransport()) {
        self.init(endpoint: DaemonEndpoint(discovery: discovery), transport: transport)
    }

    // MARK: - Daemon

    public func daemonInfo() async throws -> DaemonInfo {
        try await get(["daemon"])
    }

    /// 202 `Operation | {}`: the stop operation when services had to be stopped, else nil.
    public func shutdown(stopServices: Bool) async throws -> Operation? {
        let data = try await sendRaw(.post, ["daemon", "shutdown"], body: ShutdownRequest(stopServices: stopServices), timeout: 660)
        if data.isEmpty { return nil }
        if let obj = try? ContractCoding.decoder().decode(JSONValue.self, from: data), obj["id"] == nil {
            return nil
        }
        return try decode(Operation.self, from: data)
    }

    // MARK: - Config & projects

    public func validate(_ config: ProjectConfig) async throws -> ValidateResult {
        try await send(.post, ["config", "validate"], body: config)
    }

    public func projects() async throws -> [ProjectView] {
        try await get(["projects"])
    }

    public func register(_ config: RegisterRequest) async throws -> RegisterResponse {
        try await send(.post, ["projects"], body: config)
    }

    public func project(_ id: ProjectID) async throws -> Project {
        try await get(["projects", id])
    }

    public func update(_ id: ProjectID, _ request: UpdateRequest) async throws -> UpdateResponse {
        try await send(.put, ["projects", id], body: request)
    }

    public func deleteProject(_ id: ProjectID) async throws {
        _ = try await sendRaw(.delete, ["projects", id], body: Optional<Never>.none)
    }

    public func projectView(_ id: ProjectID) async throws -> ProjectView {
        try await get(["projects", id, "view"])
    }

    public func projectStats(_ id: ProjectID) async throws -> ProjectStats {
        try await get(["projects", id, "stats"])
    }

    public func policy(_ id: ProjectID) async throws -> ProjectPolicy { try await get(["projects", id, "policy"]) }
    public func setPolicy(_ id: ProjectID, _ policy: ProjectPolicy) async throws -> ProjectPolicy {
        try await send(.put, ["projects", id, "policy"], body: policy)
    }
    public func releaseHold(_ id: ProjectID, serviceId: ServiceID) async throws {
        _ = try await sendRaw(.delete, ["projects", id, "services", serviceId, "hold"], body: Optional<Never>.none)
    }
    public func activity(_ id: ProjectID, before: String? = nil, task: String? = nil) async throws -> ActivityPage {
        var query = before.map { [URLQueryItem(name: "before", value: $0)] } ?? []
        if let task { query.append(URLQueryItem(name: "task", value: task)) }
        return try await get(["projects", id, "activity"], query: query)
    }

    // MARK: - Params (v1.1-A)

    public func addParam(_ projectId: ProjectID, _ request: AddParamRequest) async throws -> Project {
        try await send(.post, ["projects", projectId, "params"], body: request)
    }

    public func patchParam(_ projectId: ProjectID, key: String, _ request: PatchParamRequest) async throws -> Project {
        try await send(.patch, ["projects", projectId, "params", key], body: request)
    }

    /// `inline: true` writes the current value back into every reference before deleting.
    public func deleteParam(_ projectId: ProjectID, key: String, ifRevision: Int, inline: Bool) async throws -> Project {
        try await send(
            .delete, ["projects", projectId, "params", key],
            query: [URLQueryItem(name: "ifRevision", value: String(ifRevision)),
                    URLQueryItem(name: "inline", value: inline ? "true" : "false")],
            body: Optional<Never>.none)
    }

    private func repositoryQuery(_ id: String?) -> [URLQueryItem] { id.map { [URLQueryItem(name: "repositoryId", value: $0)] } ?? [] }
    public func gitStatus(_ id: ProjectID, repositoryId: String? = nil) async throws -> GitStatus {
        try await get(["projects", id, "git", "status"], query: repositoryQuery(repositoryId))
    }
    public func gitDiff(_ id: ProjectID, file: GitFileKey, context: String = "all", repositoryId: String? = nil) async throws -> GitDiff {
        try await get(["projects", id, "git", "diff"], query: repositoryQuery(repositoryId) + [URLQueryItem(name: "path", value: file.path), URLQueryItem(name: "staged", value: file.staged ? "true" : "false"), URLQueryItem(name: "context", value: context)])
    }
    public func gitStage(_ id: ProjectID, paths: [String], staged: Bool, repositoryId: String? = nil) async throws -> GitStatus {
        try await send(.post, ["projects", id, "git", staged ? "stage" : "unstage"], query: repositoryQuery(repositoryId), body: GitPathsRequest(paths: paths))
    }
    public func gitCommit(_ id: ProjectID, request: GitCommitRequest, repositoryId: String? = nil) async throws -> GitCommitResult {
        try await send(.post, ["projects", id, "git", "commit"], query: repositoryQuery(repositoryId), body: request, timeout: 130)
    }
    public func gitStashes(_ id: ProjectID, repositoryId: String? = nil) async throws -> [GitStash] {
        try await get(["projects", id, "git", "stashes"], query: repositoryQuery(repositoryId))
    }
    public func gitStash(_ id: ProjectID, message: String, includeUntracked: Bool, repositoryId: String? = nil) async throws -> GitStatus {
        try await send(.post, ["projects", id, "git", "stash"], query: repositoryQuery(repositoryId), body: GitStashRequest(message: message, includeUntracked: includeUntracked))
    }
    public func gitApplyStash(_ id: ProjectID, ref: String, drop: Bool, repositoryId: String? = nil) async throws -> GitStatus {
        try await send(.post, ["projects", id, "git", "stash", "apply"], query: repositoryQuery(repositoryId), body: GitStashApplyRequest(ref: ref, drop: drop))
    }
    public func maven(_ projectId: ProjectID, reload: Bool = false, mavenProjectId: String? = nil) async throws -> MavenModel {
        try await get(["projects", projectId, "maven"], query: (reload ? [URLQueryItem(name: "reload", value: "1")] : []) + (mavenProjectId.map { [URLQueryItem(name: "mavenProjectId", value: $0)] } ?? []))
    }
    public func mavenRuns(_ projectId: ProjectID) async throws -> [TaskRunSummary] {
        try await get(["projects", projectId, "maven", "runs"])
    }
    public func startMaven(_ projectId: ProjectID, request: MavenRunRequest) async throws -> StartTaskRunResponse {
        try await send(.post, ["projects", projectId, "maven", "runs"], body: request)
    }
    public func actionRuns(_ projectId: ProjectID, actionId: String) async throws -> [TaskRunSummary] {
        try await get(["projects", projectId, "actions", actionId, "runs"])
    }
    public func startAction(_ projectId: ProjectID, actionId: String) async throws -> StartTaskRunResponse {
        try await send(.post, ["projects", projectId, "actions", actionId, "runs"], body: Optional<Never>.none)
    }
    public func cancelTask(_ runId: RunID, force: Bool = false) async throws -> TaskRunSummary {
        try await send(.post, ["task-runs", runId, "cancel"], body: CancelTaskRunRequest(force: force))
    }
    public func taskRun(_ runId: RunID) async throws -> TaskRunDetail {
        try await get(["task-runs", runId])
    }

    // MARK: - Runs & logs

    /// Newest first, at most `runsKeptPerService`.
    public func runs(_ projectId: ProjectID, serviceId: ServiceID) async throws -> [RunSummary] {
        try await get(["projects", projectId, "services", serviceId, "runs"])
    }

    public func run(_ runId: RunID) async throws -> RunDetail {
        try await get(["runs", runId])
    }

    /// No cursor: newest `limit` lines. `before`: lines with seq < before. `after`: seq > after.
    public func digest(_ runId: RunID) async throws -> LogDigest {
        try await get(["runs", runId, "digest"])
    }

    public func searchLogs(_ runId: RunID, query: String, caseSensitive: Bool = false,
                           after: Int = 0, through: Int? = nil, limit: Int = 50, context: Int = 2) async throws -> LogSearchPage {
        var items = [URLQueryItem(name: "q", value: query),
                     URLQueryItem(name: "caseSensitive", value: String(caseSensitive)),
                     URLQueryItem(name: "after", value: String(after)),
                     URLQueryItem(name: "limit", value: String(limit)),
                     URLQueryItem(name: "context", value: String(context))]
        if let through { items.append(URLQueryItem(name: "through", value: String(through))) }
        return try await get(["runs", runId, "logs", "search"], query: items)
    }

    public func logs(_ runId: RunID, before: Int? = nil, after: Int? = nil, limit: Int? = nil) async throws -> LogPage {
        var query: [URLQueryItem] = []
        if let before { query.append(URLQueryItem(name: "before", value: String(before))) }
        if let after { query.append(URLQueryItem(name: "after", value: String(after))) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        return try await get(["runs", runId, "logs"], query: query)
    }

    /// SSE `LogStreamEvent`s; finishes after `end` (the daemon closes the stream).
    public func logStream(_ runId: RunID, afterSeq: Int? = nil) -> AsyncThrowingStream<LogStreamEvent, any Error> {
        var query: [URLQueryItem] = []
        if let afterSeq { query.append(URLQueryItem(name: "afterSeq", value: String(afterSeq))) }
        return sse(["runs", runId, "logs", "stream"], query: query, as: LogStreamEvent.self)
    }

    // MARK: - Operations

    public func createOperation(_ request: ActionRequest) async throws -> Operation {
        try await send(.post, ["operations"], body: request)
    }

    public func operation(_ id: OperationID) async throws -> Operation {
        try await get(["operations", id])
    }

    /// Long poll (≤ 60 s): returns when the operation finishes or the timeout elapses.
    public func waitOperation(_ id: OperationID, timeoutMs: Int = 30_000) async throws -> Operation {
        let ms = min(max(timeoutMs, 0), 60_000)
        return try await send(
            .get, ["operations", id, "wait"],
            query: [URLQueryItem(name: "timeoutMs", value: String(ms))],
            body: Optional<Never>.none,
            timeout: TimeInterval(ms) / 1000 + 10)
    }

    // MARK: - Global events

    /// SSE `DaemonEvent`s. The first event is a `snapshot`. The stream finishes when the server
    /// closes it and throws `ApiError` on failure.
    public func events() -> AsyncThrowingStream<DaemonEvent, any Error> {
        sse(["events"], query: [], as: DaemonEvent.self)
    }

    // MARK: - Plumbing

    public enum Method: String, Sendable {
        case get = "GET", post = "POST", put = "PUT", patch = "PATCH", delete = "DELETE"
    }

    /// Builds a request with auth and, for non-GET, the `X-DevPanel-Client: ui` header.
    public func makeRequest(
        _ method: Method, _ path: [String], query: [URLQueryItem] = [], body: Data? = nil,
        accept: String = "application/json", timeout: TimeInterval? = nil
    ) -> URLRequest {
        var url = endpoint.baseURL
        for component in path { url.appendPathComponent(component, isDirectory: false) }
        if !query.isEmpty, var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            comps.queryItems = query
            url = comps.url ?? url
        }
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.timeoutInterval = timeout ?? requestTimeout
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if method != .get {
            request.setValue(API.clientKind, forHTTPHeaderField: API.clientHeader)
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func get<T: Decodable>(_ path: [String], query: [URLQueryItem] = []) async throws -> T {
        try await send(.get, path, query: query, body: Optional<Never>.none)
    }

    private func send<T: Decodable, B: Encodable>(
        _ method: Method, _ path: [String], query: [URLQueryItem] = [], body: B?,
        timeout: TimeInterval? = nil
    ) async throws -> T {
        let data = try await sendRaw(method, path, query: query, body: body, timeout: timeout)
        return try decode(T.self, from: data)
    }

    private func sendRaw<B: Encodable>(
        _ method: Method, _ path: [String], query: [URLQueryItem] = [], body: B?,
        timeout: TimeInterval? = nil
    ) async throws -> Data {
        var bodyData: Data?
        if let body {
            do {
                bodyData = try ContractCoding.encoder().encode(body)
            } catch {
                throw ApiError(code: .badRequest, message: "请求编码失败：\(error)")
            }
        }
        let request = makeRequest(method, path, query: query, body: bodyData, timeout: timeout)
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw Self.mapTransportError(error)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw Self.apiError(status: response.statusCode, body: data)
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try ContractCoding.decoder().decode(T.self, from: data)
        } catch {
            throw ApiError(
                code: .internal, message: "无法解析管理服务的响应：\(Self.describe(error))",
                details: ["client": .string("decode")])
        }
    }

    private func sse<E: Decodable & Sendable>(
        _ path: [String], query: [URLQueryItem], as: E.Type
    ) -> AsyncThrowingStream<E, any Error> {
        // The read timeout is an idle timeout; the daemon pings every 10 s.
        let request = makeRequest(.get, path, query: query, accept: "text/event-stream", timeout: 60)
        let transport = self.transport
        return AsyncThrowingStream { continuation in
            let task = Task {
                var parser = SSEParser()
                var status = 0
                var errorBody = Data()
                do {
                    try await transport.stream(request) { part in
                        switch part {
                        case .response(let r):
                            status = r.statusCode
                        case .data(let chunk):
                            guard (200..<300).contains(status) else {
                                if errorBody.count < 1 << 20 { errorBody.append(chunk) }
                                return
                            }
                            for message in parser.feed(chunk) {
                                let event: E
                                do {
                                    let payload = Data(message.data.utf8)
                                    event = try ContractCoding.decoder().decode(E.self, from: payload)
                                } catch {
                                    throw ApiError(
                                        code: .internal,
                                        message: "无法解析事件 \(message.event)：\(Self.describe(error))",
                                        details: ["client": .string("decode")])
                                }
                                continuation.yield(event)
                            }
                        }
                    }
                    if !(200..<300).contains(status) {
                        throw Self.apiError(status: status, body: errorBody)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as ApiError {
                    continuation.finish(throwing: error)
                } catch {
                    if Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: Self.mapTransportError(error))
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Non-2xx → ApiError from the `ErrorBody` when present.
    static func apiError(status: Int, body: Data) -> ApiError {
        if let parsed = try? ContractCoding.decoder().decode(ErrorBody.self, from: body) {
            var error = parsed.error
            if status == 401 { error.code = .unauthorized }
            return error
        }
        if status == 401 {
            return ApiError(code: .unauthorized, message: "管理服务拒绝了认证信息")
        }
        return ApiError(
            code: .internal, message: "管理服务返回 HTTP \(status)",
            details: ["status": .number(Double(status))])
    }

    static func mapTransportError(_ error: any Error) -> any Error {
        if error is CancellationError { return error }
        if let api = error as? ApiError { return api }
        if let url = error as? URLError {
            if url.code == .cancelled { return CancellationError() }
            return ApiError.unreachable("无法连接管理服务：\(url.localizedDescription)")
                .with(details: ["urlError": .number(Double(url.code.rawValue))])
        }
        return ApiError.unreachable("无法连接管理服务：\(error.localizedDescription)")
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, let ctx):
            return "缺少字段 \(path(ctx.codingPath + [key]))"
        case DecodingError.typeMismatch(_, let ctx), DecodingError.valueNotFound(_, let ctx):
            return "字段类型不符 \(path(ctx.codingPath))：\(ctx.debugDescription)"
        case DecodingError.dataCorrupted(let ctx):
            return "数据损坏 \(path(ctx.codingPath))：\(ctx.debugDescription)"
        default:
            return String(describing: error)
        }
    }

    private static func path(_ keys: [any CodingKey]) -> String {
        keys.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
    }
}

extension ApiError {
    func with(details extra: [String: JSONValue]) -> ApiError {
        var copy = self
        copy.details = (details ?? [:]).merging(extra) { _, new in new }
        return copy
    }

    /// True when this error means the URLSession could not open a connection at all
    /// (nothing listening on the discovered port).
    public var isConnectionRefused: Bool {
        guard code == .daemonUnreachable, let raw = details?["urlError"]?.intValue else { return false }
        return raw == URLError.cannotConnectToHost.rawValue
    }
}
