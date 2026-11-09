// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MediaSherpa",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MediaSherpa", targets: ["MediaSherpa"]),
        .library(name: "MediaSherpaCore", targets: ["MediaSherpaCore"]),
    ],
    targets: [
        // All the logic that can be tested without a window: settings, templates,
        // and later copy, verify, rename and safety checks.
        .target(name: "MediaSherpaCore"),
        // The SwiftUI app itself. Kept thin; it calls into MediaSherpaCore.
        .executableTarget(name: "MediaSherpa", dependencies: ["MediaSherpaCore"]),
        // Scores folders of culled photos, for calibrating auto-rating. Only reads them.
        .executableTarget(name: "score-folder", dependencies: ["MediaSherpaCore"]),
        .testTarget(name: "MediaSherpaCoreTests", dependencies: ["MediaSherpaCore"]),
    ]
)
