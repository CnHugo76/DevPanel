import DevPanelKit
import SwiftUI

/// Right-hand inspector container (ui-design v2 §4): `InspectorView` (Inspector/), width
/// 380–640 (default 470), dragged on its leading edge, remembered.
struct InspectorContainer: View {
    let model: AppModel
    let prefs: ViewPreferences
    let ref: ServiceRef?
    var project: ProjectView? = nil
    let width: CGFloat

    @State private var dragStart: Double?

    var body: some View {
        Group {
            if let ref { InspectorView(model: model, ref: ref) }
            else if let project { ProjectInspectorView(model: model, project: project) }
        }
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .background(Theme.bar)
            .overlay(alignment: .leading) {
                Rectangle().fill(Theme.line).frame(width: 1)
            }
            .overlay(alignment: .leading) { if !prefs.detailed { resizeHandle } }
    }

    private var resizeHandle: some View {
        Color.clear
            .frame(width: 6)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStart ?? Double(width)
                        if dragStart == nil { dragStart = start }
                        if project != nil { prefs.setProjectInspectorWidth(start - Double(value.translation.width)) }
                        else { prefs.setInspectorWidth(start - Double(value.translation.width)) }
                    }
                    .onEnded { _ in
                        dragStart = nil
                        if project != nil { prefs.commitProjectInspectorWidth() } else { prefs.commitInspectorWidth() }
                    })
            .offset(x: -3)
            .help("拖动调整宽度")
    }
}
