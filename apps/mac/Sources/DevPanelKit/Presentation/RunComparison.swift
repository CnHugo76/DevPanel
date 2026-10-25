import Foundation

public struct RunParamComparison: Sendable, Equatable, Identifiable {
    public var key: String
    public var actual: String
    public var next: String
    public var changed: Bool
    public var masked: Bool
    public var id: String { key }
}

/// Compares the selected immutable run snapshot with the saved next-start configuration.
/// Environment values were deliberately never saved in run details, so only keys can compare.
public struct RunComparison: Sendable {
    public var nextCommand: [String]
    public var nextCwd: String
    public var commandChanged: Bool
    public var commandMasked: Bool
    public var cwdChanged: Bool
    public var params: [RunParamComparison]

    public init(run: RunDetail, config: ServiceConfig, project: ProjectConfig) {
        let definitions = project.params ?? []
        nextCommand = CommandText.substitute(config.command, params: definitions)
        nextCwd = config.cwd.hasPrefix("/") ? config.cwd :
            ((project.root as NSString).appendingPathComponent(config.cwd) as NSString).standardizingPath
        commandChanged = run.command != nextCommand
        commandMasked = (run.command + nextCommand).contains { $0.contains("••••") }
        cwdChanged = run.cwd != nextCwd
        let env = (project.env ?? [:]).merging(config.env ?? [:]) { _, next in next }
        var keys = Set<String>()
        let texts = config.command + env.values.compactMap { value -> String? in
            if case .plain(let text) = value { return text }; return nil
        }
        for text in texts { _ = CommandText.replace(text) { key in keys.insert(key); return nil } }
        let byKey = Dictionary(definitions.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        params = Set(run.params.keys).union(keys).sorted().map { key in
            let old = run.params[key]
            let saved = keys.contains(key) ? byKey[key] : nil
            let masked = old == .secret || saved?.isSecret == true
            let actual: String
            if old == nil { actual = "未使用" }
            else if masked { actual = "••••" }
            else if case .value(let value) = old { actual = value.description.isEmpty ? "（空）" : value.description }
            else { actual = "—" }
            let next: String
            if !keys.contains(key) { next = "不再使用" }
            else if masked { next = "••••" }
            else { next = saved?.value.map { $0.description.isEmpty ? "（空）" : $0.description } ?? "未定义" }
            return RunParamComparison(key: key, actual: actual, next: next, changed: !masked && actual != next, masked: masked)
        }
    }
}
