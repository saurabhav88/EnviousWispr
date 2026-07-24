import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprPipeline

/// #1464 — does this concluded outcome delete the crash-recovery spool? Composes
/// the two real authorities the floor must stay ahead of: the driver's projection
/// (`recoveryEnding`) into the narrow public ending, then the coordinator's sole
/// delete-versus-retain predicate (`shouldDeleteOnLiveEnding`). `.completed` /
/// `.cancelled` project to nil (a saved take / a dynamically-resolved cancel) and
/// are never floor-coupled — they return false here.
@MainActor
private func deletesRecoverySpool(_ outcome: RecordingOutcome) -> Bool {
  guard let ending = KernelDictationDriver.recoveryEnding(for: outcome) else { return false }
  return RecoveryCoordinator.shouldDeleteOnLiveEnding(ending)
}

/// #1707 Phase 2 sibling of `deletesRecoverySpool(_:)`, threading the retry
/// outcome through the SAME two real authorities.
@MainActor
private func deletesRecoverySpool(_ outcome: RecordingOutcome, retryOutcome: ASRRetryOutcome?)
  -> Bool
{
  guard let ending = KernelDictationDriver.recoveryEnding(for: outcome, retryOutcome: retryOutcome)
  else { return false }
  return RecoveryCoordinator.shouldDeleteOnLiveEnding(ending)
}

/// #1755 discard doctrine: EVERY `.failed` deletes, whatever the retry
/// outcome — an ending fired while the app was alive, the user witnessed the
/// failure and re-dictates. `.asrRetryExhausted` stays a distinct typed
/// projection for diagnostics; it now AGREES with `.failed` on deletion.
@MainActor
@Suite("Failed-session spool deletion (#1707 Phase 2 → #1755 cutover)")
struct ExhaustedRetrySpoolDeletionTests {
  @Test("an exhausted retry's failed session deletes its spool (unchanged)")
  func exhaustedRetryDeletes() {
    #expect(deletesRecoverySpool(.failed(.asrFailed), retryOutcome: .retryExhausted))
  }

  @Test("a pre-capture or never-retried failed session deletes too (#1755 flipped)")
  func neverRetriedFailureDeletes() {
    #expect(deletesRecoverySpool(.failed(.asrFailed), retryOutcome: nil))
    #expect(deletesRecoverySpool(.failed(.asrFailed)))
  }

  @Test("a retry left at .attempted (timeout/cancel) deletes as plain .failed (#1755 founder override)")
  func attemptedOnlyRetryDeletesAsFailed() {
    // `.attempted` remains the honest diagnostic that no decode conclusion
    // was accepted; the founder's Gate 2 decision makes it delete anyway —
    // a visible retry failure is a failure to the user.
    #expect(deletesRecoverySpool(.failed(.asrFailed), retryOutcome: .attempted))
  }
}

// MARK: - #1408 — salvage a dictation whose capture was interrupted mid-recording
//
// Before #1408, a microphone that died mid-sentence sent the recording
// straight to `.audioInterrupted` and the audio the capture manager was still
// holding was never transcribed. Now a salvageable interruption falls through
// into the normal stop tail.
//
// Two properties are under test:
//
//   1. Salvage happens for the causes that leave audio in memory, and does NOT
//      happen for the one cause whose sample owner is gone.
//   2. THE FLOOR (#1755 reframe: terminal/notice HONESTY, not retention).
//      Falling through means an interrupted recording meets the same early
//      terminals a normal stop does (`.discarded`, `.noSpeech`,
//      `.failed(.noAudioCaptured)`) — which would tell an interrupted user
//      "you said nothing." The floor maps them back to `.audioInterrupted`,
//      the honest notice. Disk disposition is uniform best-effort deletion
//      for every concluded live ending; stale interruption state can only
//      mislabel a terminal/notice, never retain a spool.
//
// The floor's proof is a PAIR: identical early-terminal trigger, different
// exit. A too-short user stop still reads `.discarded`; a too-short
// interrupted recording reads `.audioInterrupted` (the honest notice).

#if DEBUG

  /// One floored terminal site, as data, so the parametric test names which site
  /// wedged rather than reporting a bare state mismatch.
  struct FlooredSite: Sendable, CustomStringConvertible {
    let name: String
    // #1548 D1: every floored site now delivers ≥1 buffer to reach `.live`
    // (the transport gate); the sub-minimum-discard site uses the tick-based
    // gate instead of the retired zero-buffer arm.
    let minimumRecordingTicks: Int
    let buffers: Int
    let amplitude: Float
    let deadAirVAD: Bool
    var description: String { name }
  }

  @MainActor
  @Suite("RecordingSessionKernel — interrupted-capture salvage (#1408)")
  struct RecordingSessionKernelSalvageTests {

    private func makeWrapper(
      minimumRecordingTicks: Int = 0,
      behavior: FakeEngineBehavior = .batchSuccess(text: "hello")
    ) -> (SimulatorContext, KernelRecordingSession) {
      let clock = FakeClock()
      let engine = FakeEngine(behavior: behavior, clock: clock)
      let capture = FakeAudioCapture()
      let vad = FakeVADSignalSource()
      let paste = FakePasteTarget()
      let wrapper = KernelRecordingSession(
        engine: engine, capture: capture, vad: vad, clock: clock, paste: paste,
        minimumRecordingTicks: minimumRecordingTicks)
      let context = SimulatorContext(
        sut: wrapper, engine: engine, capture: capture, vad: vad, clock: clock, paste: paste)
      return (context, wrapper)
    }

    /// Start, reach `.recording`, and deliver `bufferCount` real buffers so the
    /// kernel has audio in hand when the interruption lands.
    private func startRecording(
      _ context: SimulatorContext, buffers bufferCount: Int = 1, amplitude: Float = 0.1
    ) async {
      await context.sut.apply(.start)
      await context.sut.drainReadyWork()
      for _ in 0..<bufferCount { context.capture.deliverBuffer(amplitude: amplitude) }
      await context.sut.drainReadyWork()
    }

    // MARK: 1. Salvage happens exactly for the causes that leave audio behind

    /// Every cause whose manager is still alive and holding `capturedSamples`
    /// must transcribe. Parametric over the predicate's `true` set so a fifth
    /// cause has to make a decision here as well as at the compiler.
    @Test(
      "a salvageable interruption with real audio transcribes and completes",
      arguments: EngineInterruptionCause.allCases.filter(\.hasRecoverableAudio))
    func salvageableCauseCompletes(cause: EngineInterruptionCause) async {
      let (context, wrapper) = makeWrapper()
      await startRecording(context)

      wrapper.testKernel.externalEngineInterrupted(cause)
      await wrapper.drainReadyWork()

      #expect(wrapper.testKernel.recordingOutcome == .completed)
      #expect(context.paste.pasteCount == 1)
      #expect(wrapper.testKernel.lastAudioInterruptionCause == cause)
      // The dictation is a salvage, and `stop_reason` says so for free.
      #expect(wrapper.testKernel.lastStopReason == "audio_interruption")
    }

    // #1543: the "unsalvageable cause refuses salvage even with a full buffer"
    // test is gone with the XPC-connection cause — in-process the capture manager
    // always holds the samples, so no interruption cause is unsalvageable. The
    // salvage-succeeds path is covered by the salvage tests below.

    // MARK: 1b. #1755 chunk 2 — a text-processing throw must not lose usable raw ASR

    /// North Star point 3: a transcript the app already has is never thrown
    /// away when raw text can be delivered. A throwing `processText` used to
    /// publish `.failed(.emptyAfterProcessing)` BEFORE storage or delivery;
    /// it now routes the raw ASR through the sole recovery-floor authority
    /// (`KernelFinalizationWiring.emptyOutputRecoveryFloor`) and, when
    /// lexical, follows the ordinary store → deliver → `.completed` path.
    @Test("a processText throw with lexical raw ASR stores and delivers the raw text once")
    func processTextThrowLexicalRawDelivers() async {
      let (context, wrapper) = makeWrapper(behavior: .batchSuccess(text: "raw text"))
      wrapper.testProcessTextThrows()
      let kernel = wrapper.testKernel

      await startRecording(context)
      await context.sut.apply(.stop)
      await wrapper.drainReadyWork()

      #expect(
        wrapper.telemetryState.transcriptionFailureError as? KernelLimbError
          == .emptyAfterProcessing,
        "the exact processing error must remain on the diagnostics side-channel")
      #expect(wrapper.storedTexts == ["raw text"], "storage receives exactly the raw ASR")
      #expect(
        context.paste.pasteAttempts == ["raw text"],
        "the delivery seam is called exactly once with the raw ASR")
      #expect(context.paste.pasteCount == 1, "delivery happens exactly once")
      #expect(kernel.deliveredTranscript == "raw text")
      #expect(kernel.recordingOutcome == .completed)
      #expect(
        KernelDictationDriver.recoveryEnding(for: .completed) == nil,
        "a completed dictation requests no ended-without-save recovery ending")
      #expect(kernel.recordingOutcome != .failed(.emptyAfterProcessing))
    }

    /// The quiet twin: filler-only raw ASR has nothing worth saving — the
    /// floor returns empty and the session ends `.noSpeech(.emptyAfterProcessing)`
    /// with zero storage and zero delivery (never `.completed`, never `.failed`).
    @Test("a processText throw with filler-only raw ASR ends quietly as no-speech")
    func processTextThrowFillerOnlyEndsNoSpeech() async {
      let (context, wrapper) = makeWrapper(behavior: .batchSuccess(text: "uh"))
      wrapper.testProcessTextThrows()
      let kernel = wrapper.testKernel

      await startRecording(context)
      await context.sut.apply(.stop)
      await wrapper.drainReadyWork()

      #expect(
        wrapper.telemetryState.transcriptionFailureError as? KernelLimbError
          == .emptyAfterProcessing,
        "the exact processing error must remain on the diagnostics side-channel")
      #expect(kernel.recordingOutcome == .noSpeech(.emptyAfterProcessing))
      #expect(wrapper.storedTexts.isEmpty, "storage receives zero calls")
      #expect(context.paste.pasteAttempts.isEmpty, "the delivery seam is never called")
      #expect(kernel.deliveredTranscript == nil)
      #expect(kernel.recordingOutcome != .completed)
      if case .failed = kernel.recordingOutcome {
        Issue.record("a filler-only processing throw must never be a .failed terminal")
      }
    }

    // MARK: 1c. #1755 chunk 4 — #1709 salvage-cancelled breadcrumb (exact cell only)

    /// ONE synchronous MainActor test with no suspension points: the
    /// process-global SentryBreadcrumb delegate is swapped in, every cell is
    /// driven synchronously, and the PRIOR delegate is preserved, forwarded
    /// unrelated breadcrumbs, and restored. The no-suspension window is the
    /// real protection — a previously installed delegate survives; a truly
    /// concurrent writer to the same global could still race it, which this
    /// test cannot prevent.
    @Test("the .asr + .cancelled floor cell emits exactly one asr_salvage_cancelled breadcrumb; siblings stay silent")
    func asrSalvageCancelledBreadcrumbExactCellOnly() {
      nonisolated(unsafe) var matches: [[String: String]] = []
      let prior = SentryBreadcrumb.breadcrumbDelegate
      SentryBreadcrumb.breadcrumbDelegate = { stage, message, level, data in
        guard message == "asr_salvage_cancelled" else {
          prior?(stage, message, level, data)  // forward unrelated crumbs
          return
        }
        matches.append(
          ["stage": stage]
            .merging((data ?? [:]).compactMapValues { $0 as? String }) { a, _ in a })
      }
      defer { SentryBreadcrumb.breadcrumbDelegate = prior }

      // Eligible cell: .asr source + .cancelled.
      let (_, eligible) = makeWrapper()
      eligible.telemetryState.interruptedSalvageSource = .asr
      let floored = eligible.testKernel.testInterruptedTerminalFloor(.cancelled)
      #expect(floored == .cancelled, "the terminal itself is unchanged")
      #expect(eligible.telemetryState.asrSalvageOutcome == .cancelled)
      #expect(matches.count == 1, "exactly one breadcrumb for the eligible cell")
      #expect(
        matches.first == ["stage": "recovery", "asr_salvage_outcome": "cancelled"],
        "exact shape: stage recovery + the single data field")

      // Adversarial siblings, same delegate, still synchronous.
      let (_, sibling1) = makeWrapper()
      sibling1.telemetryState.interruptedSalvageSource = .asr
      _ = sibling1.testKernel.testInterruptedTerminalFloor(.failed(.asrFailed))
      let (_, sibling2) = makeWrapper()
      sibling2.telemetryState.interruptedSalvageSource = .engine(.deviceRemoved)
      _ = sibling2.testKernel.testInterruptedTerminalFloor(.cancelled)
      let (_, sibling3) = makeWrapper()
      _ = sibling3.testKernel.testInterruptedTerminalFloor(.cancelled)
      #expect(matches.count == 1, "no sibling cell may emit the salvage-cancelled breadcrumb")
    }

    // MARK: 2. The floor — salvage never deletes a spool today's code would keep

    /// The pair that proves the floor. Same early terminal (`bufferCount == 0`
    /// trips the minimum-recording gate), different exit.
    ///
    /// A too-short USER stop keeps discarding, spool deleted, exactly as today.
    /// A too-short INTERRUPTED recording must NOT discard: without the floor it
    /// would reach `.discarded`, whose terminal kind is `.discard` — "delete the
    /// spool now" — destroying the only surviving copy of a recording the user
    /// never chose to be told they "said nothing" about.
    // The PAIR that proves the floor (#1548 D1): identical sub-minimum setup —
    // one real buffer (so the session reaches `.live` under the transport gate)
    // but below the tick-based minimum-recording gate (the clock never advances)
    // — different exit. A too-short USER stop still discards; a too-short
    // INTERRUPTED recording floors to `.audioInterrupted` (honest notice). The
    // old zero-buffer arm is unreachable now: with no buffer the session never
    // reaches `.live`, so it cannot be interrupted mid-recording at all.
    @Test("a sub-minimum USER stop still discards (the floor is inert outside salvage)")
    func subMinimumUserStopStillDiscards() async {
      let (context, wrapper) = makeWrapper(minimumRecordingTicks: 5)
      await startRecording(context, buffers: 1)

      await context.sut.apply(.stop)
      await context.sut.drainReadyWork()

      #expect(wrapper.testKernel.recordingOutcome == .discarded(.tooShort))
      #expect(
        deletesRecoverySpool(.discarded(.tooShort)),
        "an ordinary too-short tap is still safe to delete")
    }

    @Test("a sub-minimum INTERRUPTED recording floors to .audioInterrupted, not .discarded")
    func subMinimumInterruptedFloorsRatherThanDiscards() async {
      let (context, wrapper) = makeWrapper(minimumRecordingTicks: 5)
      await startRecording(context, buffers: 1)

      // The clock never advances, so the elapsed window is below the minimum —
      // the same sub-minimum gate the user-stop pair lands on, but interrupted.
      wrapper.testKernel.externalEngineInterrupted(.engineLost)
      await wrapper.drainReadyWork()

      #expect(wrapper.testKernel.recordingOutcome == .audioInterrupted(.engineLost))
      // #1755: the floor now preserves honest TERMINAL/notice semantics only —
      // `.audioInterrupted` tells the user what happened; the disk disposition
      // is best-effort deletion like every concluded live ending.
      #expect(deletesRecoverySpool(.audioInterrupted(.engineLost)))
    }

    /// The tick-driven arm of the same gate, with the minimum-recording
    /// threshold actually ARMED (the scenario inventory zeroes it). No clock is
    /// advanced, so the elapsed window is below the threshold.
    @Test("the floor also covers the TIME arm of the minimum-recording gate")
    func subMinimumByElapsedTicksAlsoFloors() async {
      let (context, wrapper) = makeWrapper(minimumRecordingTicks: 5)
      await startRecording(context, buffers: 2)

      wrapper.testKernel.externalEngineInterrupted(.engineLost)
      await wrapper.drainReadyWork()

      #expect(wrapper.testKernel.recordingOutcome.kind == .audioInterrupted)
    }

    /// Salvaged audio that transcribes to nothing. Without the floor this lands
    /// `.noSpeech` → `.discard` → spool deleted. The post-ASR no-speech terminal
    /// is built from a ternary at its call site, which is exactly why the floor
    /// lives inside `finishTerminal` rather than at the call sites.
    @Test("salvaged audio with no speech floors to .audioInterrupted, not .noSpeech")
    func salvagedAudioWithNoSpeechFloors() async {
      let (context, wrapper) = makeWrapper()
      context.vad.evidence = .confirmedNoSpeech
      // Below the #964 dead-air floor: the VAD gate skips ASR only when the raw
      // buffer is ALSO dead air, otherwise it transcribes to recover faint speech.
      await startRecording(context, amplitude: 0.001)

      wrapper.testKernel.externalEngineInterrupted(.engineLost)
      await wrapper.drainReadyWork()

      #expect(wrapper.testKernel.recordingOutcome.kind == .audioInterrupted)
      #expect(context.paste.pasteCount == 0)
    }

    /// The POST-ASR no-speech path, which is a different terminal site from the
    /// VAD-gate one above: it is built from a ternary
    /// (`effectiveSpeechEvidence ? .failed(.asrEmpty) : .noSpeech`) that a
    /// call-site floor cannot wrap and a `grep finishTerminal(.noSpeech` does not
    /// match. It also transitions from `.transcribing`, not `.stopping` — and
    /// `.finalizing → .audioInterrupted` is an ILLEGAL transition, so a floor
    /// applied one step later would be silently rejected and wedge the session
    /// with no terminal at all. This test proves the rewritten transition is
    /// accepted and the session actually terminates.
    @Test("the post-ASR no-speech ternary is floored, and the transition is legal")
    func postASRNoSpeechTernaryIsFlooredWithoutWedging() async {
      let (context, wrapper) = makeWrapper(behavior: .empty(hadSpeechEvidence: false))
      // Above the dead-air floor, so the VAD gate does NOT short-circuit and the
      // session reaches the adapter, decodes empty, and lands on the ternary.
      context.vad.evidence = .confirmedNoSpeech
      await startRecording(context, amplitude: 0.1)

      wrapper.testKernel.externalEngineInterrupted(.engineLost)
      await wrapper.drainReadyWork()

      #expect(
        wrapper.testKernel.recordingOutcome.kind == .audioInterrupted,
        "reached \(String(describing: wrapper.testKernel.recordingOutcome)) — a wedge would leave no outcome"
      )
      #expect(wrapper.testKernel.recordingOutcome != nil, "the session must not wedge")
      #expect(context.paste.pasteCount == 0)
    }

    /// Every terminal the floor rewrites must be reachable from the state its
    /// call site runs in. A rewrite into an illegal transition is refused by
    /// `transition(to:)`, `finishTerminal` returns early, and the app hangs with a
    /// live overlay and no terminal. Drive each floored site for real.
    @Test(
      "every floored terminal site actually terminates (no illegal-transition wedge)",
      arguments: [
        // Each floored site delivers ≥1 buffer to reach `.live` (#1548 D1); the
        // sub-minimum-discard site trips the tick-based gate (clock never advances).
        FlooredSite(
          name: "sub-minimum discard", minimumRecordingTicks: 5, buffers: 1, amplitude: 0.1,
          deadAirVAD: false),
        FlooredSite(
          name: "VAD-gate no-speech", minimumRecordingTicks: 0, buffers: 1, amplitude: 0.001,
          deadAirVAD: true),
      ])
    func everyFlooredSiteTerminates(site: FlooredSite) async {
      let (context, wrapper) = makeWrapper(minimumRecordingTicks: site.minimumRecordingTicks)
      if site.deadAirVAD { context.vad.evidence = .confirmedNoSpeech }
      await startRecording(context, buffers: site.buffers, amplitude: site.amplitude)

      wrapper.testKernel.externalEngineInterrupted(.engineLost)
      await wrapper.drainReadyWork()

      #expect(
        wrapper.testKernel.recordingOutcome.kind == .audioInterrupted,
        "\(site.name): reached \(String(describing: wrapper.testKernel.recordingOutcome))")
      #expect(wrapper.testKernel.recordingOutcome != nil, "\(site.name): wedged")
    }

    /// THE INVARIANT. Absent an explicit user cancel, a session whose exit was
    /// a salvageable interruption terminates in exactly one of two states —
    /// `.completed` or `.audioInterrupted` (#1755: both request best-effort
    /// deletion; the invariant is about terminal honesty, not disk state).
    @Test(
      "invariant: a live salvageable interruption ends .completed or .audioInterrupted, never a third state",
      // #1548 D1: a genuine interruption is only reachable from `.live`, which
      // requires ≥1 buffer — the old zero-buffer case is dropped (a zero-buffer
      // session concludes via the no-transport deadline, not an interruption).
      arguments: EngineInterruptionCause.allCases.filter(\.hasRecoverableAudio), [1, 3])
    func salvageTerminatesInExactlyTwoStates(
      cause: EngineInterruptionCause, bufferCount: Int
    ) async {
      let (context, wrapper) = makeWrapper()
      await startRecording(context, buffers: bufferCount)

      wrapper.testKernel.externalEngineInterrupted(cause)
      await wrapper.drainReadyWork()

      let terminal = wrapper.testKernel.recordingOutcome
      #expect(
        terminal.kind == .completed || terminal.kind == .audioInterrupted,
        "salvage produced a third terminal: \(String(describing: terminal))")
      if terminal.kind != .completed, let outcome = terminal {
        // #1755: every non-completed live ending now requests deletion.
        #expect(deletesRecoverySpool(outcome))
      }
    }

    /// The one sanctioned third outcome. A user who sees the disconnect notice
    /// and cancels has asked us to stop; flooring `.cancelled` would override
    /// that explicit instruction with an interruption notice. Its provenance
    /// belongs to the driver's `pendingCancelOrigin` (#1755: both origins
    /// delete), not to the floor.
    @Test("an explicit cancel during a salvage is honored, never floored")
    func explicitCancelDuringSalvageIsNotFloored() async {
      // `slowFinalize` dwells inside `.transcribing`, which is how the inventory
      // places a cancel deterministically mid-tail (A8). Without it the salvage
      // runs to `.completed` before a cancel can land.
      let (context, wrapper) = makeWrapper(
        behavior: .slowFinalize(ticksToFinal: 4, text: "hello"))
      await startRecording(context)

      wrapper.testKernel.externalEngineInterrupted(.engineLost)
      await wrapper.drainReadyWork()
      #expect(
        wrapper.testKernel.state == .delivering
          && wrapper.testKernel.deliveringPhase == .transcribing,
        "precondition: the salvage tail must still be in flight, got \(wrapper.testKernel.state)/\(wrapper.testKernel.deliveringPhase)"
      )

      await wrapper.apply(.cancel)
      await wrapper.drainReadyWork()

      #expect(wrapper.testKernel.recordingOutcome == .cancelled)
      #expect(context.paste.pasteCount == 0)
      #expect(
        KernelDictationDriver.recoveryEnding(for: .cancelled) == nil,
        "`.cancelled` is resolved dynamically by pendingCancelOrigin, not the static projection")
    }

    /// Every ending outcome the FSM can conclude with (#1548 D1: the ending
    /// category moved off the state onto `RecordingOutcome`). `RecordingOutcome`
    /// has associated values so it cannot be `CaseIterable`; this list is the
    /// manual mirror, and `KernelDictationDriver.recoveryEnding` is an exhaustive
    /// switch, so a new outcome forces a decision there and gets caught here.
    /// Payloads are arbitrary valid values — the floor + the projection only read
    /// the category, never the reason.
    private static let allTerminals: [RecordingOutcome] = [
      .completed, .cancelled, .discarded(.tooShort), .noSpeech(.vadGate),
      .audioInterrupted(nil), .asrInterrupted(wasRecording: false), .noTransport,
      .failed(.prepareFailed), .failed(.permissionDenied), .failed(.modelWedged),
      .failed(.modelLoadFailed), .failed(.captureStartFailed), .failed(.noAudioCaptured),
      .failed(.asrEmpty), .failed(.asrFailed), .failed(.asrWedged),
      .failed(.emptyAfterProcessing), .failed(.captureStalled),
      // #1755 chunk 5: the two cases the "every terminal" claim omitted.
      .failed(.noMicrophoneFound), .failed(.zeroSignal),
    ]

    /// #1755 rewrite: under the discard doctrine EVERY concluded live ending
    /// deletes, so "the floor protects the spool" is obsolete. The floor's
    /// remaining job is TERMINAL/NOTICE honesty: exactly its original mapped
    /// set (`.discarded` / `.noSpeech` / `.failed(.noAudioCaptured)`) floors
    /// to `.audioInterrupted` so the user is told the mic died rather than
    /// "you said nothing"; every other terminal passes through, and every
    /// non-completed terminal now requests deletion at the coordinator.
    @Test("the floor keeps its exact terminal-honesty set; every non-completed terminal deletes")
    func floorKeepsTerminalHonestySetAndEverythingDeletes() async {
      let (_, wrapper) = makeWrapper()
      wrapper.telemetryState.interruptionCause = .engineLost
      let kernel = wrapper.testKernel

      for terminal in Self.allTerminals {
        let floored = kernel.testInterruptedTerminalFloor(terminal)
        switch terminal {
        case .discarded, .noSpeech, .failed(.noAudioCaptured):
          #expect(
            floored.kind == .audioInterrupted,
            "\(terminal) is in the floor's honesty set and must floor")
        default:
          #expect(floored == terminal, "\(terminal) must pass through unchanged")
        }
        if floored.kind != .completed, floored.kind != .cancelled {
          #expect(deletesRecoverySpool(floored), "\(floored) must request deletion (#1755)")
        }
      }
    }

    /// The floor must not over-reach. A user who cancels has asked us to stop;
    /// a completion delivered a transcript; every other `.failed` reason keeps
    /// its own honest cause (#1755: all of them delete at the coordinator).
    @Test("the floor leaves every terminal outside its honesty set alone")
    func floorLeavesOtherTerminalsAlone() async {
      let (_, wrapper) = makeWrapper()
      wrapper.telemetryState.interruptionCause = .deviceRemoved
      let kernel = wrapper.testKernel

      #expect(kernel.testInterruptedTerminalFloor(.completed) == .completed)
      #expect(
        kernel.testInterruptedTerminalFloor(.cancelled) == .cancelled,
        "an explicit user cancel is never overridden")
      #expect(
        kernel.testInterruptedTerminalFloor(.asrInterrupted(wasRecording: false))
          == .asrInterrupted(wasRecording: false))
      #expect(kernel.testInterruptedTerminalFloor(.failed(.asrEmpty)) == .failed(.asrEmpty))
      #expect(kernel.testInterruptedTerminalFloor(.failed(.asrFailed)) == .failed(.asrFailed))
      // Folded in with the other two no-transcript endings: all three land on
      // one honest terminal so none keeps a different overlay for a reason no
      // user could name.
      #expect(
        kernel.testInterruptedTerminalFloor(.failed(.noAudioCaptured)).kind == .audioInterrupted)
    }

    // MARK: 2b. The floor is unconditional — the SENTENCE is what varies

    /// HONESTY, for every cause. A no-transcript terminal is rewritten no
    /// matter which interruption fired: letting the cap fall through to
    /// `.discarded` because "no microphone disconnected" would tell the user
    /// "you said nothing" when the take was cut short. The cause-specific
    /// sentence belongs to the message; the honest CATEGORY to the terminal.
    @Test(
      "every no-transcript terminal is floored for EVERY recoverable cause",
      arguments: EngineInterruptionCause.allCases.filter(\.hasRecoverableAudio))
    func spoolDeletingTerminalsAreFlooredForEveryCause(cause: EngineInterruptionCause) async {
      let (_, wrapper) = makeWrapper()
      wrapper.telemetryState.interruptionCause = cause
      let kernel = wrapper.testKernel

      #expect(kernel.testInterruptedTerminalFloor(.discarded(.tooShort)).kind == .audioInterrupted)
      #expect(kernel.testInterruptedTerminalFloor(.noSpeech(.vadGate)).kind == .audioInterrupted)
      #expect(
        kernel.testInterruptedTerminalFloor(.failed(.noAudioCaptured)).kind == .audioInterrupted)
    }

    // MARK: 2c. #1707 — the ASR-interruption source is WIDER than .engine

    /// The `.asr` salvage source promises the SAME terminal every failure
    /// mode already produced before salvage existed — not just the
    /// deletion-class subset `.engine` protects (grounded review r4's
    /// widened-floor correction). Only a genuine delivery (`.completed`) or
    /// an explicit user cancel passes through unchanged.
    @Test("the ASR-interruption source floors every unsuccessful outcome, wider than .engine")
    func asrSourceFloorsEveryUnsuccessfulOutcome() async {
      let (_, wrapper) = makeWrapper()
      wrapper.telemetryState.interruptedSalvageSource = .asr
      let kernel = wrapper.testKernel

      for terminal in Self.allTerminals {
        let floored = kernel.testInterruptedTerminalFloor(terminal)
        switch terminal {
        case .completed, .cancelled:
          #expect(floored == terminal, "\(terminal) must pass through unchanged")
        default:
          #expect(
            floored == .asrInterrupted(wasRecording: true),
            "\(terminal) must float to the ASR-interruption terminal under the .asr source")
        }
      }
    }

    /// The end-to-end proof of grounded review r2/r3's central finding: a
    /// salvage decode can succeed (non-empty raw text), enter `.finalizing`,
    /// and STILL reach a no-transcript terminal if processing empties the
    /// result — a state where NO `.asrInterrupted` payload was legal before
    /// this fix's narrowly-widened `isLegalConclusion`. Proves the floor, the
    /// widened legality, and the no-wedge guarantee together, for real,
    /// through the actual `runFinalizing` path — not a bare unit call.
    @Test(
      "finalizing floor: a salvage decode that succeeds but polish empties still lands on .asrInterrupted(true), no wedge"
    )
    func finalizingFloorCatchesEmptyAfterProcessing() async {
      let (context, wrapper) = makeWrapper(behavior: .batchSuccess(text: "hello"))
      wrapper.testForceEmptyAfterProcessing()
      let kernel = wrapper.testKernel

      await startRecording(context)
      kernel.externalASRInterrupted()
      await wrapper.drainReadyWork()

      #expect(
        kernel.recordingOutcome == .asrInterrupted(wasRecording: true),
        "reached \(String(describing: kernel.recordingOutcome)) — a wedge would leave no outcome")
      #expect(kernel.recordingOutcome != nil, "the session must not wedge")
      #expect(
        deletesRecoverySpool(.asrInterrupted(wasRecording: true)),
        "#1755: the interruption terminal keeps its honest copy but now deletes")
      #expect(context.paste.pasteCount == 0)
      #expect(
        kernel.lastASRSalvageOutcome == .decodeFailed,
        "Codex code-diff r2: a rewarm that succeeded but decode/processing that didn't must read as decodeFailed, not rewarmFailed"
      )
    }

    /// The recovery capability's `.cancelled` outcome (superseded attempt) is
    /// handled identically to `.failed` — both mean "do not decode," never a
    /// distinct terminal.
    @Test("a .cancelled recovery outcome floors to the ASR-interrupted terminal, same as .failed")
    func asrRecoveryCancelledFloors() async {
      let (context, wrapper) = makeWrapper()
      context.engine.asrInterruptionRecoveryResult = .cancelled
      let kernel = wrapper.testKernel

      await startRecording(context)
      kernel.externalASRInterrupted()
      await wrapper.drainReadyWork()

      #expect(kernel.recordingOutcome == .asrInterrupted(wasRecording: true))
      #expect(context.paste.pasteCount == 0)
      #expect(context.engine.recoverFromASRInterruptionCallCount == 1)
      #expect(kernel.lastASRSalvageOutcome == .cancelled)
    }

    /// #1408 A3 retired `.maxDurationReached`: the hard cap is a normal
    /// auto-stop routed through the typed `.maxDuration` exit, so it can no
    /// longer stamp a cause, reach the floor, or claim an interruption at all.
    /// This freeze keeps the retirement honest — a resurrected cap case would
    /// change the enum's shape and redden here before it could lie again.
    @Test("the cause enum has exactly the two genuine interruption causes")
    func causeEnumHasNoDurationCap() {
      // #1543 retired the XPC-connection cause with the audio-capture boundary;
      // both survivors are genuine, recoverable, in-process capture losses.
      #expect(
        EngineInterruptionCause.allCases == [
          .deviceRemoved, .engineLost,
        ])
      #expect(EngineInterruptionCause(rawValue: "max_duration_reached") == nil)
      // #1524 retired the capture-session backend and its cause with it; #1543
      // retired the XPC-connection cause. Neither wire value resolves any more.
      #expect(EngineInterruptionCause(rawValue: "capture_session_lost") == nil)
      #expect(EngineInterruptionCause(rawValue: "xpc_connection_lost") == nil)
    }

    /// Outside an interruption the floor is a no-op on every terminal. If it
    /// were not, an ordinary too-short tap would read as a mic interruption.
    @Test("with no interruption stamped, the floor is the identity function")
    func floorIsInertWithoutACause() async {
      let (_, wrapper) = makeWrapper()
      let kernel = wrapper.testKernel
      #expect(wrapper.telemetryState.interruptionCause == nil)

      for terminal in Self.allTerminals {
        #expect(
          kernel.testInterruptedTerminalFloor(terminal) == terminal,
          "\(terminal) was rewritten outside an interruption")
      }
    }

    // MARK: 3. The single home — one writer, one clearer

    /// The cause now lives on the shared `KernelTelemetryState`, cleared ONLY
    /// by `resetForNewSession()`. Two clearers would let a stale cause leak
    /// into the next session, and the floor would then mislabel an ordinary
    /// too-short tap as `.audioInterrupted` — a wrong notice (#1755: never a
    /// retention change). This test is the guard.
    @Test("a fresh session starts with no cause, even after an interrupted one")
    func causeDoesNotLeakAcrossSessions() async {
      let (context, wrapper) = makeWrapper()
      await startRecording(context)
      wrapper.testKernel.externalEngineInterrupted(.engineLost)
      await wrapper.drainReadyWork()
      #expect(wrapper.testKernel.lastAudioInterruptionCause == .engineLost)

      await wrapper.apply(.reset)
      await wrapper.apply(.start)
      await wrapper.drainReadyWork()

      #expect(
        wrapper.testKernel.lastAudioInterruptionCause == nil,
        "a stale cause would mislabel the next ordinary too-short tap as an interruption")

      // And the floor is genuinely inert again: an ordinary stop discards.
      await wrapper.apply(.stop)
      await wrapper.drainReadyWork()
      #expect(wrapper.testKernel.recordingOutcome.kind == .discarded)
    }

    /// The kernel's property is a read-through, not a second copy. The finalization
    /// wiring and the lifecycle sink read the same object, so a divergence here
    /// would silently disable the History badge and the telemetry.
    @Test("the kernel's cause reads through to the shared telemetry holder")
    func kernelCauseReadsThroughToSharedHolder() async {
      let (context, wrapper) = makeWrapper()
      await startRecording(context)

      wrapper.testKernel.externalEngineInterrupted(.engineLost)
      await wrapper.drainReadyWork()

      #expect(wrapper.telemetryState.interruptionCause == .engineLost)
      #expect(
        wrapper.testKernel.lastAudioInterruptionCause == wrapper.telemetryState.interruptionCause)
    }

    // #1543: the "racing second interruption cannot flip an unsalvageable cause
    // to a salvageable one" test is gone — in-process both surviving causes are
    // salvageable, so there is no unsalvageable cause to protect. The first-wins
    // cause-preservation invariant is covered by `doubleEngineFirstCauseWins` in
    // RecordingSessionKernelExternalInterruptionTests.
  }

  // MARK: - The predicate itself (#1408)

  @Suite("EngineInterruptionCause.hasRecoverableAudio (#1408)")
  struct EngineInterruptionCauseRecoverabilityTests {

    /// `salvage_attempted` in telemetry and the kernel's salvage guard read this
    /// one property. In-process (#1543) the capture manager always holds the
    /// samples, so every surviving cause is recoverable — the unrecoverable set
    /// is empty. If a future cause is added unrecoverable, this reddens.
    @Test("in-process, no interruption cause is unrecoverable")
    func noCauseIsUnrecoverableInProcess() {
      let unrecoverable = EngineInterruptionCause.allCases.filter { !$0.hasRecoverableAudio }
      #expect(unrecoverable.isEmpty)
    }

    /// `isDeviceLoss` is a distinct question from recoverability. An engine that
    /// failed to recover with the device still attached is salvaged like a
    /// disconnect but is not one: telling that user "Microphone disconnected," or
    /// badging their transcript with a crossed-out microphone, would describe an
    /// event that never happened.
    @Test("an engine loss is recoverable but is NOT a device loss")
    func engineLossIsRecoverableButNotDeviceLoss() {
      #expect(EngineInterruptionCause.engineLost.hasRecoverableAudio)
      #expect(!EngineInterruptionCause.engineLost.isDeviceLoss)
    }

    /// Exactly one cause is backed by a real `DeviceIsAlive` check. `.engineLost`
    /// also covers a recovery timeout and a failed engine restart with the mic
    /// still attached, so it is excluded.
    @Test("only .deviceRemoved is a device loss")
    func deviceLossSetIsExactlyDeviceRemoved() {
      let deviceLosses = EngineInterruptionCause.allCases.filter(\.isDeviceLoss)
      #expect(deviceLosses == [.deviceRemoved])
    }

    /// The split's whole point. `.engineLost` used to mean both of these, and the
    /// disclosure could not tell them apart.
    @Test("an engine that failed to recover is salvageable but is not a disconnect")
    func engineLostIsSalvageableButNotADisconnect() {
      #expect(EngineInterruptionCause.engineLost.hasRecoverableAudio)
      #expect(!EngineInterruptionCause.engineLost.isDeviceLoss)
      #expect(EngineInterruptionCause.deviceRemoved.hasRecoverableAudio)
      #expect(EngineInterruptionCause.deviceRemoved.isDeviceLoss)
    }

    /// Recoverability and device-loss are different questions. In-process every
    /// cause is recoverable, but only a verified removal is a device loss, so
    /// device-loss is a strict subset of recoverable.
    @Test("device-loss is a strict subset of recoverable")
    func deviceLossIsStrictSubsetOfRecoverable() {
      let recoverable = Set(EngineInterruptionCause.allCases.filter(\.hasRecoverableAudio))
      let deviceLoss = Set(EngineInterruptionCause.allCases.filter(\.isDeviceLoss))
      // An engine loss is salvageable but is not a disconnect...
      #expect(recoverable.contains(.engineLost))
      #expect(!deviceLoss.contains(.engineLost))
      // ...so device-loss is strictly smaller than the recoverable set.
      #expect(deviceLoss.isStrictSubset(of: recoverable))
    }
  }

  // MARK: - The interruption sentence

  /// #1408 (Codex code-diff r4, founder-approved copy). `.audioInterrupted` is
  /// now the single no-transcript terminal for EVERY interruption, so it can no
  /// longer carry "Microphone disconnected" unconditionally — that string was a
  /// lie for a recovery failure, the duration cap, and our own helper crashing.
  ///
  /// #1558: the interruption copy authority moved from `InterruptionMessages`
  /// to the typed map (`KernelDictationDriver.terminalNoticeReason(for:)`) plus
  /// the AppKit presenter. These tests keep the claim honest at the TYPED-reason
  /// layer: only a verified device loss earns the disconnect reason; the
  /// customer sentence itself is frozen in `DictationNarratorTests`.
  @Suite("The interruption reason never claims more than we know (#1408 / #1558)")
  struct InterruptionReasonTests {

    @Test("only a verified device loss maps to the disconnect reason")
    func onlyDeviceLossMapsToDisconnectReason() {
      for cause in EngineInterruptionCause.allCases {
        let reason = KernelDictationDriver.terminalNoticeReason(for: cause)
        if cause.isDeviceLoss {
          #expect(reason == .deviceRemoved, "\(cause) earns the disconnect reason")
        } else {
          #expect(
            reason == .engineLost,
            "\(cause) is not a microphone walking away, so it must not claim one did")
        }
      }
    }

    /// The set mapping to `.deviceRemoved` is exactly the `isDeviceLoss` set —
    /// coupled, so a new cause cannot inherit the disconnect reason by accident.
    @Test("the disconnect-reason set is exactly the isDeviceLoss set")
    func disconnectReasonSetEqualsDeviceLossSet() {
      let claims = Set(
        EngineInterruptionCause.allCases.filter {
          KernelDictationDriver.terminalNoticeReason(for: $0) == .deviceRemoved
        })
      let deviceLoss = Set(EngineInterruptionCause.allCases.filter(\.isDeviceLoss))
      #expect(claims == deviceLoss)
      #expect(claims == [.deviceRemoved])
    }

    /// A no-stamped-cause interruption should never be reachable (the kernel
    /// refuses salvage and logs), but if it ever is, the absence of evidence
    /// must map to the neutral reason, never a disconnect.
    @Test("no stamped cause falls back to the neutral reason, never a disconnect")
    func missingCauseIsNeutral() {
      #expect(
        KernelDictationDriver.terminalNoticeReason(for: EngineInterruptionCause?.none)
          == .unknownInterruption)
    }
  }

#endif
