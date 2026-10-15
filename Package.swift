// swift-tools-version:5.9
import PackageDescription

// Exists so SourceKit-LSP (VS Code Swift extension) resolves types across files.
// The runnable app is still built via build.sh / the swiftc one-liner.
let package = Package(
    name: "TopBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "TopBar", path: "Sources")
    ]
)
