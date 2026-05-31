import Foundation

@testable import EnviousWisprLLM

/// Locates the SHIPPED classifier artifacts and committed test fixtures from
/// disk via `#filePath` (this file lives at
/// `<repo>/Tests/EnviousWisprTests/LLM/OutputClassifierTestSupport.swift`).
///
/// The model + tokenizer are app-target resources (`Bundle.main`), not in the
/// unit-test bundle, so the build-time gates read them directly from the repo.
/// `#filePath` is the compile-time absolute source path inside whatever checkout
/// is being built, so this resolves correctly on the dev machine and CI alike.
enum OutputClassifierTestPaths {
  /// `<repo>` — four parents up from this file (LLM → EnviousWisprTests → Tests → repo).
  static let repoRoot: URL = URL(filePath: #filePath)
    .deletingLastPathComponent()  // LLM
    .deletingLastPathComponent()  // EnviousWisprTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // repo root

  static let tokenizerFolder = repoRoot.appending(
    path: "Sources/EnviousWisprLLM/Resources/OutputClassifierTokenizer")
  static let tokenizerJSON = tokenizerFolder.appending(path: "tokenizer.json")
  static let tokenizerConfig = tokenizerFolder.appending(path: "tokenizer_config.json")
  static let contract = tokenizerFolder.appending(path: "tokenizer-contract.json")
  static let mlpackage = repoRoot.appending(
    path: "Sources/EnviousWisprLLM/Resources/OutputClassifier.mlpackage")

  static let fixturesFolder = repoRoot.appending(
    path: "Tests/EnviousWisprTests/Resources/OutputClassifier")
  static let pretokenizedFixture = fixturesFolder.appending(
    path: "MiniLM-L6.parity50.pretokenized.jsonl")
  static let paritySource = fixturesFolder.appending(path: "MiniLM-L6.parity-source-50.jsonl")
  static let goldenScores = fixturesFolder.appending(path: "MiniLM-L6.golden-scores.jsonl")
}

/// A deterministic stand-in tokenizer: one id per whitespace-token, ids start at
/// 1000 and increment so order + counts are observable in assertions. Lets the
/// pair-encoder math be tested without the real Argmax tokenizer or model.
func wordIndexEncoder(_ text: String) -> [Int] {
  text.split(separator: " ", omittingEmptySubsequences: true)
    .enumerated().map { index, _ in 1000 + index }
}

/// Decode a `TokenizerContract` from an inline JSON literal (for the RoBERTa
/// config-driven test, which has no shipped fixture).
func decodeContract(_ json: String) throws -> TokenizerContract {
  try JSONDecoder().decode(TokenizerContract.self, from: Data(json.utf8))
}

/// A controllable `OutputClassifierProtocol` for fail-open behavior tests.
final class StubOutputClassifier: OutputClassifierProtocol, @unchecked Sendable {
  enum Behavior: Sendable {
    case score(Double)
    case sleep(seconds: Double, then: Double)
    case throwError
  }
  let behavior: Behavior
  init(_ behavior: Behavior) { self.behavior = behavior }

  func score(input: String, polished: String) async throws -> Double {
    switch behavior {
    case let .score(value):
      return value
    case let .sleep(seconds, then):
      try await Task.sleep(for: .seconds(seconds))
      return then
    case .throwError:
      throw OutputClassifierError.disabled(.inferenceError)
    }
  }
}
