// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AIChatApp",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        // MarkdownUI: GFM markdown rendering (tables, headings, code, etc.)
        // Vendored locally (Vendor/) so the project builds fully offline on any
        // architecture without flaky network fetches at build time.
        .package(path: "Vendor/swift-markdown-ui"),
        // SwiftMath: native LaTeX typesetting (iosMath Swift port, bundled math
        // fonts) used to render `$...$` / `$$...$$` math returned by AI models.
        .package(path: "Vendor/SwiftMath")
    ],
    targets: [
        .executableTarget(
            name: "AIChatApp",
            dependencies: [
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "SwiftMath", package: "SwiftMath")
            ],
            path: "Sources/AIChatApp",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)