import DevPanelKit
import SwiftUI

/// "移除项目" confirmation (ui-design §7). Removing only drops DevPanel's config, runs and logs;
/// nothing under the root is touched. Disabled while any service is starting / running /
/// stopping / unknown (the daemon would answer PROJECT_RUNNING).
struct RemoveProjectSheet: View {
    let presenter: EditorPresenter
    let model: AppModel
    let projectId: ProjectID

    @State private var removing = false
    @State private var error: ApiError?

    var body: some View {
        let project = model.project(projectId)
        let check = project.map(RemovalCheck.init)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "trash")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.red)
                    .frame(width: 36, height: 36)
                    .background(Theme.redSoft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("移除项目「\(project?.name ?? projectId)」？")
                        .font(.system(size: 14, weight: .semibold))
                    if let project {
                        Text(RemovalCheck.message(root: project.root))
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("项目的运行记录与日志会一并删除。之后可以重新添加。")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.text3)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("这个项目已不在列表中。").font(.system(size: 12.5)).foregroundStyle(Theme.text2)
                    }
                }
            }
            if let reason = check?.blockedReason {
                HintBox(tone: .amber, text: reason)
            }
            if let error {
                HintBox(tone: .red, text: "\(error.message)（\(error.code.rawValue)）")
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                SheetButton(title: "取消") { presenter.close() }
                    .keyboardShortcut(.cancelAction)
                SheetButton(
                    title: removing ? "正在移除…" : "移除", kind: .danger,
                    enabled: check?.allowed == true && !removing && model.isConnected, action: remove
                )
                .help(check?.blockedReason ?? (model.isConnected ? "从 DevPanel 移除" : Copy.staleReason))
            }
        }
        .padding(20)
        .background(Theme.card)
        .foregroundStyle(Theme.text)
    }

    private func remove() {
        removing = true
        error = nil
        Task {
            do {
                let name = model.project(projectId)?.name ?? projectId
                try await model.removeProject(projectId)
                presenter.close()
                presenter.show(.init(tone: .ok, text: "已从 DevPanel 移除「\(name)」，项目文件未改动"))
            } catch let e as ApiError {
                error = e
            } catch {
                self.error = ApiError(code: .internal, message: error.localizedDescription)
            }
            removing = false
        }
    }
}

/// A tinted box with a message.
struct HintBox: View {
    let tone: DisplayTone
    let text: String

    var body: some View {
        let c = Theme.colors(tone)
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.text)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(c.bg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(c.border))
            .textSelection(.enabled)
    }
}
