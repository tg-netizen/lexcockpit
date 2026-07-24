// swift-tools-version: 5.9
// LexCockpit — SwiftUI macOS app, buildable two ways:
//   1. `swift run` (this manifest; used for development + verification)
//   2. Drag sources into an Xcode app project (README flow) — unchanged.
// No third-party packages: URLSession + Security + WebKit only.
import PackageDescription

let package = Package(
    name: "LexCockpit",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "LexCockpit",
            path: "LexCockpit",
            resources: [.copy("Resources/projects.json")]
        )
    ]
)
