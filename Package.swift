// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OtoLog",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "OtoLogCore", targets: ["OtoLogCore"]),
        .executable(name: "OtoLog", targets: ["OtoLogApp"]),
    ],
    dependencies: [
        // ライブラリビューワーの md レンダリング用。UI 層のみの依存で、OtoLogCore は外部依存ゼロを維持する
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.1"),
    ],
    targets: [
        .target(name: "OtoLogCore"),
        .executableTarget(
            name: "OtoLogApp",
            dependencies: [
                "OtoLogCore",
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ]
        ),
        .executableTarget(name: "otolog-devtool", dependencies: ["OtoLogCore"]),
        .testTarget(name: "OtoLogCoreTests", dependencies: ["OtoLogCore"]),
    ]
)
