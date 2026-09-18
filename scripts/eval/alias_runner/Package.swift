// swift-tools-version: 6.0
// AliasRunner — local dev tool for issue #637 alias-suggestion benchmark.
// Path-depends on the root EnviousWispr package so it reuses the shipped
// WordSuggestionService. NEVER built by root `swift build`. NEVER bundled.

import PackageDescription

let package = Package(
  name: "AliasRunner",
  platforms: [
    .macOS(.v14)
  ],
  dependencies: [
    .package(name: "EnviousWispr", path: "../../..")
  ],
  targets: [
    // #996: the `judge` subcommand's contract (corpus rows, candidate names,
    // outcome vocabulary, fixture executor). A library so it is testable; it
    // depends on no root product in Chunk 1. Real judges arrive in Chunk 2.
    .target(
      name: "AliasRunnerKit",
      path: "Sources/AliasRunnerKit"
    ),
    .executableTarget(
      name: "AliasRunner",
      dependencies: [
        "AliasRunnerKit",
        .product(name: "EnviousWisprCore", package: "EnviousWispr"),
        .product(name: "EnviousWisprPostProcessing", package: "EnviousWispr"),
      ],
      path: "Sources/AliasRunner"
    ),
    .testTarget(
      name: "AliasRunnerKitTests",
      dependencies: ["AliasRunnerKit"],
      path: "Tests/AliasRunnerKitTests"
    ),
  ],
  swiftLanguageModes: [.v6]
)
