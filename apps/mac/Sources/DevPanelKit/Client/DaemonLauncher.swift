import Foundation

/// Runs `devpanel daemon start` (the user-installed CLI shim) for the "启动管理服务" button.
///
/// Only the daemon is started; no project is ever started by this. The CLI inherits this
/// process's environment, so `DEVPANEL_HOME` (if set) applies to the daemon it launches.
public struct DaemonLauncher: Sendable {
    public enum Failure: Error, Equatable, Sendable, LocalizedError {
        /// The CLI shim is not installed: point to setup guidance without choosing a write location.
        case cliNotFound(path: String)
        case failed(exitCode: Int32, output: String)
        case timedOut

        public var errorDescription: String? {
            switch self {
            case .cliNotFound(let path):
                "找不到命令行工具 \(path)。请打开“接入第一个项目”检查 CLI 入口；源码开发请使用隔离数据目录与源码 CLI。"
            case .failed(let code, let output):
                "启动管理服务失败（退出码 \(code)）\(output.isEmpty ? "" : "：\(output)")"
            case .timedOut:
                "启动管理服务超时"
            }
        }
    }

    public var cliPath: URL
    public var environment: [String: String]
    public var timeout: Duration

    /// 发布 App 优先使用内置 CLI；隔离开发继续使用既有入口。
    public static var defaultCLIPath: URL {
        preferredCLIPath(bundleURL: Bundle.main.bundleURL, environment: Foundation.ProcessInfo.processInfo.environment)
    }

    public static func preferredCLIPath(bundleURL: URL, environment: [String: String], userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let bundled = bundleURL.appendingPathComponent("Contents/Resources/runtime/bin/devpanel")
        if environment["DEVPANEL_HOME"] == nil, FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        return userHome.appendingPathComponent(".local/bin/devpanel")
    }

    public init(
        cliPath: URL = DaemonLauncher.defaultCLIPath,
        environment: [String: String] = Foundation.ProcessInfo.processInfo.environment,
        timeout: Duration = .seconds(30)
    ) {
        self.cliPath = cliPath
        self.environment = environment
        self.timeout = timeout
    }

    public var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: cliPath.path) }

    /// Runs `<cli> daemon start` and returns its combined output on success.
    public func start() async throws(Failure) -> String {
        try await run(arguments: ["daemon", "start"])
    }

    /// 与 CLI 相同的登录启动语义；只有引导中明确勾选后才调用。
    public func installLoginItem() async throws(Failure) -> String {
        try await run(arguments: ["daemon", "install"])
    }

    private func run(arguments: [String]) async throws(Failure) -> String {
        guard isInstalled else { throw .cliNotFound(path: cliPath.path) }
        let process = Process()
        process.executableURL = cliPath
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        // Output goes to a temp file, not a pipe: a detached daemon that inherited a pipe would
        // keep it open and block reading until the daemon exits.
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpanel-daemon-start-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: logURL.path, contents: nil),
              let logHandle = try? FileHandle(forWritingTo: logURL)
        else { throw .failed(exitCode: -1, output: "无法创建临时输出文件") }
        defer {
            try? logHandle.close()
            try? FileManager.default.removeItem(at: logURL)
        }
        process.standardOutput = logHandle
        process.standardError = logHandle

        let result: Result<(Int32, String), Failure> = await withCheckedContinuation { continuation in
            let box = OnceBox(continuation)
            process.terminationHandler = { p in
                let data = (try? Data(contentsOf: logURL)) ?? Data()
                let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                box.resume(.success((p.terminationStatus, String(text.suffix(2000)))))
            }
            do {
                try process.run()
            } catch {
                box.resume(.failure(.failed(exitCode: -1, output: error.localizedDescription)))
                return
            }
            let pid = process.processIdentifier
            let timeout = self.timeout
            Task {
                try? await Task.sleep(for: timeout)
                // Only our own child, identified by the Process object we spawned.
                if process.isRunning, process.processIdentifier == pid { process.terminate() }
                box.resume(.failure(.timedOut))
            }
        }
        let (status, output) = try result.get()
        guard status == 0 else { throw .failed(exitCode: status, output: output) }
        return output
    }
}

/// Resumes a continuation at most once (termination handler vs. timeout).
private final class OnceBox<T: Sendable>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, Never>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = continuation }

    func resume(_ value: T) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}
