import Foundation

/// Locates `<home>/daemon.json`.
///
/// `home` defaults to `~/Library/Application Support/DevPanel` and is overridden by
/// `DEVPANEL_HOME` (development: `<repo>/.devpanel-dev/mock` for the mock daemon).
public struct DaemonHome: Hashable, Sendable {
    public var url: URL

    public init(url: URL) { self.url = url }

    public static func resolve(
        environment: [String: String] = Foundation.ProcessInfo.processInfo.environment,
        userHome: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> DaemonHome {
        if let override = environment["DEVPANEL_HOME"], !override.isEmpty {
            let expanded = (override as NSString).expandingTildeInPath
            return DaemonHome(url: URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL)
        }
        return DaemonHome(
            url: userHome
                .appendingPathComponent("Library/Application Support/DevPanel", isDirectory: true))
    }

    public var discoveryFile: URL { url.appendingPathComponent("daemon.json") }

    public var isOverridden: Bool {
        !url.path.hasSuffix("/Library/Application Support/DevPanel")
    }
}

public enum DiscoveryError: Error, Equatable, Sendable, LocalizedError {
    /// The file exists but cannot be read or parsed (e.g. caught mid-write).
    case unreadable(String)
    /// The daemon speaks an API version this app does not.
    case incompatibleAPI(Int)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let why): "无法读取发现文件：\(why)"
        case .incompatibleAPI(let v): "管理服务的接口版本（v\(v)）与本程序（v\(API.version)）不兼容"
        }
    }
}

public struct DiscoveryReader: Sendable {
    public var home: DaemonHome

    public init(home: DaemonHome) { self.home = home }

    /// nil = file missing = "管理服务未运行".
    public func read() throws(DiscoveryError) -> DaemonDiscovery? {
        let file = home.discoveryFile
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        } catch {
            if !FileManager.default.fileExists(atPath: file.path) { return nil }
            throw .unreadable(error.localizedDescription)
        }
        let discovery: DaemonDiscovery
        do {
            discovery = try ContractCoding.decoder().decode(DaemonDiscovery.self, from: data)
        } catch {
            throw .unreadable(String(describing: error))
        }
        guard discovery.apiVersion == API.version else { throw .incompatibleAPI(discovery.apiVersion) }
        return discovery
    }
}

/// Address + credentials of a running daemon.
public struct DaemonEndpoint: Hashable, Sendable {
    /// `http://127.0.0.1:<httpPort>/api/v1`
    public var baseURL: URL
    public var token: String

    public init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }

    public init(discovery: DaemonDiscovery) {
        // 127.0.0.1 only: the daemon binds loopback and validates Host.
        self.baseURL = URL(string: "http://127.0.0.1:\(discovery.httpPort)\(API.basePath)")!
        self.token = discovery.token
    }
}
