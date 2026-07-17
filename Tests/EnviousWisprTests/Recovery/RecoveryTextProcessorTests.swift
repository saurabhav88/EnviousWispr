import EnviousWisprCore
import EnviousWisprPipeline
import Foundation
import Testing

@testable import EnviousWisprLLM

/// The public recovery text-processing seam (#1063 PR0) must run the SAME chain
/// a live dictation runs, configured by the recording's settings snapshot. With
/// polish disabled (provider `.none`) the deterministic steps are observable, so
/// these tests prove the chain actually runs and honors the snapshot toggles.
@MainActor
@Suite("Recovery text processor (#1063)")
struct RecoveryTextProcessorTests {

  private func snapshot(
    fillerRemoval: Bool, provider: String = "none",
    backendType: ASRBackendType = .parakeet, lidCapable: Bool = false,
    languageMode: LanguageMode = .auto
  ) -> RecordingSettingsSnapshot {
    RecordingSettingsSnapshot(
      backendType: backendType,
      backendSupportsLanguageDetection: lidCapable,
      languageMode: languageMode,
      wordCorrectionEnabled: false,
      fillerRemovalEnabled: fillerRemoval,
      emojiFormatterEnabled: false,
      customWordsVersion: nil,
      llmProvider: provider,
      llmModel: "none",
      polishPromptVersion: nil)
  }

  @Test("the recovery chain runs the standard steps end to end, polish disabled")
  func chainRunsEndToEnd() async {
    // Inverse text normalization is the robust observable transform here (its
    // 2s runner budget tolerates CPU-saturated parallel runs, unlike filler
    // removal's 50ms budget — `tests-no-real-time-scheduling-precision`). A
    // non-LID engine with auto language runs ITN. Proves the seam executes the
    // chain and keeps polish off under provider .none.
    let processor = RecoveryTextProcessor(keychainManager: KeychainManager())
    processor.applySettings(snapshot(fillerRemoval: true))
    let outcome = await processor.process(rawText: "the code is two zero three")
    #expect(outcome.text.contains("203"))  // the chain demonstrably transformed the text
    #expect(outcome.polishedText == nil)  // provider .none ⇒ no polish
    #expect(outcome.polishError == nil)
  }

  @Test("disabling filler removal in the snapshot leaves the text untouched")
  func snapshotTogglesThreadThrough() async {
    let input = "um hello uh there world"
    let processor = RecoveryTextProcessor(keychainManager: KeychainManager())
    processor.applySettings(snapshot(fillerRemoval: false))
    let outcome = await processor.process(rawText: input)
    #expect(outcome.text == input)
    #expect(outcome.polishedText == nil)
  }

  /// The recovered take must hit the SAME inverse-text-normalization language
  /// gate the live pipeline does (Codex PR0 P2). For a LID engine with unknown
  /// language, ITN must skip rather than rewrite possibly-non-English numbers.
  @Test("the ITN language gate matches the live pipeline for the recorded engine")
  func itnLanguageGateMatchesLiveEngine() async {
    let spoken = "call me at two zero three"

    // Non-LID engine (Parakeet-class): unknown language runs ITN → digits.
    let parakeet = RecoveryTextProcessor(keychainManager: KeychainManager())
    parakeet.applySettings(
      snapshot(fillerRemoval: false, backendType: .parakeet, lidCapable: false))
    let parakeetOut = await parakeet.process(rawText: spoken)
    #expect(parakeetOut.text.contains("203"))

    // LID engine (WhisperKit) with unknown language: ITN skips → text untouched.
    let whisperKit = RecoveryTextProcessor(keychainManager: KeychainManager())
    whisperKit.applySettings(
      snapshot(fillerRemoval: false, backendType: .whisperKit, lidCapable: true))
    let whisperKitOut = await whisperKit.process(rawText: spoken)
    #expect(whisperKitOut.text == spoken)
  }

  /// A take recorded with a LOCKED non-English language must replay under THAT
  /// language, derived from the snapshot — not nil/auto — so the chain never
  /// rewrites it as English (Codex PR0 P2). With Spanish locked, the English-
  /// only ITN must skip, leaving the spoken-form numbers intact.
  @Test("a locked non-English snapshot replays under its own language")
  func lockedLanguageReplaysUnderSnapshot() async {
    let spoken = "llamame al dos cero tres two zero three"
    let processor = RecoveryTextProcessor(keychainManager: KeychainManager())
    // Non-LID engine: were the locked language NOT applied, language would be
    // nil and ITN would run (non-LID + nil) and rewrite "two zero three" → 203.
    processor.applySettings(
      snapshot(
        fillerRemoval: false, backendType: .parakeet, lidCapable: false,
        languageMode: .locked("es")))
    let outcome = await processor.process(rawText: spoken)
    #expect(outcome.text == spoken)  // Spanish locked ⇒ English ITN skipped
  }

  // MARK: - Telemetry silence (#945, extended by #1446)

  /// A `KeychainManager` whose reads always throw, driving the cloud connector's
  /// `getAPIKey` catch arm (`.apiKeyUnreadable`, #1446). The `.legacyFiles` backend
  /// is the DEBUG/dev one, so the founder's real Keychain is never touched, and the
  /// throw lands before any network request is built.
  private struct UnreadableKeyStore: LegacyKeyFileStorage {
    func store(key: String, value: String) throws { throw KeyStoreError.storeFailed(-1) }
    func retrieve(key: String) throws -> String { throw KeyStoreError.retrieveFailed(-1) }
    func delete(key: String) throws {}
  }

  @Test("a recovered take whose polish fails still lands as deterministic text with its notice")
  func recoveryPolishFailureFallsBackToRawWithNotice() async {
    let processor = RecoveryTextProcessor(
      keychainManager: KeychainManager(backend: .legacyFiles, legacyStore: UnreadableKeyStore()))
    processor.applySettings(snapshot(fillerRemoval: false, provider: "openAI"))

    // Long enough to clear the polish step's short-transcript short-circuit.
    let outcome = await processor.process(
      rawText: "so i was thinking we could maybe ship the new thing some time next week or so")

    #expect(outcome.polishedText == nil)
    // #1446: `.apiKeyUnreadable` reuses `.apiKeyMissing`'s copy verbatim, so the
    // split is invisible to the user even on the recovery path.
    #expect(
      outcome.polishError == "AI cleanup skipped: no OpenAI API key set yet. Add one in Settings.")
  }

  /// #945 / #1446: recovery must emit NO polish telemetry — a live-only metric.
  ///
  /// Asserted against the source rather than by observing telemetry, deliberately.
  /// The seams are private to the runner, so the only behavioral observation point
  /// is a process-global delegate; a negative assertion through one can pass
  /// vacuously when a sibling suite replaces the hook mid-`await`, which makes it a
  /// guard that silently stops guarding (`swift-patterns.md`
  /// `tests-no-process-global-mutable-delegate`). Reading the wiring is race-free
  /// and strictly stronger: it fails if recovery hand-rolls its own seams, which is
  /// exactly the mistake `TextProcessingRunner.TelemetrySeams.silent` exists to
  /// prevent.
  @Test(
    "RecoveryTextProcessor silences telemetry via the one .silent value, not per-seam closures",
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/1446",
      "a second telemetry seam must not be left live in crash recovery")
  )
  func recoveryWiresTheSilentSeams() throws {
    let path = repoRoot().appending(
      path: "Sources/EnviousWisprPipeline/RecoveryTextProcessor.swift")
    let source = try String(contentsOf: path, encoding: .utf8)
    let code = source.split(separator: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.hasPrefix("//") }
      .joined(separator: " ")

    // Bound to locals so a failure prints the verdict, not the whole source file.
    let buildsRunnerFromSilent = code.contains("TextProcessingRunner(telemetry: .silent)")
    // Hand-rolled seams here are the regression: they silence what exists today and
    // silently miss whatever seam is added tomorrow. (`recordPolishSkipped` is the
    // one that WAS missed — it called TelemetryService directly until the cloud
    // review of PR #1460 found it.)
    let handRolledSeams = ["captureError:", "recordPolishFailed:", "recordPolishSkipped:"]
      .filter { code.contains($0) }

    #expect(buildsRunnerFromSilent)
    #expect(handRolledSeams.isEmpty, "recovery must name .silent, not per-seam closures")
  }

  /// #1461: `TextProcessingRunner.TelemetrySeams.silent` only ever covered the
  /// RUNNER's own three seams — it cannot reach `LLMPolishStep`'s own emitters,
  /// which fired identically on a live take and a recovered replay until this
  /// plan gave the step its own `.live`/`.silent` seam. Same static-source-check
  /// pattern as `recoveryWiresTheSilentSeams` above, not a process-global hook
  /// (`swift-patterns.md` RULE: tests-no-process-global-mutable-delegate) —
  /// deliberately proving the real construction call site, not just that
  /// `.silent` behaves correctly in isolation (that's `LLMPolishStepTelemetryTests`).
  @Test(
    "RecoveryTextProcessor silences LLMPolishStep's own telemetry via .silent, not per-seam closures",
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/1461",
      "LLMPolishStep's own emitters must not leak into crash recovery")
  )
  func recoveryWiresLLMPolishStepSilent() throws {
    let path = repoRoot().appending(
      path: "Sources/EnviousWisprPipeline/RecoveryTextProcessor.swift")
    let source = try String(contentsOf: path, encoding: .utf8)
    let code = source.split(separator: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.hasPrefix("//") }
      .joined(separator: " ")

    let buildsStepFromSilent = code.contains(
      "LLMPolishStep(keychainManager: keychainManager, telemetry: .silent()")
    let handRolledSeams = [
      "limbFailureObserved:", "breadcrumbStarted:", "captureProviderInitError:",
      "captureAFMPolishError:", "breadcrumbCompleted:", "recordPolishSkipped:",
    ].filter { code.contains($0) }

    #expect(buildsStepFromSilent)
    #expect(handRolledSeams.isEmpty, "recovery must name .silent, not per-seam closures")
  }

  /// Repo root, anchored off `#filePath` — this file lives at
  /// `Tests/EnviousWisprTests/Recovery/`, four levels below the root.
  private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
