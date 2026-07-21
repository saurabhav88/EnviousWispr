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
  /// `<repo>`, resolved by the shared marker-walk helper (`RepoRoot.swift`,
  /// `Tests/EnviousWisprTests/Architecture/`) rather than a fixed-depth trim.
  /// A fixed 4-hop trim from this file broke under a `/tmp` checkout (`/tmp`
  /// is a symlink to `/private/tmp` on macOS) — see #1675.
  static let repoRoot: URL = RepoRoot.url

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
    /// A NON-cooperative block (ignores cancellation) that parks the calling
    /// cooperative-pool thread — polling a test-owned release flag with a
    /// blocking `usleep`, like a stuck Core ML `MLModel.prediction`. It does NOT
    /// complete until the test calls `releaseGate()` (or a ~10s iteration cap
    /// elapses as a safety net). Lets a test prove `withDeadline` released the
    /// caller at the deadline DETERMINISTICALLY: while the gate is still closed
    /// the block cannot have completed, so `didFinishBlock` is false the instant
    /// the caller returns — no wall-clock bound, no post-return reschedule race
    /// (#1283, cloud-review r1/r2). A regression that AWAITED the block would
    /// only return after the cap, failing cleanly instead of hanging.
    case gatedBlock(then: Double)
    case throwError
  }
  let behavior: Behavior
  init(_ behavior: Behavior) { self.behavior = behavior }

  private let lock = NSLock()
  private var _released = false
  private var _didFinishBlock = false
  /// True once a `.gatedBlock` body has run to completion. Deterministically
  /// false while the gate is still closed (before `releaseGate()`).
  var didFinishBlock: Bool { lock.withLock { _didFinishBlock } }
  /// Release a parked `.gatedBlock` so its thread can complete and free.
  func releaseGate() { lock.withLock { _released = true } }

  func score(input: String, polished: String) async throws -> Double {
    switch behavior {
    case let .score(value):
      return value
    case let .sleep(seconds, then):
      try await Task.sleep(for: .seconds(seconds))
      return then
    case let .gatedBlock(then):
      // Non-cooperative park: blocks the pool thread by polling the release flag
      // with a 1ms `usleep` (a blocking syscall, allowed from async unlike
      // `DispatchSemaphore.wait`). The ~10_000-iteration (~10s) cap is a safety
      // net for a regression that awaits the block — it never binds the happy
      // path, which is released within ~1ms of `releaseGate()`.
      var iterations = 0
      while iterations < 10_000, !lock.withLock({ _released }) {
        usleep(1000)
        iterations += 1
      }
      lock.withLock { _didFinishBlock = true }
      return then
    case .throwError:
      throw OutputClassifierError.disabled(.inferenceError)
    }
  }
}
