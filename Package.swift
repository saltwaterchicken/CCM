// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CardIngest",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CardIngest", targets: ["CardIngest"]),
        .library(name: "CardIngestCore", targets: ["CardIngestCore"]),
    ],
    targets: [
        // All the logic that can be tested without a window: settings, templates,
        // and later copy, verify, rename and safety checks.
        .target(name: "CardIngestCore"),
        // The SwiftUI app itself. Kept thin; it calls into CardIngestCore.
        .executableTarget(name: "CardIngest", dependencies: ["CardIngestCore"]),
        .testTarget(name: "CardIngestCoreTests", dependencies: ["CardIngestCore"]),
    ]
)
