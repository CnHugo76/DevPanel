import DevPanelKit
import SwiftUI

/// UI-only state of one editor sheet (collapsed cards, open "高级" sections, scroll request).
@Observable
@MainActor
final class EditorViewState {
    var collapsed: Set<UUID> = []
    var advancedOpen: Set<UUID> = []
    var projectEnvOpen = false
    /// Scroll target requested from outside (snapshot): `bottom`, `top` or a card ID string.
    var scrollTarget: String?
    /// Card IDs whose ID change the user already confirmed (value: the confirmed ID).
    var confirmedIdChanges: [UUID: String] = [:]

    init(editor: ProjectEditor) {
        let services = editor.draft.services
        if services.count > 2 { collapsed = Set(services.dropFirst().map(\.id)) }
        projectEnvOpen = !editor.draft.env.isEmpty
    }
}

/// Opens the add / edit project sheet and the remove confirmation, and shows the result toast.
/// One per window; reachable from any view through the environment.
@Observable
@MainActor
final class EditorPresenter {
    enum Sheet: Identifiable {
        case editor(ProjectEditor, EditorViewState)
        case remove(ProjectID)
        case portable(PortableConfigSession)

        var id: String {
            switch self {
            case .editor(let e, _): "editor-" + (e.mode.projectId ?? "new")
            case .remove(let id): "remove-" + id
            case .portable: "portable"
            }
        }
    }

    struct Toast: Equatable {
        enum Tone { case ok, info, warn }
        var tone: Tone
        var text: String
        /// Stays until closed (important messages such as kept option values).
        var sticky = false
        var id = UUID()
    }

    let model: AppModel
    var sheet: Sheet?
    var toast: Toast?
    var revealProject: ProjectID?
    var revealGeneration = 0

    init(model: AppModel) { self.model = model }

    /// "＋ 添加项目" (⌘N).
    func openNew() {
        guard sheet == nil else { return }
        let editor = ProjectEditor(model: model, mode: .create)
        sheet = .editor(editor, EditorViewState(editor: editor))
    }

    /// "编辑项目…": the sheet shows "正在读取配置…" until the config is there.
    func edit(_ id: ProjectID) {
        guard sheet == nil else { return }
        let editor = ProjectEditor(model: model, mode: .edit(id))
        let state = EditorViewState(editor: editor)
        sheet = .editor(editor, state)
        Task {
            await editor.load()
            let fresh = EditorViewState(editor: editor)
            state.collapsed = fresh.collapsed
            state.projectEnvOpen = fresh.projectEnvOpen
        }
    }

    /// "移除项目…".
    func remove(_ id: ProjectID) {
        guard sheet == nil else { return }
        sheet = .remove(id)
    }

    func portable(_ mode: PortableConfigSession.Mode) {
        guard sheet == nil else { return }
        let model = model
        let environment = PortableConfigSession.Environment(
            projects: { @MainActor in
                guard model.isConnected, let client = model.client else { throw ApiError.unreachable("管理服务未连接") }
                return try await client.projects()
            },
            project: { try await model.fetchProject($0) },
            validate: { try await model.validateConfig($0) },
            register: { try await model.registerProject($0) },
            update: { try await model.updateProject($0, ifRevision: $1, config: $2) })
        sheet = .portable(PortableConfigSession(mode: mode, environment: environment))
    }

    func close() { sheet = nil }

    /// Reveals a project in the overview: selects its first service (inspector opens).
    func locate(_ id: ProjectID) {
        revealProject = id; revealGeneration += 1
        if let first = model.project(id)?.services.first {
            model.select(ServiceRef(id, first.id))
        }
    }

    func show(_ toast: Toast) {
        self.toast = toast
        guard !toast.sticky else { return }
        let id = toast.id
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            if self?.toast?.id == id { self?.toast = nil }
        }
    }

    /// After a successful save: close the sheet and say what happened.
    func finish(_ outcome: EditorSaveOutcome, editor: ProjectEditor) {
        sheet = nil
        switch outcome {
        case .created(let p):
            show(Toast(tone: .ok, text: "已添加项目 \(p.config.name) · 未启动"))
        case .alreadyRegistered(let p):
            locate(p.id)
            show(Toast(tone: .info, text: "已存在相同配置的项目「\(p.config.name)」，已为你定位到它。"))
        case .updated(let p, let kept):
            let base = editor.isRunning ? "已保存 · 下次启动时生效，不会自动重启" : "已保存"
            if kept.isEmpty {
                show(Toast(tone: .ok, text: base))
            } else {
                show(Toast(
                    tone: .warn,
                    text: "\(base)。以下选项保留了你之前设置的值：\(editor.keptValuesText(kept, project: p))",
                    sticky: true))
            }
        }
    }
}

/// Snapshots render sheets inline (a real sheet is a separate window `cacheDisplay` cannot see).
struct InlineSheetsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var inlineSheets: Bool {
        get { self[InlineSheetsKey.self] }
        set { self[InlineSheetsKey.self] = newValue }
    }
}

/// Attaches the presenter's sheets and toast to the window content.
struct EditorHost: ViewModifier {
    let presenter: EditorPresenter
    @Environment(\.inlineSheets) private var inline
    @State private var windowHeight: CGFloat = 760

    func body(content: Content) -> some View {
        let maxHeight = max(360, windowHeight - 40)
        content
                .environment(presenter)
                .background {
                    GeometryReader { g in
                        Color.clear
                            .onAppear { windowHeight = g.size.height }
                            .onChange(of: g.size.height) { _, h in windowHeight = h }
                    }
                }
                .overlay(alignment: .bottom) { toast }
                .sheet(item: inline ? .constant(nil) : sheetBinding) { sheet in
                    sheetContent(sheet, maxHeight: maxHeight)
                }
                .overlay {
                    if inline, let sheet = presenter.sheet {
                        ZStack(alignment: .top) {
                            Color.black.opacity(0.28)
                            sheetContent(sheet, maxHeight: maxHeight - 24)
                                .background(Theme.card)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line2))
                                .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
                                .padding(.top, 12)
                        }
                    }
                }
    }

    private var sheetBinding: Binding<EditorPresenter.Sheet?> {
        Binding(get: { presenter.sheet }, set: { presenter.sheet = $0 })
    }

    @ViewBuilder private func sheetContent(_ sheet: EditorPresenter.Sheet, maxHeight: CGFloat) -> some View {
        switch sheet {
        case .editor(let editor, let state):
            ProjectEditorSheet(presenter: presenter, editor: editor, state: state)
                .frame(width: 700, height: min(maxHeight, 760))
        case .remove(let id):
            RemoveProjectSheet(presenter: presenter, model: presenter.model, projectId: id)
                .frame(width: 460)
        case .portable(let session):
            PortableConfigSheet(session: session, presenter: presenter)
                .frame(width: 740, height: min(maxHeight, 720))
        }
    }

    @ViewBuilder private var toast: some View {
        if let t = presenter.toast {
            let c = colors(t.tone)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HuggingWidth(max: 540) {
                    Text(t.text)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.text)
                }
                Button {
                    presenter.toast = nil
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.text3)
                        .frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("关闭")
                .accessibilityLabel("关闭提示")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.card)
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(c.bg)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(c.border))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
            .padding(.bottom, 18)
            .accessibilityElement(children: .combine)
        }
    }

    private func colors(_ tone: EditorPresenter.Toast.Tone) -> (fg: Color, bg: Color, border: Color) {
        switch tone {
        case .ok: Theme.colors(.green)
        case .info: Theme.colors(.blue)
        case .warn: Theme.colors(.amber)
        }
    }
}

extension View {
    func editorHost(_ presenter: EditorPresenter) -> some View { modifier(EditorHost(presenter: presenter)) }
}

/// Proposes at most `max` points of width and takes the child's own size (a `frame(maxWidth:)`
/// would always take the full `max`): short toasts hug their text, long ones wrap.
struct HuggingWidth: Layout {
    var max: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let width = Swift.min(proposal.width ?? max, max)
        return child.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
