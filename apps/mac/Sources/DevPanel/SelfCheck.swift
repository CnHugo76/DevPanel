import DevPanelKit
import Foundation

/// `DevPanel --self-check [--timeout <sec>]`
///
/// Reads the discovery file, connects through the same `AppModel` the window uses, waits for
/// the snapshot, cross-checks `GET /projects` and `GET /daemon`, prints a summary and exits.
///
/// Exit codes: 0 connected · 1 other failure · 2 daemon not running · 3 unreachable / no
/// snapshot · 4 unauthorized · 5 snapshot and REST disagree.
@MainActor
enum SelfCheck {
    static func run(arguments: [String]) async -> Int32 {
        var timeout: TimeInterval = 10
        if let i = arguments.firstIndex(of: "--timeout"), i + 1 < arguments.count,
           let t = TimeInterval(arguments[i + 1]) {
            timeout = t
        }

        let home = DaemonHome.resolve()
        out("DevPanel self-check")
        out("home:       \(home.url.path)\(home.isOverridden ? "  (DEVPANEL_HOME)" : "")")
        switch Result(catching: { try DiscoveryReader(home: home).read() }) {
        case .success(let d?):
            out("discovery:  http://127.0.0.1:\(d.httpPort)\(API.basePath)  pid \(d.pid)  version \(d.version)")
        case .success(nil):
            out("discovery:  \(home.discoveryFile.path) 不存在")
        case .failure(let e):
            out("discovery:  \(e.localizedDescription)")
        }

        let model = AppModel(environment: .live(home: home))
        model.start()
        let deadline = Date().addingTimeInterval(timeout)
        while model.connection.status == .connecting, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        let connection = model.connection
        let client = model.client
        model.stop()

        out("status:     \(connection.status.rawValue)  ·  \(connection.summary(running: model.runningServiceCount, total: model.serviceCount, projectCount: model.projects.count, now: Date()))")

        switch connection.status {
        case .connected:
            break
        case .notRunning:
            out(connection.staleDiscovery
                ? "result:     管理服务未运行（发现文件存在但端口无人监听）"
                : "result:     管理服务未运行")
            return 2
        case .unauthorized:
            out("result:     认证失败：\(connection.lastError?.message ?? "")")
            return 4
        case .disconnected:
            out("result:     连接失败：\(connection.lastError?.description ?? "")")
            return 3
        case .connecting:
            out("result:     \(Int(timeout)) 秒内没有收到 snapshot")
            return 3
        }

        if let d = model.daemon {
            out("daemon:     \(d.version)  api v\(d.apiVersion)  pid \(d.pid)  stats \(d.limits.statsIntervalMs)ms")
        }
        out("projects:   \(model.projects.count)")
        out("services:   \(model.serviceCount)  (running \(model.runningServiceCount))")
        out("operations: \(model.operations.count)  ·  stats: \(model.stats.map { "\($0.projects.count) 个项目有采样" } ?? "无")")
        for p in model.projects {
            let label = p.aggregate.label(running: p.runningCount, total: p.serviceCount)
            let services = p.services.map { "\($0.id)=\($0.state.rawValue)" }.joined(separator: " ")
            out("  - \(p.name) [\(p.id)]  \(label)  ·  \(p.serviceCount) 个服务  ·  \(services)")
        }

        // Cross-check the REST path against the snapshot.
        guard let client else { return 1 }
        do {
            let info = try await client.daemonInfo()
            let rest = try await client.projects()
            let restServices = rest.reduce(0) { $0 + $1.serviceCount }
            let same = rest.map(\.id) == model.projects.map(\.id) && restServices == model.serviceCount
            out("rest:       GET /daemon \(info.version) · GET /projects \(rest.count) 个项目 / \(restServices) 个服务\(same ? "（与 snapshot 一致）" : "（与 snapshot 不一致）")")
            if !same { return 5 }
        } catch {
            out("rest:       失败 \(error)")
            return 1
        }
        out("result:     OK")
        return 0
    }

    private static func out(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}
