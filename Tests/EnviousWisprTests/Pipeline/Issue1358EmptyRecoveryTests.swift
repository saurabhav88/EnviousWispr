import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprPipeline

// MARK: - #1358 — empty-after-processing recovery
//
// When the limb chain empties the transcript, the finalization wiring delivers
// the first non-empty deterministic floor (post-ITN text, else lexical raw ASR)
// with History == clipboard, and only a truly non-lexical result routes to the
// quiet `.noSpeech` terminal (never a `heart_path_finalization` failure). The
// two illegal safe-point transitions the fix needs (`.noSpeech` and its
// interruption-floored `.audioInterrupted`) are made legal so nothing wedges.
//
// End-to-end "a filler-only RECORDING lands in `.noSpeech`" is covered
// transitively: the wiring returns "" for a filler-only chain result (see
// `wiringFillerOnlyReturnsEmpty`), the kernel branch routes "" → `.noSpeech`
// (code), the transition is legal (`Issue1358EmptyRecoveryFSMTests`), and the
// observable outcome is a breadcrumb, not a Sentry capture
// (`KernelLifecycleTelemetrySinkTests.noSpeechEmptyAfterProcessingEmission`).
//
// SPLIT into two suites so the config-independent core keeps running in the
// post-merge RELEASE lane (ci-pipeline.md RULE: release-tests-run-post-merge):
//   • `Issue1358EmptyRecoveryTests` (this suite) — pure classifier / floor /
//     wiring tests. Runs in BOTH debug and release.
//   • `Issue1358EmptyRecoveryFSMTests` (below, `#if DEBUG`) — the FSM-legality,
//     interrupted-floor, and diagnostic archive-relabel tests, which use
//     `#if DEBUG`-only members of `RecordingSessionKernel` (`testForceTransition`
//     / `testSetInterruptionCause` / `testInterruptedTerminalFloor` and the
//     debug-only `relabeledArchiveOutcome`), so that suite must be gated (release
//     compiles with `DEBUG` undefined and those members vanish).

@MainActor
@Suite("#1358 empty-after-processing recovery")
struct Issue1358EmptyRecoveryTests {

  // MARK: TextLexicalContent (the raw-floor classifier)

  @Test(
    "hasLexicalContentAfterRemovingFillers: fillers/punctuation → false, real words/digits → true",
    arguments: [
      ("uh", false), ("um", false), ("hmm", false), ("mm", false),
      ("...", false), ("", false), ("   ", false),
      ("OK", true), ("hi", true), ("no", true), ("I", true),
      ("1988", true), ("8", true), ("uh OK", true), ("hello there", true),
    ])
  func lexicalClassifier(input: String, expected: Bool) {
    #expect(TextLexicalContent.hasLexicalContentAfterRemovingFillers(input) == expected)
  }

  // MARK: emptyOutputRecoveryFloor (the pure floor decision)

  @Test(
    "emptyOutputRecoveryFloor: post-ITN floor wins, else lexical raw, else empty (→ no-speech)",
    arguments: [
      // (deterministicText, rawASR, expectedFloor)
      ("hello there", "uh", "hello there"),  // rank 2 wins even when raw is filler
      ("203", "two zero three", "203"),  // rank 2 (polish erased, post-ITN intact)
      ("", "hello", "hello"),  // rank 3 — a step erased a real word
      ("   ", "  no  ", "no"),  // whitespace deterministic → rank 3, trimmed
      ("", "1988", "1988"),  // rank 3 digit
      ("", "uh", ""),  // filler-only → route to .noSpeech
      ("", "uh...", ""),  // filler + punctuation → .noSpeech
      ("", "", ""),  // nothing → .noSpeech
    ])
  func recoveryFloor(deterministicText: String, rawASR: String, expectedFloor: String) {
    #expect(
      KernelFinalizationWiring.emptyOutputRecoveryFloor(
        deterministicText: deterministicText, rawASR: rawASR) == expectedFloor)
  }

  @Test(
    "the raw floor strips fillers regardless of the filler-removal toggle (deliberate, #1358)")
  func rawFloorIsToggleIndependent() {
    // The classifier never reads `fillerRemovalEnabled`; a bare filler is never
    // floored even when a NON-filler step emptied the deterministic text.
    #expect(
      KernelFinalizationWiring.emptyOutputRecoveryFloor(deterministicText: "", rawASR: "uh") == ""
    )
    // A real word emptied by a step IS recovered.
    #expect(
      KernelFinalizationWiring.emptyOutputRecoveryFloor(deterministicText: "", rawASR: "hello")
        == "hello")
  }

  // MARK: Wiring integration — polish returns empty (finding 3)

  @Test(
    "polish returns empty with an intact post-ITN floor → floor delivered, History == clipboard",
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/1358",
      "empty polish erased short dictations"
    ))
  func wiringPolishEmptyDeliversFloorConsistently() async throws {
    let outcome = KernelFinalizationOutcome()
    let saved = SavedBox()
    let steps = makeSteps()
    // Polish ON with an empty-returning polisher; >3 words so it is not bypassed.
    steps.llmPolish.llmProvider = .openAI
    steps.llmPolish.llmModel = "gpt-4o-mini"
    steps.llmPolish.makePolisher = { _, _, _ in EmptyPolisher() }
    let wiring = makeWiring(outcome: outcome, steps: steps, save: { saved.transcript = $0 })

    let input = "please clean up this sentence now"
    let result = try await wiring.processText(input) {}
    try await wiring.store(result, UUID())
    _ = await wiring.deliver(result)

    // Delivered the post-ITN floor, not the empty polish.
    #expect(result == input)
    // Side-channels stamped so store/deliver/metrics all agree.
    #expect(outcome.rawText == input)
    #expect(outcome.polishedText == nil)
    #expect(outcome.pipelineFellBackToRaw == true)
    #expect(outcome.polishFallbackReason == "empty_output_floor")
    // The polish attempt is still recorded honestly (not erased).
    #expect(outcome.llmProvider == LLMProvider.openAI.rawValue)
    #expect(outcome.llmModel == "gpt-4o-mini")
    // History == clipboard: the persisted transcript text equals the delivered text.
    #expect(saved.transcript?.text == input)
    #expect(saved.transcript?.polishedText == nil)
    // The recovery signal reaches telemetry even though this is a CLOUD provider
    // (no AFM `polishMetadata`) — the metrics gate lets `empty_output_floor`
    // through so the defensive recovery is observable.
    let metrics = try #require(outcome.transcript?.metrics)
    #expect(metrics.polishFellBackToRaw == true)
    #expect(metrics.polishFallbackReason == "empty_output_floor")
  }

  @Test("a filler-only chain result returns empty from processText (kernel routes → .noSpeech)")
  func wiringFillerOnlyReturnsEmpty() async throws {
    let outcome = KernelFinalizationOutcome()
    let steps = makeSteps()
    steps.fillerRemoval.fillerRemovalEnabled = true  // the shipped default
    let wiring = makeWiring(outcome: outcome, steps: steps)

    // Filler removal empties "uh"; the raw floor is non-lexical → "".
    let result = try await wiring.processText("uh") {}
    #expect(result.isEmpty)
    // No floor stamped — nothing to recover.
    #expect(outcome.polishFallbackReason == nil)
  }

  // MARK: Helpers

  private func makeSteps() -> LimbSteps {
    LimbSteps(
      wordCorrection: WordCorrectionStep(),
      fillerRemoval: FillerRemovalStep(),
      emojiFormatter: EmojiFormatterStep(),
      inverseTextNormalization: InverseTextNormalizationStep(),
      llmPolish: LLMPolishStep(keychainManager: KeychainManager()),
      emojiRestore: EmojiRestoreStep())
  }

  private func makeWiring(
    outcome: KernelFinalizationOutcome = KernelFinalizationOutcome(),
    steps: LimbSteps? = nil,
    save: @escaping @MainActor (Transcript) throws -> Void = { _ in }
  ) -> KernelFinalizationWiring {
    let context = KernelSessionContext()
    context.config = .testDefault(autoPasteToActiveApp: true)
    return KernelFinalizationWiring(
      outcome: outcome,
      context: context,
      adapter: ParakeetEngineAdapter(asrManager: StubParakeetASRManager()),
      steps: steps ?? makeSteps(),
      textProcessingRunner: TextProcessingRunner(
        timeoutExecutor: FakeTimeoutExecutor(throwBelowSeconds: 0).run),
      save: save,
      deliverPaste: { _ in
        PasteDeliveryResult(
          tier: .cgEvent, durationMs: 1,
          outcome: .delivered(tier: .cgEvent, durationMs: 1))
      },
      pasteCompletionRegistry: nil,
      currentTime: { ProcessInfo.processInfo.systemUptime },
      telemetryState: KernelTelemetryState())
  }
}

/// Returns an empty polish result so the empty-output floor is exercised — the
/// short-input analogue of the validator gap (`validatePolishOutput` has no
/// empty guard below 10 input words).
private struct EmptyPolisher: TranscriptPolisher {
  func polish(
    text: String,
    instructions: PolishInstructions,
    config: LLMProviderConfig,
    onToken: (@Sendable (String) -> Void)?
  ) async throws -> LLMResult {
    LLMResult(polishedText: "")
  }
}

@MainActor
private final class SavedBox {
  var transcript: Transcript?
}

// MARK: - FSM legality + interrupted floor (DEBUG-only hooks)
//
// These drive the kernel through `testForceTransition` / `testSetInterruptionCause`
// / `testInterruptedTerminalFloor`, which are `#if DEBUG`-only on
// `RecordingSessionKernel` — so this suite is gated exactly like
// `RecordingSessionKernelTests` and `RecordingSessionKernelExternalInterruptionTests`.

#if DEBUG

  @MainActor
  @Suite("#1358 empty-after-processing recovery — FSM (DEBUG hooks)")
  struct Issue1358EmptyRecoveryFSMTests {

    @Test(
      "finalizing legal terminal set is exactly {.completed, .failed, .noSpeech, .audioInterrupted}",
      .bug(
        "https://github.com/saurabhav88/EnviousWispr/issues/1358",
        "an illegal finalizing → noSpeech/audioInterrupted would silently wedge the session"
      ))
    func finalizingAllowedTerminalSet() {
      // The four legal terminals — each on a fresh kernel walked to finalizing
      // (a successful transition leaves finalizing).
      for terminal in [
        RecordingSessionState.completed, .failed(.asrEmpty), .noSpeech, .audioInterrupted,
      ] {
        let kernel = freshKernelAtFinalizing()
        #expect(
          kernel.testForceTransition(to: terminal) == true,
          "\(terminal) must be a legal terminal from finalizing")
      }
      // Every other target is rejected (the safe point holds). All false on one
      // kernel since a rejected transition leaves it in finalizing.
      let kernel = freshKernelAtFinalizing()
      for forbidden in [
        RecordingSessionState.idle, .preparing, .warmingUp, .recording, .stopping,
        .transcribing, .finalizing, .cancelled, .discarded, .asrInterrupted,
      ] {
        #expect(
          kernel.testForceTransition(to: forbidden) == false,
          "\(forbidden) must be rejected from finalizing")
        #expect(kernel.state == .finalizing, "a rejected transition leaves the safe point intact")
      }
    }

    @Test(
      "an interrupted empty finalize floors .noSpeech → .audioInterrupted (retain spool), else unchanged"
    )
    func interruptedEmptyFloorsToAudioInterrupted() {
      // With an interruption cause, the empty no-speech is floored UP so the
      // #1408 crash-recovery spool is retained.
      let interrupted = freshKernelAtFinalizing()
      interrupted.testSetInterruptionCause(.xpcConnectionLost)
      #expect(interrupted.testInterruptedTerminalFloor(.noSpeech) == .audioInterrupted)

      // With no interruption, the clean cold-mic filler stays quiet no-speech.
      let clean = freshKernelAtFinalizing()
      clean.testSetInterruptionCause(nil)
      #expect(clean.testInterruptedTerminalFloor(.noSpeech) == .noSpeech)
    }

    // MARK: Diagnostic-archive relabel (code-diff r2)
    // `relabeledArchiveOutcome` + the dictation-audio-archive feature are
    // `#if DEBUG`-only (diagnostic capture), so this test lives in the gated suite.

    @Test(
      "archive relabel: filler-only .noSpeech archives as .noSpeech, not .finalizationFailed")
    func archiveOutcomeRelabel() {
      let transcript = ASREngineOutcome.transcript(
        ASRResult(
          text: "uh", language: nil, duration: 0.1, processingTime: 0.05, backendType: .parakeet))
      // A normal completion keeps its base label.
      #expect(
        RecordingSessionKernel.relabeledArchiveOutcome(
          base: .completed, effectiveOutcome: transcript,
          reachedCompleted: true, reachedNoSpeech: false) == .completed)
      // #1358: a filler-only capture emptied by processing → quiet no-speech, NOT a failure.
      #expect(
        RecordingSessionKernel.relabeledArchiveOutcome(
          base: .completed, effectiveOutcome: transcript,
          reachedCompleted: false, reachedNoSpeech: true) == .noSpeech)
      // Empty-after-polish `.failed` / superseded mid-finalize stays finalizationFailed.
      #expect(
        RecordingSessionKernel.relabeledArchiveOutcome(
          base: .completed, effectiveOutcome: transcript,
          reachedCompleted: false, reachedNoSpeech: false) == .finalizationFailed)
      // A non-`.transcript` decode keeps its base label untouched.
      #expect(
        RecordingSessionKernel.relabeledArchiveOutcome(
          base: .noSpeech, effectiveOutcome: .empty(hadSpeechEvidence: false),
          reachedCompleted: false, reachedNoSpeech: true) == .noSpeech)
    }

    /// A fresh kernel legally walked to `.finalizing`.
    private func freshKernelAtFinalizing() -> RecordingSessionKernel {
      let clock = FakeClock()
      let engine = FakeEngine(behavior: .batchSuccess(text: "hello"), clock: clock)
      let wrapper = KernelRecordingSession(
        engine: engine, capture: FakeAudioCapture(), vad: FakeVADSignalSource(),
        clock: clock, paste: FakePasteTarget())
      let kernel = wrapper.testKernel
      _ = kernel.testForceTransition(to: .preparing)
      _ = kernel.testForceTransition(to: .warmingUp)
      _ = kernel.testForceTransition(to: .recording)
      _ = kernel.testForceTransition(to: .stopping)
      _ = kernel.testForceTransition(to: .transcribing)
      _ = kernel.testForceTransition(to: .finalizing)
      return kernel
    }
  }

#endif  // DEBUG (#1358 FSM suite — shares the testForceTransition gating posture)
