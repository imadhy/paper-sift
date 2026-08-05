// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PaperSift",
    platforms: [.macOS(.v15)],
    targets: [
        // Everything that can be exercised without a window lives here: the
        // store, the query parser, the ranker, the extractors, the OCR pipeline.
        .target(name: "PaperSiftCore"),
        // SwiftUI shell + the `--index` / `--search` / `--stats` CLI harness.
        .executableTarget(name: "PaperSift", dependencies: ["PaperSiftCore"]),
        // The test suite, as an executable rather than a `.testTarget`: neither
        // `Testing` nor `XCTest` ships with the Command Line Tools, and this
        // project stays buildable without Xcode. Run it with
        // `swift run PaperSiftCheck`.
        .executableTarget(name: "PaperSiftCheck", dependencies: ["PaperSiftCore"]),
    ]
)
