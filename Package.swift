// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OrganicShell",
    platforms: [.macOS(.v26)],
    dependencies: [
        // The terminal's renderer (f163): the product's exact version (Tools' ToolsTerminalSurface adapts it).
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.99.1"),
    ],
    targets: [
        .executableTarget(name: "OrganicShell", dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
                          path: "Sources/OrganicShell"),
    ]
)
