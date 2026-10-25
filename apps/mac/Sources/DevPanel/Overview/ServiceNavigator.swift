import DevPanelKit
import SwiftUI

/// A narrow source list leaves the detail pane to the selected service's logs.
struct ServiceNavigator: View {
    let model: AppModel
    let query: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(OverviewFilter.apply(model.projects, query: query)) { item in
                    project(item)
                }
            }.padding(12)
        }.background(Theme.bar)
    }

    private func project(_ item: FilteredProject) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.project.name).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text3).padding(.horizontal, 8)
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
    private var ref: ServiceRef { ServiceRef(project.id, service.id) }

    var body: some View {
        Button { model.select(ref) } label: {
            HStack(spacing: 8) {
                ServiceIdentityMark(color: Theme.process(ProcessPalette.index(of: service.id, in: project)))
                Text(service.name).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12.5)).foregroundStyle(Theme.text)
            .padding(8).contentShape(Rectangle())
            .background(model.selection == ref ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain)
            .accessibilityAddTraits(model.selection == ref ? .isSelected : [])
    }
}
