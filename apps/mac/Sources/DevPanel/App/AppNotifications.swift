import AppKit
import DevPanelKit
import UserNotifications

/// macOS delivery only; selection and de-duplication policy live in DevPanelKit.
@MainActor final class AppNotifications: NSObject, UNUserNotificationCenterDelegate {
    private weak var controller: AppController?
    private var tracker = NotificationTracker()
    private var readyTracker = ReadyNotificationTracker()
    private var taskTracker = TaskNotificationTracker()
    private var center: UNUserNotificationCenter?
    init(controller: AppController) { self.controller = controller }
    func start() {
        if Bundle.main.bundleURL.pathExtension == "app" {
            center = .current(); center?.delegate = self
        }
        controller?.model.eventObserver = { [weak self] event in self?.receive(event) }
    }
    private func receive(_ event: DaemonEvent) {
        guard let controller else { return }
        controller.resolveNotification()
        let count = controller.model.abnormalServiceCount
        NSApp.dockTile.badgeLabel = count == 0 ? nil : String(count)
        for notice in tracker.consume(event) + taskTracker.consume(event, foreground: NSApp.isActive && controller.window?.isVisible == true) + readyTracker.consume(event, foreground: NSApp.isActive && controller.window?.isVisible == true) {
            Task { await deliver(notice) }
        }
    }
    private func deliver(_ notice: ServiceNotice) async {
        guard let center else { return }
        do {
            // Bridge the callbacks so older SDKs never send non-Sendable
            // notification objects across the main actor boundary.
            let authorizationStatus: UNAuthorizationStatus = await withCheckedContinuation { continuation in
                center.getNotificationSettings { @Sendable settings in
                    continuation.resume(returning: settings.authorizationStatus)
                }
            }
            let allowed: Bool
            if authorizationStatus == .notDetermined {
                allowed = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, any Error>) in
                    center.requestAuthorization(options: [.alert, .sound, .badge]) { @Sendable granted, error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume(returning: granted) }
                    }
                }
            } else { allowed = authorizationStatus == .authorized || authorizationStatus == .provisional }
            guard allowed else { return }
            let content = UNMutableNotificationContent()
            content.title = notice.title; content.body = notice.body; content.sound = .default
            switch notice.ref {
            case .service(let ref): content.userInfo = ["projectId": ref.projectId, "serviceId": ref.serviceId]
            case .task(let ref):
                switch ref.target {
                case .maven: content.userInfo = ["projectId": ref.projectId, "kind": "maven"]
                case .action(let id): content.userInfo = ["projectId": ref.projectId, "kind": "action", "actionId": id]
                }
            }
            let request = UNNotificationRequest(identifier: notice.id, content: content, trigger: nil)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                center.add(request) { @Sendable error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        } catch {
            controller?.editor.show(.init(tone: .warn, text: "系统通知未发送：\(error.localizedDescription)"))
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let p = info["projectId"] as? String {
            let kind = info["kind"] as? String, actionId = info["actionId"] as? String, serviceId = info["serviceId"] as? String
            Task { @MainActor [weak self] in
                guard let controller = self?.controller else { return }
                if kind == "action", let actionId {
                    controller.showWindow(); controller.model.selectProject(p, tab: .actions)
                    controller.model.projectInspector.actionChoice[p] = actionId
                } else if kind == "maven" {
                    controller.showWindow(); controller.model.selectProject(p, tab: .maven)
                } else if let serviceId { controller.openNotification(ServiceRef(p, serviceId)) }
            }
        }
        completionHandler()
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
