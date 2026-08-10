// swift-tools-version: 6.0
// PromptRender — local dev tool: renders the REAL production polish prompt
// (system + user + mode) for a given provider/model over a JSONL corpus, by
// driving the shipped DefaultPromptPlanner. Path-depends on the root
// EnviousWispr package so it reuses the exact shipped builders. NEVER built by
// root `swift build`. NEVER bundled. Used to capture faithful prompt baselines
// for the cloud→one-fixed-prompt initiative (polish-prompt-architecture.md).

import PackageDescription

let package = Package(
  name: "PromptRender",
  platforms: [
    .macOS(.v14)
  ],
  dependencies: [
    .package(name: "EnviousWispr", path: "../../..")
  ],
  targets: [
    .executableTarget(
      name: "PromptRender",
      dependencies: [
        .product(name: "EnviousWisprCore", package: "EnviousWispr"),
        .product(name: "EnviousWisprLLM", package: "EnviousWispr"),
      ],
      path: "Sources/PromptRender"
    )
  ],
  swiftLanguageModes: [.v6]
)
