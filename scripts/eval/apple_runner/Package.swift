// swift-tools-version: 6.0
// AppleIntelligencePolishRunner — local dev tool for issue #372 polish benchmark.
// Path-depends on the root EnviousWispr package so it reuses the shipped
// AppleIntelligenceConnector. NEVER built by root `swift build`. NEVER bundled.

import PackageDescription

let package = Package(
  name: "AppleIntelligenceRunner",
  platforms: [
    .macOS(.v14)
  ],
  dependencies: [
    .package(name: "EnviousWispr", path: "../../..")
  ],
  targets: [
    .executableTarget(
      name: "AppleIntelligenceRunner",
      dependencies: [
        .product(name: "EnviousWisprCore", package: "EnviousWispr"),
        .product(name: "EnviousWisprLLM", package: "EnviousWispr"),
      ],
      path: "Sources/AppleIntelligenceRunner"
    )
  ],
  swiftLanguageModes: [.v6]
)
