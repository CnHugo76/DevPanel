import Foundation

/// A problem belongs to a particular service and (when known) one particular run.
public struct OverviewProblem: Equatable, Identifiable, Sendable {
    public let ref: ServiceRef
    public let serviceName: String
    public let isFailure: Bool
    public let summary: String
    public let runID: RunID?
    public var id: ServiceRef { ref }

    public init?(projectID: ProjectID, service: ServiceView) {
        self.ref = ServiceRef(projectID, service.id)
        self.serviceName = service.name
        self.isFailure = service.state == .failed
        if service.stopTimedOut {
            summary = "停止超时"
            runID = service.currentRun?.id
        } else if service.state == .unknown {
            summary = "进程状态无法核验"
            runID = nil
        } else if service.state == .failed {
            summary = service.failureReason
            // A rejected start need not create a new run. Never attach an older success.
            runID = service.lastRun.flatMap { $0.state == .failed ? $0.id : nil }
        } else if service.currentRun?.ready?.state == .timedOut {
            summary = "等待就绪超时"
            runID = service.currentRun?.id
        } else {
            return nil
        }
    }

    private func port(in text: String) -> Int? {
        guard let range = text.range(of: #"(?i)\bport\s+[0-9]{1,5}\b"#, options: .regularExpression),
              let port = text[range].split(whereSeparator: \.isWhitespace).last.flatMap({ Int($0) }),
              (1...65535).contains(port) else { return nil }
        return port
    }

    public func evidence(in digest: LogDigest?) -> String? {
        guard let digest, digest.runId == runID,
              let block = digest.blocks.first(where: { $0.kind == .error }) else { return nil }
        let lines = block.lines.map { Ansi.strip($0.text).trimmingCharacters(in: .whitespacesAndNewlines) }
        if let line = lines.first(where: {
            let text = $0.lowercased()
            return text.contains("address already in use") || text.contains("address in use")
                || text.contains("eaddrinuse") || (text.contains("port ") && text.contains("already in use"))
        }) {
            return port(in: line).map { "日志提示 \($0) 端口已被占用" } ?? "日志提示监听地址已被占用"
        }
        if let line = lines.first(where: { $0.localizedCaseInsensitiveContains("failed to bind port ") }),
           let port = port(in: line) {
            return "日志提示无法绑定 \(port) 端口"
        }
        return lines.first(where: { !$0.isEmpty })
    }
}
