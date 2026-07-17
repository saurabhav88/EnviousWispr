import Foundation
import Testing
@preconcurrency import WhisperKit

@testable import EnviousWisprASR

/// Locates the SHIPPED tokenizer resource from disk via `#filePath` (this file
/// lives at `<repo>/Tests/EnviousWisprASRTests/WhisperTokenizerBundleTests.swift`).
/// The tokenizer is an app-target resource (`Bundle.main`), not in the unit-test
/// bundle, so these tests read it directly from the repo — the exact pattern
/// already shipped for `OutputClassifierTokenizer`
/// (`Tests/EnviousWisprTests/LLM/OutputClassifierTestSupport.swift`).
enum WhisperTokenizerTestPaths {
  /// `<repo>` — three parents up from this file (EnviousWisprASRTests → Tests → repo root).
  static let repoRoot: URL = URL(filePath: #filePath)
    .deletingLastPathComponent()  // EnviousWisprASRTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // repo root

  static let tokenizerFolder = repoRoot.appending(
    path: "Sources/EnviousWisprASR/Resources/WhisperTokenizer")
}

@Suite("Bundled WhisperKit tokenizer (#1386)")
struct WhisperTokenizerBundleTests {

  /// Proves the bundled tokenizer files parse into a real, functioning
  /// large-v3 tokenizer, and that this run's successful load came from the
  /// local bytes rather than a completed Hub fallback. Does NOT prove a
  /// structural guarantee that a future local-parse failure could never
  /// attempt any network call — that stronger claim would need an upstream/
  /// forked WhisperKit "local tokenizer only" option, out of scope here.
  @Test(
    "bundled Whisper tokenizer parses locally and WhisperKit selects it without creating a Hub cache"
  )
  func bundledTokenizerLoadsLocally() async throws {
    let folder = WhisperTokenizerTestPaths.tokenizerFolder
    let hubCache = folder.appending(path: "models/openai/whisper-large-v3")

    #expect(FileManager.default.fileExists(atPath: hubCache.path) == false)

    // Fail-closed direct parse: if this throws, the files are bad — no fallback exists here.
    let local = try await AutoTokenizerWrapper.from(modelFolder: folder)
    let endToken = try #require(local.convertTokenToId("<|endoftext|>"))
    #expect(local.encode(text: "Hello from EnviousWispr").isEmpty == false)

    // WhisperKit's real integration path, same folder.
    let tokenizer = try await ModelUtilities.loadTokenizer(
      for: .largev3, tokenizerFolder: folder, additionalSearchPaths: [])

    #expect(tokenizer.convertTokenToId("<|endoftext|>") == endToken)
    // large-v3-specific discriminator: a fallback-default tokenizer would read
    // 50362 here (WhisperTokenizerWrapper.defaultNoSpeechToken), not the real
    // large-v3 value — large-v3 uniquely inserts `<|yue|>` (Cantonese), shifting
    // every later special token by one relative to older Whisper variants.
    #expect(tokenizer.specialTokens.noSpeechToken == 50363)
    // Directory-absence proof: a successful Hub fallback would have populated
    // this directory. Its absence, combined with the preceding fail-closed
    // local parse and the successful integration load matching it, proves
    // these committed bytes were the ones selected locally on this run.
    #expect(FileManager.default.fileExists(atPath: hubCache.path) == false)
  }

  /// Proves the constructor param reaches the exact `WhisperKitConfig`
  /// construction production uses — testing the real factory directly, not a
  /// parallel observation seam.
  @Test("bundled tokenizer folder reaches WhisperKitConfig")
  func tokenizerFolderReachesConfiguration() throws {
    let expected = URL(filePath: "/tmp/WhisperTokenizer")

    let config = WhisperKitBackend.makeWhisperKitConfig(
      model: WhisperKitBackend.defaultModelVariant(),
      modelPath: "/tmp/model",
      tokenizerFolderURL: expected)

    #expect(config.tokenizerFolder == expected)
    #expect(config.modelFolder == "/tmp/model")
    #expect(config.download == false)
  }
}
