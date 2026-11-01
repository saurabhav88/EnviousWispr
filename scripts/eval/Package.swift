// swift-tools-version: 6.0
// EvalRunners — the three local eval CLIs as ONE package, so the root
// EnviousWispr graph compiles once for all of them (#4293). Before, each runner
// was its own package with its own `.build`, and a full local test run compiled
// the app's code three extra times (121-286 s, ~13 GB per worktree).
//
//   AppleIntelligenceRunner  issue #372 polish benchmark (shipped AppleIntelligenceConnector)
//   AliasRunner (+Kit)       issue #637 alias-suggestion benchmark and the #996 judge
//   PromptRender             renders the real production polish prompt over a corpus
//
// Path-depends on the root package. NEVER built by root `swift build`. NEVER bundled.
// Build: `swift build -c release --package-path scripts/eval`. Binaries: the path
// printed by `swift build -c release --package-path scripts/eval --show-bin-path`;
// every gate resolves it through scripts/eval/eval_bin.py. CI compile check:
// scripts/ci/compile-eval-packages.sh.

import PackageDescription

let package = Package(
  name: "EvalRunners",
  platforms: [
    .macOS(.v14)
  ],
  dependencies: [
    .package(name: "EnviousWispr", path: "../.."),
    // #996 chunk 2b-ii (founder decision 2026-09-18, option 1): the upstream
    // Hugging Face tokenizer, RUNNER ONLY, to measure parity for the
    // cross-encoder candidates. The app keeps its Argmax dependency until
    // this proves exact multilingual parity. Pinned to an exact tag; its
    // transitive graph is pinned through Package.runner-only-pins.json
    // (scripts/ci/compile-eval-packages.sh), since the app's pins lack it.
    .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.4"),
  ],
  targets: [
    .executableTarget(
      name: "AppleIntelligenceRunner",
      dependencies: [
        .product(name: "EnviousWisprCore", package: "EnviousWispr"),
        .product(name: "EnviousWisprLLM", package: "EnviousWispr"),
        .product(name: "EnviousWisprPipeline", package: "EnviousWispr"),
        .product(name: "EnviousWisprPostProcessing", package: "EnviousWispr"),
      ],
      path: "apple_runner/Sources/AppleIntelligenceRunner"
    ),
    // #996: the `judge` subcommand's contract (corpus rows, candidate names,
    // outcome vocabulary, fixture executor). A library so it is testable.
    .target(
      name: "AliasRunnerKit",
      path: "alias_runner/Sources/AliasRunnerKit"
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
      path: "alias_runner/Sources/AliasRunner"
    ),
    .testTarget(
      name: "AliasRunnerKitTests",
      dependencies: ["AliasRunnerKit"],
      path: "alias_runner/Tests/AliasRunnerKitTests"
    ),
    .executableTarget(
      name: "PromptRender",
      dependencies: [
        .product(name: "EnviousWisprCore", package: "EnviousWispr"),
        .product(name: "EnviousWisprLLM", package: "EnviousWispr"),
      ],
      path: "prompt_render/Sources/PromptRender"
    ),
  ],
  swiftLanguageModes: [.v6]
)
