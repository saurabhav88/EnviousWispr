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
    .executableTarget(
      name: "AliasRunner",
      dependencies: [
        .product(name: "EnviousWisprCore", package: "EnviousWispr"),
        .product(name: "EnviousWisprPostProcessing", package: "EnviousWispr"),
      ],
      path: "Sources/AliasRunner"
    )
  ],
  swiftLanguageModes: [.v6]
)
