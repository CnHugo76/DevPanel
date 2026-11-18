import DevPanelKit
import SwiftUI

/// A narrow source list leaves the detail pane to the selected service's logs.
struct ServiceNavigator: View {
    let model: AppModel
    let prefs: ViewPreferences
    let query: String

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ForEach(prefs.organization.sections(model.projects, query: query)) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        if section.group != nil {
                            ProjectGroupHeader(organization: prefs.organization, section: section,
                                               projects: model.projects, searching: searching, compact: true)
                        }
                        if section.group == nil || searching || !prefs.organization.isCollapsed(section.id) {
                            ForEach(section.projects) { item in project(item) }
                        }
                    }
                    .id(section.id)
                }
                if query.isEmpty { UngroupedDropArea(organization: prefs.organization, projects: model.projects) }
            }.padding(12)
        }.background(Theme.bar)
        .onChange(of: prefs.organization.revealGeneration) { _, _ in
            if let id = prefs.organization.revealGroup {
                Task { @MainActor in
                    await Task.yield()
                    proxy.scrollTo(id, anchor: .top)
                }
            }
        }
        }
    }

    private func project(_ item: FilteredProject) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                ArrangementHandle(value: .project(item.id), label: "拖动项目 \(item.project.name)")
                Text(item.project.name).font(.system(size: 11, weight: .semibold)).lineLimit(2)
                Spacer(minLength: 0)
            }
                .foregroundStyle(Theme.text3).padding(.horizontal, 8)
                .help(item.project.root + "\n" + item.project.id)
                .contextMenu { ProjectArrangementMenu(organization: prefs.organization, project: item.project, projects: model.projects) }
                .modifier(ArrangementDrop { value, after in
                    switch value {
                    case .project(let id):
                        guard id != item.id, model.projects.contains(where: { $0.id == id }) else { return false }
                        prefs.organization.placeProject(id, beside: item.id, after: after, projects: model.projects)
                        return true
                    case .group(let id):
                        guard prefs.organization.groupID(for: item.project) == nil else { return false }
                        prefs.organization.placeSection(id, beside: ProjectOrganization.projectSectionID(item.id), after: after, projects: model.projects)
                        return true
                    case .service: return false
                    }
                })
            if let instance = item.project.instance {
                Text(instance.displayText).font(.system(size: 10.5)).foregroundStyle(Theme.accent2)
                    .lineLimit(2).padding(.horizontal, 8)
                    .help(instance.displayText + "\n" + item.project.root + "\n" + item.project.id)
            }
            Button { model.selectProject(item.project.id) } label: {
                Label("项目", systemImage: "folder").frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    .background(model.inspectorSelection == .project(item.project.id) ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(.plain)
            ForEach(item.services, id: \.id) { service in
                ServiceNavigationRow(model: model, project: item.project, service: service)
            }
        }
    }
}

private struct ServiceNavigationRow: View {
    let model: AppModel
    let project: ProjectView
    let service: ServiceView
    @Environment(ProjectOrganization.self) private var organization
    private var ref: ServiceRef { ServiceRef(project.id, service.id) }

    var body: some View {
        HStack(spacing: 8) {
            ArrangementHandle(value: .service(project: project.id, service: service.id), label: "拖动服务 \(service.name)")
            ServiceIdentityMark(color: Theme.process(ProcessPalette.index(of: service.id, in: project)))
            Text(service.name).lineLimit(1)
            Spacer(minLength: 0)
        }
            .font(.system(size: 12.5)).foregroundStyle(Theme.text)
            .padding(8).contentShape(Rectangle())
            .background(model.selection == ref ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 6))
            .onTapGesture { model.select(ref) }
            .focusable()
            .onKeyPress(.return) { model.select(ref); return .handled }
            .onKeyPress(.space) { model.select(ref); return .handled }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(service.name)
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(model.selection == ref ? .isSelected : [])
            .accessibilityAction { model.select(ref) }
            .contextMenu {
                Button("上移服务") { organization.shiftService(service.id, in: project, down: false) }
                Button("下移服务") { organization.shiftService(service.id, in: project, down: true) }
            }
            .modifier(ArrangementDrop(accept: acceptDrop))
    }

    private func acceptDrop(_ value: ArrangementDrag, _ after: Bool) -> Bool {
        guard case .service(let projectID, let serviceID) = value,
              projectID == project.id, serviceID != service.id,
              project.services.contains(where: { $0.id == serviceID }) else { return false }
        organization.placeService(serviceID, in: project, beside: service.id, after: after)
        return true
    }
}
