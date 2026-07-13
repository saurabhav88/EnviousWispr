import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprPipeline

// MARK: - #1408 — the History "Interrupted" badge's data path
//
// The badge is driven by `Transcript.inputDeviceWasRemoved`, set inside the production
// `store` closure. That closure sees only `outcome`, `context`, and `adapter` —
// none of which knows the microphone died. It reads the interruption from the
// SHARED `KernelTelemetryState` it already captures for `historySaveFailed`.
//
// THE TRAP THIS SUITE EXISTS FOR: `KernelTelemetryState` is DEFAULTED to a fresh
// instance in both `RecordingSessionKernel.init` and `KernelFinalizationWiring
// .init`. Production passes one shared instance to both. A test that constructs
// them separately gets TWO holders — and then every badge assertion passes
// against a holder nobody ever wrote to, while the badge does nothing in the
// shipped app. So these tests pass the holder explicitly, and the last test
// guards the production wiring itself.

/// Captures what the production `store` closure handed to `TranscriptStore.save`.
@MainActor
final class InterruptedSavedTranscriptBox {
  var transcript: Transcript?
}

@MainActor
@Suite("Interrupted-transcript badge data path (#1408)")
struct KernelInterruptedTranscriptTests {

  private func makeWiring(
    telemetryState: KernelTelemetryState,
    saved: InterruptedSavedTranscriptBox
  ) -> KernelFinalizationWiring {
    let engine = FakeEngine(behavior: .batchSuccess(text: "hi"), clock: FakeClock())
    let outcome = KernelFinalizationOutcome()
    outcome.rawText = "hi"
    return KernelFinalizationWiring(
      outcome: outcome,
      context: KernelSessionContext(),
      adapter: engine,
      steps: LimbSteps(
        wordCorrection: WordCorrectionStep(),
        fillerRemoval: FillerRemovalStep(),
        emojiFormatter: EmojiFormatterStep(),
        inverseTextNormalization: InverseTextNormalizationStep(),
        llmPolish: LLMPolishStep(keychainManager: KeychainManager()),
        emojiRestore: EmojiRestoreStep()),
      textProcessingRunner: TextProcessingRunner(),
      save: { saved.transcript = $0 },
      deliverPaste: { _ in
        PasteDeliveryResult(
          tier: .cgEvent, durationMs: 1,
          outcome: .delivered(tier: .cgEvent, durationMs: 1))
      },
      pasteCompletionRegistry: nil,
      telemetryState: telemetryState)
  }

  @Test("a salvaged completion saves a transcript flagged interrupted")
  func salvagedCompletionIsFlagged() async throws {
    let telemetryState = KernelTelemetryState()
    let saved = InterruptedSavedTranscriptBox()
    let wiring = makeWiring(telemetryState: telemetryState, saved: saved)

    // The kernel stamps this before the exit is delivered. `.deviceRemoved` is
    // the ONLY cause backed by a `DeviceIsAlive` check, so it is the only one
    // allowed to leave a permanent crossed-out-microphone badge.
    telemetryState.interruptionCause = .deviceRemoved
    try await wiring.store("hi", UUID())

    let transcript = try #require(saved.transcript)
    #expect(transcript.inputDeviceWasRemoved == true)
    #expect(transcript.isRecovered == false, "a salvage is the live take, not a rescued one")
  }

  /// The engine died but the microphone never left: a codec-switch recovery that
  /// timed out, or a failed engine restart. The dictation is still salvaged; it
  /// just must not be badged as a disconnect it was not.
  @Test("an engine failure with the mic still attached is NOT badged as a disconnect")
  func engineFailureWithMicAttachedIsNotBadged() async throws {
    let telemetryState = KernelTelemetryState()
    let saved = InterruptedSavedTranscriptBox()
    let wiring = makeWiring(telemetryState: telemetryState, saved: saved)

    telemetryState.interruptionCause = .engineLost
    try await wiring.store("hi", UUID())

    #expect(try #require(saved.transcript).inputDeviceWasRemoved == false)
  }

  /// A capture-session interruption is salvaged exactly like a disconnect, but
  /// the History badge shows a crossed-out microphone. The session can be
  /// interrupted for ANY reason with the mic still attached, so the badge must
  /// stay off. (The duration cap used to sit in this class too; #1408's A3
  /// rerouted it as a normal `.maxDuration` stop, so it can no longer stamp a
  /// cause at all.)
  @Test("a capture-session-loss salvage is NOT badged as a disconnect")
  func captureSessionLossSalvageIsNotBadged() async throws {
    let telemetryState = KernelTelemetryState()
    let saved = InterruptedSavedTranscriptBox()
    let wiring = makeWiring(telemetryState: telemetryState, saved: saved)

    telemetryState.interruptionCause = .engineLost
    try await wiring.store("hi", UUID())

    #expect(try #require(saved.transcript).inputDeviceWasRemoved == false)
  }

  @Test("an ordinary completion saves a transcript that is not flagged")
  func ordinaryCompletionIsNotFlagged() async throws {
    let telemetryState = KernelTelemetryState()
    let saved = InterruptedSavedTranscriptBox()
    let wiring = makeWiring(telemetryState: telemetryState, saved: saved)

    try await wiring.store("hi", UUID())

    let transcript = try #require(saved.transcript)
    #expect(transcript.inputDeviceWasRemoved == false)
  }

  /// `resetForNewSession()` is the SOLE clearer of the cause. If a second clearer
  /// is ever reintroduced, or this one drops the field, the next dictation after
  /// an interrupted one would be badged "Interrupted" in History despite being a
  /// clean take.
  @Test("resetForNewSession clears the cause, so the next take is not badged")
  func resetForNewSessionClearsTheCause() async throws {
    let telemetryState = KernelTelemetryState()
    let saved = InterruptedSavedTranscriptBox()
    let wiring = makeWiring(telemetryState: telemetryState, saved: saved)

    telemetryState.interruptionCause = .engineLost
    telemetryState.resetForNewSession(polishEnabled: false)
    try await wiring.store("hi", UUID())

    #expect(telemetryState.interruptionCause == nil)
    #expect(try #require(saved.transcript).inputDeviceWasRemoved == false)
  }
}

// MARK: - The shared-holder guard

/// A source-level assertion, in the style of the ceiling tests: the factory pulls
/// in the real transcript store, paste executor, and ASR machinery, so no unit
/// test instantiates it. What matters is structural and greppable — exactly ONE
/// `KernelTelemetryState` is constructed, and the same value reaches the kernel,
/// the finalization wiring, and the lifecycle sink.
///
/// Without this, a refactor that gave any one of the three its own defaulted
/// holder would silently disable the History badge and the `interrupted_by`
/// telemetry, and every test above would still pass.
@Suite("KernelDictationDriverFactory shares one telemetry holder (#1408)")
struct KernelTelemetryStateSharingTests {

  private static let sourcePath = "Sources/EnviousWisprPipeline/KernelDictationDriverFactory.swift"

  @Test("the factory constructs exactly one KernelTelemetryState")
  func exactlyOneHolderIsConstructed() throws {
    let source = try String(
      contentsOf: RepoRoot.sourceURL(Self.sourcePath), encoding: .utf8)
    let constructions = source.components(separatedBy: "KernelTelemetryState()").count - 1
    #expect(
      constructions == 1,
      """
      Expected exactly one `KernelTelemetryState()` in the factory, found \(constructions). \
      The kernel, the finalization wiring, and the lifecycle sink each DEFAULT to a \
      fresh holder; production must hand all three the same instance or the History \
      "Interrupted" badge and `interrupted_by` silently stop working.
      """)
  }

  @Test("that one holder is passed to all three consumers")
  func theHolderIsPassedToEveryConsumer() throws {
    let source = try String(
      contentsOf: RepoRoot.sourceURL(Self.sourcePath), encoding: .utf8)
    let passes = source.components(separatedBy: "telemetryState: telemetryState").count - 1
    #expect(
      passes >= 3,
      """
      Expected the shared holder to be passed to the kernel, the finalization wiring, \
      and the lifecycle sink (>= 3 `telemetryState: telemetryState` arguments), found \(passes).
      """)
  }
}
