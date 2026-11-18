import Darwin
import Foundation

public struct LocalNetworkAddress: Equatable, Identifiable, Sendable {
    public var interface: String
    public var address: String
    public var id: String { interface + ":" + address }
    public init(interface: String, address: String) { self.interface = interface; self.address = address }

    /// A local interface snapshot, without contacting any server or requesting network access.
    public static func detect() -> [Self] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }
        var values: [Self] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let entry = current.pointee
            guard let address = entry.ifa_addr,
                  entry.ifa_flags & UInt32(IFF_UP) != 0,
                  entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let host = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard isPrivateIPv4(host) else { continue }
            values.append(Self(interface: String(cString: entry.ifa_name), address: host))
        }
        return values.sorted {
            let a = $0.interface.hasPrefix("en") ? 0 : 1
            let b = $1.interface.hasPrefix("en") ? 0 : 1
            return a == b ? $0.id < $1.id : a < b
        }.reduce(into: []) { result, value in
            if !result.contains(where: { $0.address == value.address }) { result.append(value) }
        }
    }

    public static func isPrivateIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let bytes = parts.compactMap { UInt8($0) }
        guard bytes.count == 4 else { return false }
        return bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1]))
            || (bytes[0] == 192 && bytes[1] == 168)
    }
}

public enum ServiceLinkSuggestions {
    /// Listening ports first; an explicit readiness port also works for stopped services.
    public static func ports(listening: [ListeningPort]?, config: ServiceConfig?, params: [ParamConfig]) -> [Int] {
        var ports = Array(Set((listening ?? []).map(\.port))).sorted()
        if let check = config?.ready?.check, check.kind == .port, let value = check.port {
            var resolved = value
            if case .string(let placeholder) = value, placeholder.hasPrefix("${"), placeholder.hasSuffix("}") {
                let key = String(placeholder.dropFirst(2).dropLast())
                if let param = params.first(where: { $0.key == key && $0.secret != true }), let value = param.value { resolved = value }
            }
            if case .number(let value) = resolved, value.isFinite, value.rounded() == value, (1...65535).contains(value) {
                let port = Int(value)
                if !ports.contains(port) { ports.append(port) }
            }
        }
        return ports.filter { (1...65535).contains($0) }
    }

    /// Selecting a host or port preserves the user's scheme, path, query and fragment.
    public static func address(_ text: String, host: String? = nil, port: Int? = nil, defaultPort: Int? = nil) -> String {
        let base = ServiceShortcutAddress.url(text)?.absoluteString ?? "http://localhost" + (defaultPort.map { ":\($0)" } ?? "") + "/"
        guard var components = URLComponents(string: base) else { return text }
        if let host { components.host = host }
        if let port, (1...65535).contains(port) { components.port = port }
        return components.url?.absoluteString ?? text
    }
}

public extension ServiceView {
    /// A browser shortcut needs a known web service and sockets for its current run.
    /// Explicit user URLs can also point at a reverse proxy or another host.
    func overviewURLs(customURL: URL?, listening: [ListeningPort]?, command: [String]) -> [URL] {
        guard state == .running, currentRun != nil else { return [] }
        if let customURL { return [customURL] }
        let names = (id + " " + name).lowercased()
        let words = names.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let webNames = ["frontend", "web", "ui", "www", "website"]
        let webTools = ["vite", "next", "nuxt", "astro", "webpack-dev-server", "react-scripts"]
        guard names.contains("前端") || words.contains(where: { webNames.contains(String($0)) })
                || command.contains(where: { webTools.contains(($0 as NSString).lastPathComponent) }) else { return [] }
        let sockets = listening ?? []
        let ports = Set(sockets.filter {
            ($0.scope == .loopback || $0.scope == .all) && (1...65535).contains($0.port)
        }.map(\.port))
        return ports.sorted().compactMap { URL(string: "http://localhost:\($0)") }
    }
}
