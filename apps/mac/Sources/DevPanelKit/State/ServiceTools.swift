import Foundation

/// Resolve registered tools by directory ancestry, never by service name or list order.
public enum ServiceTools {
    public static func closest(cwd: String, paths: [String], root: String) -> Int? {
        func absolute(_ path: String) -> String {
            URL(fileURLWithPath: path.hasPrefix("/") ? path : root + "/" + path).standardizedFileURL.path
        }
        let directory = absolute(cwd)
        return paths.indices.filter {
            let path = absolute(paths[$0])
            return directory == path || directory.hasPrefix(path == "/" ? "/" : path + "/")
        }.max { absolute(paths[$0]).count < absolute(paths[$1]).count }
    }
}

extension AppModel {
    public func serviceToolProject(_ ref: ServiceRef) -> ProjectView? {
        guard var project = project(ref.projectId), let config = serviceConfig(ref.projectId, ref.serviceId) else { return nil }
        if let targets = project.repositories {
            project.repositories = ServiceTools.closest(cwd: config.cwd, paths: targets.map(\.path), root: project.root).map { [targets[$0]] } ?? []
        }
        if let targets = project.mavenProjects {
            project.mavenProjects = ServiceTools.closest(cwd: config.cwd, paths: targets.map(\.path), root: project.root).map { [targets[$0]] } ?? []
        } else {
            let executable = config.command.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
            if config.cwd != ".", !["java", "mvn", "mvnw"].contains(executable) { project.maven = nil }
        }
        return project
    }
    public func serviceTabs(_ ref: ServiceRef) -> [InspectorTab] {
        guard let project = serviceToolProject(ref) else { return InspectorTab.visible }
        return InspectorTab.visible + (project.repositories?.isEmpty != true ? [.git] : [])
            + (project.mavenProjects?.isEmpty == false || (project.mavenProjects == nil && project.maven != nil) ? [.maven] : [])
    }
    public func selectServiceTab(_ tab: InspectorTab, for ref: ServiceRef) {
        select(ref)
        guard selection == ref else { return }
        inspector.tab = serviceTabs(ref).contains(tab) ? tab : .logs
        syncLogSession()
    }
    public func prepareServiceTools(_ ref: ServiceRef) {
        guard let project = serviceToolProject(ref) else { return }
        git.repositorySelections[ref.projectId] = project.repositories?.first?.id
        let target = project.mavenProjects?.first?.id
        if maven.targetSelections[ref.projectId] != target {
            maven.targetSelections[ref.projectId] = target
            projectInspector.runChoice[TaskRef(ref.projectId, .maven)] = nil
        }
        if !serviceTabs(ref).contains(inspector.tab) { inspector.tab = .logs }
    }
}

extension AppModel {
    /// Project pages retain only tools that cannot be reached through a service directory.
    public func projectTabs(_ id: ProjectID) -> [ProjectInspectorTab] {
        guard let project = project(id) else { return [.activity, .options] }
        return ProjectInspectorTab.allCases.filter { tab in
            guard tab == .git || tab == .maven else { return true }
            let contexts = project.services.compactMap { serviceToolProject(ServiceRef(id, $0.id)) }
            if tab == .git {
                guard let targets = project.repositories else { return !contexts.contains { $0.repositories == nil } }
                return targets.isEmpty || targets.contains { target in !contexts.contains { $0.repositories?.contains { $0.id == target.id } == true } }
            }
            guard let targets = project.mavenProjects else { return !contexts.contains { $0.maven != nil } }
            return targets.isEmpty || targets.contains { target in !contexts.contains { $0.mavenProjects?.contains { $0.id == target.id } == true } }
        }
    }
    public func serviceForTool(_ id: ProjectID, tab: ProjectInspectorTab) -> ServiceRef? {
        guard tab == .git || tab == .maven, let project = project(id) else { return nil }
        return project.services.map { ServiceRef(id, $0.id) }.first { ref in
            guard let context = serviceToolProject(ref) else { return false }
            if tab == .git {
                return serviceTabs(ref).contains(.git) && context.repositories?.first?.id == gitScope(id).repositoryId
            }
            return serviceTabs(ref).contains(.maven) && context.mavenProjects?.first?.id == (maven.targetSelections[id] ?? project.mavenProjects?.first?.id)
        }
    }
}
