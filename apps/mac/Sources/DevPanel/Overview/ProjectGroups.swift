import DevPanelKit
import SwiftUI
import UniformTypeIdentifiers

enum ArrangementDrag: Codable, Sendable {
    case project(String)
    case group(String)
    case service(project: String, service: String)

    static let prefix = "devpanel-arrangement:"
}

struct ArrangementHandle: View {
    let value: ArrangementDrag
    let label: String
    var symbol = "line.3.horizontal"
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11)).foregroundStyle(Theme.text3)
            .frame(width: 20, height: 24).contentShape(Rectangle())
            .onDrag {
                let data = (try? JSONEncoder().encode(value)) ?? Data()
                return NSItemProvider(object: (ArrangementDrag.prefix + String(decoding: data, as: UTF8.self)) as NSString)
            }
            .help(label).accessibilityLabel(label)
    }
}

/// Drop positions use the actual target height; movement is committed only on drop.
struct ArrangementDrop: ViewModifier {
    let accept: @MainActor (ArrangementDrag, Bool) -> Bool
    @State private var targeted = false
    @State private var height: CGFloat = 44

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .onDrop(of: [UTType.plainText], isTargeted: $targeted) { providers, position in
                guard providers.count == 1, let provider = providers.first else { return false }
                let after = position.y > height / 2
                let accept = accept
                provider.loadObject(ofClass: NSString.self) { object, _ in
                    guard let text = object as? String, text.utf8.count < 16_384, text.hasPrefix(ArrangementDrag.prefix),
                          let value = try? JSONDecoder().decode(ArrangementDrag.self, from: Data(text.dropFirst(ArrangementDrag.prefix.count).utf8)) else { return }
                    Task { @MainActor in _ = accept(value, after) }
                }
                return true
            }
            .overlay {
                if targeted { RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.accent, lineWidth: 2).allowsHitTesting(false) }
            }
    }
}

struct ProjectGroupHeader: View {
    let organization: ProjectOrganization
    let section: ProjectSection
    let projects: [ProjectView]
    let searching: Bool
    var compact = false
    @State private var editing = false
    @State private var removing = false

    var body: some View {
        if let group = section.group {
            HStack(spacing: 6) {
                ArrangementHandle(value: .group(group.id), label: "拖动分组 \(group.name)")
                Button { organization.toggleCollapsed(group.id) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: organization.isCollapsed(group.id) && !searching ? "chevron.right" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                        if !compact { Image(systemName: "folder").foregroundStyle(Theme.accent2) }
                        Text(group.name).font(.system(size: compact ? 12 : 14, weight: .semibold))
                            .lineLimit(compact ? 2 : 1).fixedSize(horizontal: false, vertical: true)
                            .layoutPriority(1).help(group.name)
                        if !compact {
                            Text("\(section.members.count) 个项目 · \(section.runningCount) 个服务运行中")
                                .font(.system(size: 11)).foregroundStyle(Theme.text3).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if section.problemCount > 0 {
                            Label("\(section.problemCount)", systemImage: "exclamationmark.triangle.fill")
                                .labelStyle(GroupProblemLabelStyle(compact: compact))
                                .font(.system(size: 11)).foregroundStyle(Theme.amber)
                                .help("\(section.problemCount) 个服务异常、状态未知或就绪超时")
                        }
                    }.contentShape(Rectangle()).frame(minHeight: 30)
                }.buttonStyle(.plain)
                    .accessibilityLabel(group.name)
                    .accessibilityValue(organization.isCollapsed(group.id) && !searching ? "已折叠" : "已展开")
                    .accessibilityIdentifier("group-disclosure-" + group.id)
                MoreMenu {
                    Button("编辑分组…") { editing = true }
                    Divider()
                    Button("上移") { organization.shiftSection(group.id, down: false, projects: projects) }
                        .disabled(organization.sections(projects).first?.id == group.id)
                    Button("下移") { organization.shiftSection(group.id, down: true, projects: projects) }
                        .disabled(organization.sections(projects).last?.id == group.id)
                    Divider()
                    Button("解散分组…") { removing = true }
                }
            }
            .padding(.vertical, 4)
            .modifier(ArrangementDrop { value, after in
                switch value {
                case .project(let id):
                    organization.moveProject(id, to: group.id, projects: projects)
                    return projects.contains { $0.id == id }
                case .group(let id):
                    guard id != group.id else { return false }
                    organization.placeSection(id, beside: group.id, after: after, projects: projects)
                    return true
                case .service: return false
                }
            })
            .sheet(isPresented: $editing) { ProjectGroupEditor(organization: organization, projects: projects, group: group) }
            .alert("解散“\(group.name)”？", isPresented: $removing) {
                Button("解散分组") { organization.removeGroup(group.id, projects: projects) }
                Button("取消", role: .cancel) {}
            } message: { Text("组内项目会回到外层列表，配置和运行状态保持原样。") }
        }
    }
}

private struct GroupProblemLabelStyle: LabelStyle {
    let compact: Bool
    func makeBody(configuration: Configuration) -> some View {
        if compact { configuration.icon }
        else { HStack(spacing: 4) { configuration.icon; configuration.title } }
    }
}

struct ProjectArrangementMenu: View {
    let organization: ProjectOrganization
    let project: ProjectView
    let projects: [ProjectView]

    var body: some View {
        Menu("移到分组") {
            Button("不分组") { organization.moveProject(project.id, to: nil, projects: projects) }
            ForEach(organization.groups(in: projects)) { group in
                Button {
                    organization.moveProject(project.id, to: group.id, projects: projects)
                } label: {
                    if organization.groupID(for: project) == group.id { Label(group.name, systemImage: "checkmark") }
                    else { Text(group.name) }
                }
            }
        }
        Button("上移项目") { organization.shiftProject(project.id, down: false, projects: projects) }
        Button("下移项目") { organization.shiftProject(project.id, down: true, projects: projects) }
    }
}

struct UngroupedDropArea: View {
    let organization: ProjectOrganization
    let projects: [ProjectView]
    var body: some View {
        Text("拖到这里移到列表末尾 · 项目会移出分组")
            .font(.system(size: 11)).foregroundStyle(Theme.text3)
            .frame(maxWidth: .infinity, minHeight: 36)
            .contentShape(Rectangle())
            .modifier(ArrangementDrop { value, _ in
                switch value {
                case .project(let id):
                    guard projects.contains(where: { $0.id == id }) else { return false }
                    organization.moveProject(id, to: nil, projects: projects)
                    organization.moveSection(ProjectOrganization.projectSectionID(id), before: nil, projects: projects)
                    return true
                case .group(let id):
                    organization.moveSection(id, before: nil, projects: projects)
                    return true
                case .service: return false
                }
            })
    }
}

struct ProjectGroupEditor: View {
    let organization: ProjectOrganization
    let projects: [ProjectView]
    let group: ProjectGroup?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var selected: Set<ProjectID>

    init(organization: ProjectOrganization, projects: [ProjectView], group: ProjectGroup? = nil) {
        self.organization = organization
        self.projects = projects
        self.group = group
        _name = State(initialValue: group?.name ?? "")
        _selected = State(initialValue: Set(projects.filter { group != nil && organization.groupID(for: $0) == group?.id }.map(\.id)))
    }

    private var error: String? { organization.nameError(name, excluding: group?.id, projects: projects) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(group == nil ? "新建项目组" : "编辑项目组").font(.headline)
            TextField("例如：示例工作区 / Demo", text: $name).textFieldStyle(.roundedBorder)
                .accessibilityLabel("分组名称")
            if !name.isEmpty, let error { Text(error).font(.callout).foregroundStyle(Theme.red) }
            Text("包含项目").font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(projects) { project in
                        Toggle(isOn: Binding(get: { selected.contains(project.id) }, set: { value in
                            if value { selected.insert(project.id) } else { selected.remove(project.id) }
                        })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(project.name).lineLimit(1)
                                Text(Format.tildePath(project.root)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        }.toggleStyle(.checkbox)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 230)
            Text("分组和显示顺序保存在这台 Mac 上，重开后保留。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存", action: save).keyboardShortcut(.defaultAction).disabled(error != nil)
            }
        }.padding(24).frame(width: 460)
    }

    private func save() {
        guard error == nil else { return }
        let id: String
        if let group {
            id = group.id
            organization.renameGroup(id, name: name, projects: projects)
        } else {
            guard let created = organization.createGroup(name, projects: projects) else { return }
            id = created
        }
        for project in projects {
            if selected.contains(project.id) {
                if organization.groupID(for: project) != id { organization.moveProject(project.id, to: id, projects: projects) }
            } else if organization.groupID(for: project) == id { organization.moveProject(project.id, to: nil, projects: projects) }
        }
        organization.reveal(id)
        dismiss()
    }
}
