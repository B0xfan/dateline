// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Dateline",
    platforms: [.macOS(.v14), .iOS(.v17), .watchOS(.v10)],
    products: [.library(name: "DatelineCore", targets: ["DatelineCore"])],   // gives xcodebuild a DatelineCore scheme for the iOS CI check
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],   // self-update from GitHub Releases; embedded by scripts/make-app.sh
    targets: [
        // the logic shared with the iPhone and watch apps: sentences, repeats, calendar files, the store, accounts, weather, drive times, alerts, license. No screens, no Mac-only code.
        .target(name: "DatelineCore", path: "Sources/DatelineCore"),
        .executableTarget(name: "Dateline", dependencies: ["DatelineCore", .product(name: "Sparkle", package: "Sparkle")], path: "Sources/Dateline",
                                // the app bundle keeps Sparkle.framework in Contents/Frameworks; the bare built program (--selftest, --render) finds it beside itself
                                linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks", "-Xlinker", "-rpath", "-Xlinker", "@executable_path"])])
    ]
)
