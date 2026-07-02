// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CmdMD",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CmdMD", targets: ["CmdMD"])
    ],
    dependencies: [
        // Markdown parsing (GitHub-Flavored: tables, strikethrough, task lists)
        .package(url: "https://github.com/apple/swift-markdown.git", from: "0.6.0"),
        // Syntax highlighting for code blocks
        .package(url: "https://github.com/raspu/Highlightr.git", from: "2.3.0"),
        // YAML parsing for frontmatter
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.4.0"),
    ],
    targets: [
        .executableTarget(
            name: "CmdMD",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
                "Highlightr",
                "Yams",
            ],
            path: "Sources",
            resources: [
                // KaTeX·Mermaid 로컬 번들(인라인 주입용). 빌드 시 CmdMD_CmdMD.bundle/web/…로 복사된다.
                .copy("Resources/web")
            ],
            linkerSettings: [
                // SwiftUI VideoPlayer는 _AVKit_SwiftUI 오버레이만 자동 링크되고 AVKit 본체가 빠져
                // 런타임에 AVPlayerView 수퍼클래스 디맹글 실패로 크래시한다 — 명시 링크 필수.
                .linkedFramework("AVKit")
            ]
        ),
        .testTarget(
            name: "CmdMDTests",
            dependencies: ["CmdMD"],
            path: "Tests/CmdMDTests"
        ),
    ]
)
