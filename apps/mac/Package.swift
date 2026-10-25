// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DevPanel",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DevPanel", targets: ["DevPanel"]),
        .library(name: "DevPanelKit", targets: ["DevPanelKit"]),
    ],
    targets: [
        // Models (contract types), networking, state. No SwiftUI views.
        .target(
            name: "DevPanelKit",
            path: "Sources/DevPanelKit"
        ),
        // The SwiftUI app shell. `DevPanel --self-check` runs headless.
        .executableTarget(
            name: "DevPanel",
            dependencies: ["DevPanelKit"],
            path: "Sources/DevPanel"
        ),
        .testTarget(
            name: "DevPanelKitTests",
            dependencies: ["DevPanelKit"],
            path: "Tests/DevPanelKitTests",
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
