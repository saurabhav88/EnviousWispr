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
    .package(name: "EnviousWispr", path: "../../.."),
    // #996 chunk 2b-ii (founder decision 2026-09-18, option 1): the upstream
    // Hugging Face tokenizer, RUNNER ONLY, to measure parity for the
    // cross-encoder candidates. The app keeps its Argmax dependency until
    // this proves exact multilingual parity. Pinned to an exact tag; CI pins
    // it and its transitive graph through Package.runner-only-pins.json
    // (scripts/ci/compile-eval-packages.sh), since the app's pins lack it.
    .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.4"),
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
        // #996 chunk 2b: the tokenizer-parity door for the edit-judge
        // compatibility probe lives in LLM (`CorrectionJudgeBenchmark`).
        .product(name: "EnviousWisprLLM", package: "EnviousWispr"),
        .product(name: "Tokenizers", package: "swift-transformers"),
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
