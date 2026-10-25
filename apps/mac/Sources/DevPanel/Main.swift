import AppKit
import DevPanelKit
import Foundation

/// Entry point: `--self-check` runs headless (no window), `--snapshot` renders a PNG and exits;
/// otherwise the SwiftUI app.
@main
@MainActor
enum Main {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--self-check") {
            Task { @MainActor in
                let code = await SelfCheck.run(arguments: arguments)
                exit(code)
            }
            dispatchMain()
        } else if arguments.contains("--snapshot") {
            Snapshot.main(arguments: arguments)
        } else {
            DevPanelApp.main()
        }
    }
}
