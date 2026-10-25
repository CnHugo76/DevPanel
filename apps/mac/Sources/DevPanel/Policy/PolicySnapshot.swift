import DevPanelKit
import SwiftUI

/// 与生产 sheet 共用内容；仅在隔离的 --snapshot 渲染中内联展示。
struct PolicySnapshotHost: ViewModifier {
    let model: AppModel
    @Environment(\.inlineSheets) private var inline
    func body(content: Content) -> some View {
        content.overlay {
            let process = ProcessInfo.processInfo
            if inline, process.environment["DEVPANEL_HOME"] != nil,
               let id = AppSnapshot.value("--policy-project", process.arguments),
               let project = model.project(id) {
                ZStack {
                    Color.black.opacity(0.28)
                    PolicySheet(model: model, project: project)
                        .background(Theme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line2))
                        .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
                }
            }
        }
    }
}
