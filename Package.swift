// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Seer",
    platforms: [.macOS(.v14)],
    // Last tree-sitter release that ships a Package.swift; runtime supports grammar ABI 13-15.
    dependencies: [.package(url: "https://github.com/tree-sitter/tree-sitter", exact: "0.25.10")],
    targets: [
        .target(name: "SeerCore", dependencies: [.product(name: "TreeSitter", package: "tree-sitter")]),
        .executableTarget(name: "Seer", dependencies: ["SeerCore"]),
        // Command Line Tools ship the swift-testing macro plugin outside the default plugin path.
        .testTarget(
            name: "SeerCoreTests",
            dependencies: ["SeerCore"],
            swiftSettings: [.unsafeFlags(["-plugin-path", "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"])]
        ),
    ],
    swiftLanguageModes: [.v5]
)
