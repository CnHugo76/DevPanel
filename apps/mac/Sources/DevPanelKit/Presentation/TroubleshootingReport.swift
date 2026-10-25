import Foundation

/// A report is always pinned to one run; all fields originate from already-masked responses.
public struct TroubleshootingReport: Sendable {
    public var runId: RunID
    public var text: String
    public var digest: LogDigest
    public var firstError: LogDigestBlock? { digest.blocks.first { $0.kind == .error } }
    public static let byteLimit = 48 * 1024

    public static func load(client: DaemonClient, owner: LogOwner, runId: RunID) async throws -> Self {
        async let digest = client.digest(runId)
        let lines: [String]
        switch owner {
        case .service(let ref):
            let run = try await client.run(runId)
            guard run.id == runId, run.projectId == ref.projectId, run.serviceId == ref.serviceId else { throw mismatch() }
            lines = serviceLines(run)
        case .task(let ref):
            let run = try await client.taskRun(runId)
            guard run.id == runId, run.projectId == ref.projectId else { throw mismatch() }
            switch ref.target {
            case .action(let id): guard run.kind == .action, run.actionId == id else { throw mismatch() }
            case .maven: guard run.kind == .maven else { throw mismatch() }
            }
            lines = baseLines(id: run.id, projectId: run.projectId, label: run.label, state: run.state.title,
                              revision: run.configRevision, actor: run.startedBy, startedAt: run.startedAt,
                              endedAt: run.endedAt, pid: run.pid, command: run.command, cwd: run.cwd,
                              envKeys: run.envKeys, params: run.params, exit: run.exit)
                + ["就绪：一次性任务不使用服务就绪检查"]
        }
        let result = try await digest
        guard result.runId == runId else { throw mismatch() }
        return Self(runId: runId, text: bounded((lines + ["", result.text]).joined(separator: "\n")), digest: result)
    }

    public static func make(run: RunDetail, digest: LogDigest) throws -> Self {
        guard run.id == digest.runId else { throw mismatch() }
        return Self(runId: run.id, text: bounded((serviceLines(run) + ["", digest.text]).joined(separator: "\n")), digest: digest)
    }

    private static func serviceLines(_ run: RunDetail) -> [String] {
        baseLines(id: run.id, projectId: run.projectId, label: run.serviceId, state: run.summary.stateText,
                  revision: run.configRevision, actor: run.startedBy, startedAt: run.startedAt, endedAt: run.endedAt,
                  pid: run.pid, command: run.command, cwd: run.cwd, envKeys: run.envKeys, params: run.params, exit: run.exit)
        + ["就绪：\(run.ready?.explanation ?? "未提供就绪证据")"]
        + (run.ready?.nextStep.map { ["下一步：\($0)"] } ?? [])
    }

    private static func baseLines(id: RunID, projectId: ProjectID, label: String, state: String, revision: Int,
                                  actor: Actor?, startedAt: Timestamp, endedAt: Timestamp?, pid: Int?, command: [String],
                                  cwd: String, envKeys: [String], params: [String: RunParamValue], exit: ExitInfo?) -> [String] {
        var lines = ["DevPanel 排障信息", "运行：\(id)", "项目：\(projectId) / \(label)",
                     "状态：\(state)", "配置版本：\(revision)", "启动来源：\(actor?.sourceLabel ?? "未知")",
                     "开始：\(startedAt)", "结束：\(endedAt ?? "尚未结束")", "PID：\(pid.map(String.init) ?? "—")",
                     "实际命令：\(CommandText.join(command))", "工作目录：\(cwd)",
                     "环境变量名：\(envKeys.sorted().joined(separator: ", "))（不保存或复制环境变量值）"]
        for key in params.keys.sorted() {
            let value: String
            switch params[key]! { case .secret: value = "••••"; case .value(let param): value = param.description }
            lines.append("实际选项 \(key)：\(value)")
        }
        lines.append("退出：\(exit?.summary ?? "未记录")")
        return lines
    }

    private static func bounded(_ text: String) -> String {
        let clean = Ansi.strip(text)
        guard clean.utf8.count > byteLimit else { return clean }
        let suffix = "\n[排障信息超过 48 KiB，后续内容已省略]"
        return String(decoding: clean.utf8.prefix(byteLimit - suffix.utf8.count - 3), as: UTF8.self) + suffix
    }

    private static func mismatch() -> ApiError { ApiError(code: .internal, message: "排障信息的运行不一致，请重新选择运行。") }
}
