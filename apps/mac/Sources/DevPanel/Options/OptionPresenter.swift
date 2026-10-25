import DevPanelKit
import SwiftUI

@Observable @MainActor
final class OptionPresenter {
    enum Sheet: Identifiable {
        case add(Project), edit(OptionEditor), remove(Project, ParamConfig)
        var id: String {
            switch self {
            case .add(let p): "add-" + p.id
            case .edit(let e): "edit-" + String(describing: ObjectIdentifier(e))
            case .remove(let p, let param): "remove-" + p.id + param.key
            }
        }
    }
    let model: AppModel
    var sheet: Sheet?
    init(model: AppModel) { self.model = model }
    func add(_ id: ProjectID) { if let p = model.configs[id] { sheet = .add(p) } }
    func edit(_ id: ProjectID, key: String) {
        if let p = model.configs[id], let param = p.config.params?.first(where: { $0.key == key }) {
            sheet = .edit(OptionEditor(model: model, project: p, param: param))
        }
    }
    func remove(_ id: ProjectID, key: String) {
        if let p = model.configs[id], let param = p.config.params?.first(where: { $0.key == key }) { sheet = .remove(p, param) }
    }
}

struct OptionHost: ViewModifier {
    @Bindable var presenter: OptionPresenter
    @Environment(\.inlineSheets) private var inline
    func body(content: Content) -> some View {
        content.environment(presenter)
            .sheet(item: inline ? .constant(nil) : $presenter.sheet) { sheet in sheetContent(sheet) }
            .overlay {
                if inline, let sheet = presenter.sheet {
                    ZStack {
                        Color.black.opacity(0.28)
                        sheetContent(sheet).background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line2)).padding(24)
                    }
                }
            }
    }
    @ViewBuilder private func sheetContent(_ sheet: OptionPresenter.Sheet) -> some View {
        switch sheet {
        case .add(let p): AddOptionSheet(presenter: presenter, project: p).frame(width: 480)
        case .edit(let e): OptionEditCard(editor: e, close: { presenter.sheet = nil }).frame(width: 380)
        case .remove(let p, let param): DeleteOptionSheet(presenter: presenter, project: p, param: param).frame(width: 480)
        }
    }
}

struct DeleteOptionSheet: View {
    let presenter: OptionPresenter
    @State var project: Project
    let param: ParamConfig
    @State private var error: String?
    @State private var busy = false
    @Environment(EditorPresenter.self) private var projectEditor: EditorPresenter?
    private var current: ParamConfig { project.config.params?.first { $0.key == param.key } ?? param }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("删除选项「\(param.label)」？").font(.headline)
            if OptionRules.blocksInline(current) {
                Text("敏感选项被命令引用，不能将秘密写回命令。请先编辑项目，移除命令中的引用。").foregroundStyle(Theme.amber)
                Button("编辑项目…") { presenter.sheet = nil; projectEditor?.edit(project.id) }
            } else if !(current.usedBy ?? []).isEmpty {
                Text("当前值会写回以下引用；服务下次启动将使用写回后的配置。").foregroundStyle(Theme.text2)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(OptionRules.references(current, config: project.config, inline: true)) { ref in
                            Text(ref.location).foregroundStyle(Theme.text3)
                            Text(highlight(ref.segments)).textSelection(.enabled)
                                .font(.system(size: 12, design: .monospaced))
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: CGFloat(min(230, max(60, (current.usedBy ?? []).count * 70))))
            } else { Text("此选项没有被引用，删除不影响命令。") }
            if let error { Text(error).foregroundStyle(Theme.red) }
            HStack {
                Spacer()
                Button("取消") { presenter.sheet = nil }
                Button((current.usedBy ?? []).isEmpty ? "删除" : "删除并写回", role: .destructive) { Task { await remove() } }
                    .disabled(busy || !presenter.model.isConnected || OptionRules.blocksInline(current))
            }
        }.font(.system(size: 12.5)).padding(20)
    }
    private func highlight(_ segments: [CommandPreview.Segment]) -> AttributedString {
        var result = AttributedString()
        for segment in segments {
            var s = AttributedString(segment.text)
            s.foregroundColor = segment.kind == .text || segment.kind == .escaped ? Theme.text2 : Theme.green
            result += s
        }
        return result
    }
    private func remove() async {
        busy = true; defer { busy = false }
        do {
            _ = try await presenter.model.deleteOption(project.id, revision: project.revision, param: current)
            presenter.sheet = nil
        } catch {
            let e = error as? ApiError ?? .unreachable(error.localizedDescription)
            self.error = OptionRules.errorText(e)
            if e.code == .revisionMismatch || e.code == .paramUnknown {
                if let p = try? await presenter.model.fetchProject(project.id) { project = p }
            }
        }
    }
}
