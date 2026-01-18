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
        // Markdown parsing
        .package(url: "https://github.com/apple/swift-markdown.git", from: "0.3.0"),
        // Syntax highlighting for code blocks
        .package(url: "https://github.com/raspu/Highlightr.git", from: "2.1.2"),
        // YAML parsing for frontmatter
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.6"),
    ],
    targets: [
        .executableTarget(
            name: "CmdMD",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
                "Highlightr",
                "Yams",
            ],
            path: "Sources"
        ),
    ]
)
