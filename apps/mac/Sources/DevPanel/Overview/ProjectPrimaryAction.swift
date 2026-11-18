import DevPanelKit
import SwiftUI

struct ProjectPrimaryAction: View {
    let model: AppModel
    let project: ProjectView
    let links: ServiceLinkPreferences
    @Environment(\.openURL) private var openURL
    @Environment(\.isStale) private var stale

    private struct Destination: Identifiable {
        let name: String
        let url: URL
        let frontend: Bool
        var id: URL { url }
    }

    private var destinations: [Destination] {
        var seen: Set<URL> = []
        return project.services.flatMap { service in
            let ref = ServiceRef(project.id, service.id)
            let urls = service.overviewURLs(customURL: links.customURL(for: ref),
                listening: model.listening(for: service, in: project.id), command: model.serviceConfig(project.id, service.id)?.command ?? [])
            return urls.filter { seen.insert($0).inserted }.map { Destination(name: service.name, url: $0, frontend: service.name.contains("前端") || service.id == "frontend") }
        }
    }

    var body: some View {
        let choices = destinations
        if choices.count == 1, let first = choices.first {
            Button { openURL(first.url) } label: {
                Label(project.services.count > 1 && first.frontend ? "打开前端" : "打开", systemImage: "arrow.up.right")
                    .lineLimit(1)
            }.help(first.url.absoluteString).disabled(stale)
        } else if choices.count > 1 {
            Menu("打开…") {
                ForEach(choices) { item in
                    Button(item.name + " · " + item.url.absoluteString) { openURL(item.url) }
                }
            }.fixedSize().disabled(stale)
        } else if project.availableActions.start && !project.services.contains(where: { $0.state.isActive }) {
            let req = ActionRequest(projectId: project.id, action: .start)
            Button { Task { await model.runAction(req) } } label: { Label("启动", systemImage: "play") }
                .disabled(stale || model.isPending(req))
        } else {
            Button("查看服务") {
                if let service = project.services.first(where: { $0.state.isActive }) ?? project.services.first {
                    model.select(ServiceRef(project.id, service.id))
                } else { model.selectProject(project.id) }
            }
        }
    }
}
