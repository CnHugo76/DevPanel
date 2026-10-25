import DevPanelKit
import SwiftUI

/// Put dynamic items in Views: Commands itself does not track Observation dependencies.
struct AppCommands: Commands {
    let controller: AppController
    var body: some Commands {
        CommandGroup(after: .appInfo) { ApplicationMenuItems(controller: controller) }
        CommandGroup(replacing: .newItem) { FileMenuItems(controller: controller) }
        CommandMenu("项目") { ProjectMenuItems(controller: controller) }
        CommandMenu("服务") { ServiceMenuItems(controller: controller) }
        CommandGroup(after: .toolbar) { ViewMenuItems(controller: controller) }
    }
}

private struct ApplicationMenuItems: View {
    let controller: AppController
    var body: some View {
        Button("安装 CLI 与登录启动…") { controller.showWindow(); controller.showInstallation = true }
            .disabled(!controller.hasBundledCLI)
        Button("停止所有服务并退出管理服务…") { controller.showWindow(); controller.requestShutdown() }
            .disabled(!controller.model.isConnected || controller.shutdownBusy)
    }
}
private struct FileMenuItems: View {
    let controller: AppController
    var body: some View {
        Button("添加项目") { controller.showWindow(); controller.editor.openNew() }.keyboardShortcut("n")
            .disabled(!controller.model.isConnected)
        Button("编辑项目…") { if let id = controller.model.selectedProjectId { controller.showWindow(); controller.editor.edit(id) } }
            .disabled(!controller.model.isConnected || controller.model.selectedProjectId == nil)
        Button("移除项目…") { if let id = controller.model.selectedProjectId { controller.showWindow(); controller.editor.remove(id) } }
            .disabled(!controller.model.isConnected || controller.model.selectedProjectId == nil)
    }
}
private struct ServiceMenuItems: View {
    let controller: AppController
    var body: some View {
        Button(controller.toggleAction == .start ? "启动" : "停止") { if controller.toggleEnabled { controller.run(controller.toggleAction) } }
            .keyboardShortcut(.return).disabled(!controller.toggleEnabled)
        Button("重启") { controller.run(.restart) }.keyboardShortcut("r").disabled(!controller.enabled(.restart))
        Button("强制停止…") { controller.run(.forceStop) }.disabled(!controller.enabled(.forceStop))
        Divider()
        Button("打开日志") { if let ref = controller.model.selection { controller.showWindow(); controller.model.openLogs(ref) } }
            .keyboardShortcut("l").disabled(!controller.model.isConnected || controller.selected == nil)
    }
}
private struct ViewMenuItems: View {
    let controller: AppController
    var body: some View {
        Button(!controller.model.hasInspectorSelection ? "显示检查器" : "隐藏检查器") { controller.showWindow(); controller.toggleInspector() }
            .keyboardShortcut("i", modifiers: [.option, .command]).disabled(!controller.model.isConnected || controller.model.projects.isEmpty)
        Button(controller.prefs.detailed ? "切换到总览" : "切换到详情") {
            controller.showWindow()
            controller.prefs.detailed.toggle()
        }.keyboardShortcut("d", modifiers: [.option, .command])
        Button("搜索") { controller.showWindow(); controller.focusSearch() }.keyboardShortcut("f")
    }
}

private struct ProjectMenuItems: View {
    let controller: AppController
    private var project: ProjectView? { controller.model.selectedProjectId.flatMap { controller.model.project($0) } }
    var body: some View {
        Button("Maven") {
            if let ref = controller.model.selection { controller.showWindow(); controller.model.selectServiceTab(.maven, for: ref) }
            else if let project { controller.showWindow(); controller.model.selectProject(project.id, tab: .maven) }
        }.keyboardShortcut("m", modifiers: [.option, .command])
            .disabled(!controller.model.isConnected || (controller.model.selection.map { !controller.model.serviceTabs($0).contains(.maven) } ?? (project?.maven == nil)))
        Button("Git") { if let ref = controller.model.selection { controller.showWindow(); controller.model.selectServiceTab(.git, for: ref) }
            else if let project { controller.showWindow(); controller.model.selectProject(project.id, tab: .git) } }
            .keyboardShortcut("g", modifiers: [.option, .command]).disabled(!controller.model.isConnected || project == nil || (controller.model.selection.map { !controller.model.serviceTabs($0).contains(.git) } ?? false))
        Menu("运行快捷操作") {
            if let project {
                ForEach(project.actions) { action in
                    Button(action.name) { controller.showWindow(); controller.model.requestQuickAction(project.id, actionId: action.id) }
                        .disabled(action.currentRun != nil)
                }
            }
        }.disabled(!controller.model.isConnected || project?.actions.isEmpty != false)
        Button("取消运行中的任务") {
            guard let project else { return }
            Task {
                for run in project.actions.compactMap(\.currentRun) + [project.maven?.currentRun].compactMap({ $0 }) { await controller.model.cancelTask(run) }
            }
        }.disabled(!controller.model.isConnected || !(project?.actions.contains { $0.currentRun != nil } ?? false) && project?.maven?.currentRun == nil)
    }
}
