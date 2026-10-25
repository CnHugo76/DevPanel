import DevPanelKit
import SwiftUI

/// Targets of a "强制停止" waiting for confirmation.
struct ForceStopTarget: Identifiable, Equatable {
    var projectId: ProjectID
    var serviceIds: [ServiceID]?
    var id: String { projectId + "/" + (serviceIds?.joined(separator: ",") ?? "*") }
}

/// The "强制停止？" confirmation used by the overview (rows, project menu) and the inspector header.
struct ForceStopConfirmation: ViewModifier {
    let model: AppModel
    @Binding var target: ForceStopTarget?
    @Environment(\.isStale) private var stale

    func body(content: Content) -> some View {
        content.alert(
            "强制停止？", isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }),
            presenting: target
        ) { target in
            Button("强制停止", role: .destructive) {
                let request = ActionRequest(projectId: target.projectId, serviceIds: target.serviceIds, action: .forceStop)
                Task { await model.runAction(request) }
            }
            .disabled(stale)
            Button("取消", role: .cancel) {}
        } message: { target in
            Text(message(target) + "\n" + ForceStopText.note)
        }
    }

    private func message(_ target: ForceStopTarget) -> String {
        guard let p = model.project(target.projectId) else { return "" }
        let names = p.services
            .filter { (target.serviceIds?.contains($0.id) ?? true) && $0.currentRun != nil }
            .map(\.name)
        return ForceStopText.message(
            names: names,
            processCount: model.forceStopProcessCount(target.projectId, serviceIds: target.serviceIds),
            multiServiceProject: p.services.count > 1)
    }
}

extension View {
    func forceStopConfirmation(model: AppModel, target: Binding<ForceStopTarget?>) -> some View {
        modifier(ForceStopConfirmation(model: model, target: target))
    }
}
