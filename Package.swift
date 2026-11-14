// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "setPilot",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "setPilot", path: "Sources")]
)
