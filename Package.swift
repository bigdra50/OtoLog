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
            ],
            // mermaid.js は同梱する。CDN から取ると図の描画にネットワークが要り、
            // オンデバイス完結という前提が崩れる
            resources: [.copy("Resources/mermaid.min.js")]
        ),
        .executableTarget(name: "otolog-devtool", dependencies: ["OtoLogCore"]),
        .testTarget(name: "OtoLogCoreTests", dependencies: ["OtoLogCore"]),
        // UI 層のレイアウト検証。ポップオーバーの実寸はホスティングして測るしかないため
        .testTarget(name: "OtoLogAppTests", dependencies: ["OtoLogApp", "OtoLogCore"]),
    ]
)
