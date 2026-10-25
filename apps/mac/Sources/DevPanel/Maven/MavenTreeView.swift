import AppKit
import DevPanelKit
import SwiftUI

struct MavenTreeView: View {
    let model: AppModel
    let project: ProjectView
    let maven: MavenModel
    let run: (MavenRunRequest) -> Void
    let save: (MavenRunRequest) -> Void
    @State private var expansion = MavenTreeExpansion()
    @State private var profilesOpen = true
    @FocusState private var focused: Bool
    private var selection: MavenSelection { model.maven.selections[model.maven.key(project.id), default: MavenSelection()] }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !maven.profiles.isEmpty { profiles.padding(.horizontal, 10).padding(.bottom, 8); Divider() }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(maven.modules.filter { visible($0) }) { module in
                        moduleHeader(module)
                        if !expansion.collapsed.contains(module.id), module.error == nil { lifecycle(module) }
                    }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onChange(of: maven.modules.map(\.id), initial: true) { _, _ in
            expansion.synchronize(maven.modules)
            expansion.reveal(selection.moduleId, modules: maven.modules)
        }
        .onChange(of: selection.moduleId) { _, id in expansion.reveal(id, modules: maven.modules) }
        .focusable().focused($focused).focusEffectDisabled()
        .onKeyPress(.return) {
            guard model.isConnected, !selection.goals.isEmpty else { return .ignored }
            run(model.maven.request(project.id)); return .handled
        }
    }
    private func moduleHeader(_ module: MavenModule) -> some View {
        HStack(spacing: 5) {
            Button { toggle(module.id, in: &expansion.collapsed) } label: {
                Image(systemName: expansion.collapsed.contains(module.id) ? "chevron.right" : "chevron.down").font(.system(size: 9)).frame(width: 12)
            }.buttonStyle(.plain)
            Text("m").font(.system(size: 12, weight: .heavy, design: .serif)).foregroundStyle(Theme.accent2)
            Text(module.displayTitle).font(.system(size: 12, weight: .medium)).lineLimit(1).layoutPriority(1)
            Text("(\(module.packaging))").foregroundStyle(Theme.text3)
            if let group = module.groupId { Text(group + ":" + module.artifactId).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.middle) }
            if module.parentOutside { Text("父 POM 在项目外").font(.system(size: 10)).foregroundStyle(Theme.amber).fixedSize() }
            if module.error != nil { Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.red) }
            Spacer(minLength: 0)
        }.font(.system(size: 11)).foregroundStyle(module.error == nil ? Theme.text : Theme.red)
            .padding(.leading, CGFloat(depth(module)) * 16).padding(.vertical, 5)
            .contentShape(Rectangle())
            .onTapGesture {
                guard model.isConnected, module.error == nil else { return }
                focused = true
                var selection = selection
                if selection.moduleId != module.id { selection.phases = [] }
                selection.moduleId = module.id
                model.maven.selections[model.maven.key(project.id)] = selection
            }
            .help([module.displayName, module.error, module.parentOutside ? "父 POM 在项目外" : nil, module.pomPath].compactMap { $0 }.joined(separator: "\n"))
    }
    private func lifecycle(_ module: MavenModule) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Button { toggle(module.id, in: &expansion.closedLifecycle) } label: {
                Label("Lifecycle", systemImage: expansion.closedLifecycle.contains(module.id) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.text2).frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain).padding(.vertical, 3)
            if !expansion.closedLifecycle.contains(module.id) {
                ForEach(MavenSelection.phases, id: \.self) { phase in
                    phaseRow(module, phase: phase)
                }
            }
        }.padding(.leading, CGFloat(depth(module) + 1) * 16 + 3)
    }
    private func phaseRow(_ module: MavenModule, phase: String) -> some View {
        let selected = selection.moduleId == module.id && selection.phases.contains(phase)
        return HStack(spacing: 6) {
            Image(systemName: "play").font(.system(size: 9)).foregroundStyle(selected ? Theme.accent2 : Theme.text3)
            Text(phase).font(.system(size: 11.5, design: .monospaced))
            Spacer(minLength: 0)
        }.padding(.horizontal, 8).padding(.vertical, 4)
            .background(selected ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                if !selected { select(module, phase: phase, additive: false) }
                run(model.maven.request(project.id))
            }
            .onTapGesture { select(module, phase: phase, additive: NSEvent.modifierFlags.contains(.command)) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .contextMenu {
                Button("运行") { run(contextRequest(module, phase: phase)) }
                Button("运行并跳过测试") { var request = contextRequest(module, phase: phase); request.skipTests = true; run(request) }
                Button("复制命令") { copy(CommandText.join(contextRequest(module, phase: phase).previewCommand(executable: maven.executable))) }
                Button("存为快捷操作") { save(contextRequest(module, phase: phase)) }
            }.disabled(!model.isConnected)
    }
    private var profiles: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { profilesOpen.toggle() } label: {
                Label("Profiles", systemImage: profilesOpen ? "chevron.down" : "chevron.right").font(.system(size: 12, weight: .medium))
            }.buttonStyle(.plain).padding(.top, 6)
            if profilesOpen {
                ForEach(maven.profiles, id: \.self) { profile in
                    let state = model.maven.profileStates[model.maven.key(project.id)]?[profile] ?? .default
                    Button { model.maven.cycleProfile(profile, projectId: project.id) } label: {
                        Label(profile, systemImage: state.symbol).font(.system(size: 11.5))
                            .foregroundStyle(state == .default ? Theme.text2 : state == .enabled ? Theme.accent2 : Theme.amber)
                    }.buttonStyle(.plain).padding(.leading, 18).padding(.vertical, 3)
                        .help("\(state.title)；点击切换为\(state.next.title)")
                        .accessibilityLabel("Profile \(profile)").accessibilityValue(state.title)
                        .disabled(!model.isConnected)
                }
            }
        }
    }
    private func select(_ module: MavenModule, phase: String, additive: Bool) {
        focused = true
        var selection = selection; selection.select(module: module.id, phase: phase, additive: additive)
        model.maven.selections[model.maven.key(project.id)] = selection
    }
    private func contextRequest(_ module: MavenModule, phase: String) -> MavenRunRequest {
        var request = model.maven.request(project.id)
        if selection.moduleId != module.id || !selection.phases.contains(phase) { request.moduleId = module.id; request.goals = [phase] }
        return request
    }
    private func toggle(_ id: String, in set: inout Set<String>) { if set.contains(id) { set.remove(id) } else { set.insert(id) } }
    private func ancestors(_ module: MavenModule) -> [String] {
        var result: [String] = []; var parent = module.parentId
        while let id = parent, !result.contains(id), result.count < maven.modules.count {
            result.append(id); parent = maven.modules.first { $0.id == id }?.parentId
        }
        return result
    }
    private func depth(_ module: MavenModule) -> Int { ancestors(module).count }
    private func visible(_ module: MavenModule) -> Bool { !ancestors(module).contains { expansion.collapsed.contains($0) } }
}
