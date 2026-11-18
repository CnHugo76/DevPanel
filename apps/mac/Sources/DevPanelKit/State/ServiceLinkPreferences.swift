import Foundation
import Observation

/// Browser destinations are local UI preferences, independent of daemon configuration.
@Observable
@MainActor
public final class ServiceLinkPreferences {
    private static let key = "services.shortcutURLs"
    private var addresses: [ProjectID: [ServiceID: String]]
    @ObservationIgnored private let defaults: UserDefaults?

    public init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        addresses = defaults?.dictionary(forKey: Self.key) as? [String: [String: String]] ?? [:]
    }

    public func customURL(for service: ServiceRef) -> URL? {
        guard let text = addresses[service.projectId]?[service.serviceId] else { return nil }
        return ServiceShortcutAddress.url(text)
    }

    public func url(for service: ServiceRef, port: Int) -> URL {
        customURL(for: service) ?? URL(string: "http://localhost:\(port)")!
    }

    /// Returns an inline validation message. Invalid input never replaces a saved preference.
    @discardableResult
    public func save(_ text: String, for service: ServiceRef) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let error = ServiceShortcutAddress.validationMessage(trimmed) { return error }
        if trimmed.isEmpty {
            addresses[service.projectId]?[service.serviceId] = nil
            if addresses[service.projectId]?.isEmpty == true { addresses[service.projectId] = nil }
        } else {
            addresses[service.projectId, default: [:]][service.serviceId] = trimmed
        }
        defaults?.set(addresses, forKey: Self.key)
        return nil
    }
}

public enum ServiceShortcutAddress {
    public static func url(_ text: String) -> URL? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
              value.range(of: "%(?![0-9A-Fa-f]{2})", options: .regularExpression) == nil,
              let url = URL(string: value),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.port.map({ (1...65535).contains($0) }) ?? (components.rangeOfPort == nil) else { return nil }
        return url
    }

    /// Empty means reset to the current port's default address.
    public static func validationMessage(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return url(value) == nil ? "请输入完整的 HTTP/HTTPS 地址，例如 http://192.168.10.20:18085/；端口须为 1–65535，地址不能包含空白。" : nil
    }
}
