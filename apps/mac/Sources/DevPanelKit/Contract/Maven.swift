import Foundation

public struct MavenModule: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var pomPath: String
    public var parentId: String?
    public var groupId: String?
    public var artifactId: String
    public var name: String?
    public var packaging: String
    public var profiles: [String]
    public var parentOutside: Bool
    public var error: String?
    public var displayName: String { name.flatMap { $0.contains("${") || $0.isEmpty ? nil : $0 } ?? artifactId }
    public var displayTitle: String { artifactId + (displayName == artifactId ? "" : " · " + displayName) }
}
public enum MavenExecutable: OpenEnum {
    case wrapper, mvn
    case other(String)
    public static let known: [Self] = [.wrapper, .mvn]
    public var rawValue: String { switch self { case .wrapper: "wrapper"; case .mvn: "mvn"; case .other(let s): s } }
}
public struct MavenModel: Codable, Hashable, Sendable {
    public var executable: MavenExecutable
    public var modules: [MavenModule]
    public var profiles: [String]
    public var scannedAt: Timestamp
}

extension MavenRunRequest {
    public init(moduleId: String = ".", goals: [String], profiles: [String] = [], skipTests: Bool = false, offline: Bool = false, alsoMake: Bool = false, mavenProjectId: String? = nil) {
        self.mavenProjectId = mavenProjectId
        self.moduleId = moduleId; self.goals = goals; self.profiles = profiles
        self.skipTests = skipTests; self.offline = offline; self.alsoMake = alsoMake
    }
    /// Preview and saved action argv only. The run endpoint receives structured fields;
    /// the daemon independently validates and constructs the actual executable/arguments.
    public func previewCommand(executable: MavenExecutable) -> [String] {
        var argv = [executable == .wrapper ? "./mvnw" : executable.rawValue]
        if moduleId != "." {
            argv += ["-pl", moduleId]
            if alsoMake == true { argv.append("-am") }
        }
        if skipTests == true { argv.append("-DskipTests") }
        if offline == true { argv.append("-o") }
        if let profiles, !profiles.isEmpty { argv.append("-P" + profiles.joined(separator: ",")) }
        return argv + goals
    }
    public var localError: String? {
        if goals.isEmpty { return "请选择生命周期阶段，或输入 Maven 目标" }
        let goal = #"^[A-Za-z0-9_.-]+(:[A-Za-z0-9_.-]+){0,3}(@[A-Za-z0-9_.-]+)?$"#
        if let bad = goals.first(where: { $0.hasPrefix("-") || $0.range(of: goal, options: .regularExpression) == nil }) {
            return "无效 Maven 目标：\(bad)。这里只接受阶段或插件目标，开关请在工具栏设置。"
        }
        if let bad = profiles?.first(where: { $0.range(of: #"^!?[A-Za-z0-9_.-]+$"#, options: .regularExpression) == nil }) { return "无效 Profile：\(bad)" }
        return nil
    }
}
