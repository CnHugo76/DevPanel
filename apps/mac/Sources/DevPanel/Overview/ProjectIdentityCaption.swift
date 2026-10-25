import DevPanelKit
import SwiftUI

/// Display grouping always travels with the independent directory and project ID.
struct ProjectIdentityCaption: View {
    let project: ProjectView
    var body: some View {
        if let instance = project.instance {
            VStack(alignment: .leading, spacing: 3) {
                Text("实例 · " + instance.displayText)
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.accent2)
                    .lineLimit(2).help(instance.displayText)
                Text(Format.tildePath(project.root))
                    .lineLimit(1).truncationMode(.middle).help(project.root)
                Text("项目 ID · " + project.id).lineLimit(1).help(project.id)
            }
            .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.text3)
            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }
    }
}
