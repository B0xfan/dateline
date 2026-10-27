// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Dateline",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "Dateline", path: "Sources/Dateline")]
)
