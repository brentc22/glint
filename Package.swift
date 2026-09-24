// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Glint",
    platforms: [.macOS(.v14)],  // SCScreenshotManager
    targets: [
        .target(name: "GlintCore"),
        .executableTarget(name: "Glint", dependencies: ["GlintCore"]),
        // XCTest and swift-testing need Xcode; tests run as a plain executable.
        .executableTarget(name: "GlintTests", dependencies: ["GlintCore"]),
    ]
)
