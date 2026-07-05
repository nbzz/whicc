// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "whicc-macui",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "whicc-macui",
            path: "Sources/macui"
        ),
    ]
)
