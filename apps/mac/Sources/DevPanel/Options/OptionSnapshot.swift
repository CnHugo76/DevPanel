import DevPanelKit
import Foundation

/// Uses the very same editor/save path as a click. Always run against an isolated home.
@MainActor enum OptionSnapshot {
    static func apply(_ args: [String], model: AppModel, presenter: OptionPresenter) async throws {
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }; return args[i + 1]
        }
        if let id = value("--add-option") { presenter.add(id) }
        if let target = value("--option") ?? value("--delete-option") {
            let parts = target.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { throw SnapshotError("选项参数需要 projectId/key") }
            if value("--delete-option") != nil {
                presenter.remove(parts[0], key: parts[1])
                if args.contains("--confirm-delete"), case .remove(let p, let param) = presenter.sheet {
                    _ = try await model.deleteOption(p.id, revision: p.revision, param: param)
                    presenter.sheet = nil
                }
            } else {
                presenter.edit(parts[0], key: parts[1])
                if case .edit(let e) = presenter.sheet {
                    if args.contains("--option-bump"), let p = model.configs[parts[0]] {
                        _ = try await model.patchOption(parts[0], key: parts[1], request: PatchParamRequest(ifRevision: p.revision, label: e.param.label + " · 外部编辑"))
                    }
                    if let text = value("--option-value") { e.text = text }
                    if args.contains("--option-save") { await e.save() }
                    if args.contains("--option-close") { presenter.sheet = nil }
                }
            }
        }
    }
}
