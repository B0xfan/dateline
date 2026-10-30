// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Dateline",
    platforms: [.macOS(.v14)],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],   // self-update from GitHub Releases; embedded by scripts/make-app.sh
    targets: [.executableTarget(name: "Dateline", dependencies: [.product(name: "Sparkle", package: "Sparkle")], path: "Sources/Dateline",
                                // the app bundle keeps Sparkle.framework in Contents/Frameworks; the bare built program (--selftest, --render) finds it beside itself
                                linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks", "-Xlinker", "-rpath", "-Xlinker", "@executable_path"])])]
)
