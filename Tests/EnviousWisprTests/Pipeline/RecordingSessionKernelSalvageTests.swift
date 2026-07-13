import EnviousWisprAudio
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

// MARK: - #1408 — salvage a dictation whose capture was interrupted mid-recording
//
// Before this change, a microphone that died mid-sentence sent the recording
// straight to `.audioInterrupted` and the audio the capture manager was still
// holding was never transcribed. Now a salvageable interruption falls through
// into the normal stop tail.
//
// Two properties are under test, and the second is the one that matters:
//
//   1. Salvage happens for the causes that leave audio in memory, and does NOT
//      happen for the one cause whose sample owner is gone.
//   2. THE FLOOR. Salvage may only ever ADD a transcript. It must never turn a
//      terminal that RETAINS the crash-recovery spool into one that DELETES it.
//      Falling through means an interrupted recording now meets the same early
//      terminals a normal stop does (`.discarded`, `.noSpeech`,
//      `.failed(.noAudioCaptured)`) — and two of those delete the spool. The
//      floor maps them back to `.audioInterrupted`, precisely the terminal this
//      session reached before salvage existed.
//
// The floor's proof is a PAIR: identical early-terminal trigger, different exit.
// A too-short user stop must still `.discarded` (spool deleted, unchanged); a
// too-short interrupted recording must land `.audioInterrupted` (spool retained).

#if DEBUG

  /// One floored terminal site, as data, so the parametric test names which site
  /// wedged rather than reporting a bare state mismatch.
  struct FlooredSite: Sendable, CustomStringConvertible {
    let name: String
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

      #expect(wrapper.testKernel.state == .completed)
      #expect(context.paste.pasteCount == 1)
      #expect(wrapper.testKernel.lastAudioInterruptionCause == cause)
      // The dictation is a salvage, and `stop_reason` says so for free.
      #expect(wrapper.testKernel.lastStopReason == "audio_interruption")
    }

    /// The helper process that OWNED the samples is gone. There is nothing to
    /// transcribe, so we must fail honestly rather than paste an empty string —
    /// even though a full buffer is sitting in the fake's array. This is the
    /// adversarial half of `matcher-set-adversarial-tests`: the unsalvageable
    /// cause is exercised WITH audio present and must still refuse.
    @Test("the unsalvageable cause refuses salvage even with a full buffer")
    func xpcConnectionLostRefusesSalvage() async {
      let (context, wrapper) = makeWrapper()
      await startRecording(context, buffers: 3)

      wrapper.testKernel.externalEngineInterrupted(.xpcConnectionLost)
      await wrapper.drainReadyWork()

      #expect(wrapper.testKernel.state == .audioInterrupted)
      #expect(context.paste.pasteCount == 0)
      #expect(
        KernelDictationDriver.endedWithoutSaveKind(for: .audioInterrupted) == .failure,
        "an unsalvaged interruption must RETAIN the crash-recovery spool")
    }

    // MARK: 2. The floor — salvage never deletes a spool today's code would keep

    /// The pair that proves the floor. Same early terminal (`bufferCount == 0`
    /// trips the minimum-recording gate), different exit.
    ///
    /// A too-short USER stop keeps discarding, spool deleted, exactly as today.
    /// A too-short INTERRUPTED recording must NOT discard: without the floor it
    /// would reach `.discarded`, whose terminal kind is `.discard` — "delete the
    /// spool now" — destroying the only surviving copy of a recording the user
    /// never chose to throw away.
    @Test("a sub-minimum USER stop still discards (the floor is inert outside salvage)")
    func subMinimumUserStopStillDiscards() async {
      let (context, wrapper) = makeWrapper()
      await context.sut.apply(.start)
      await context.sut.drainReadyWork()

      await context.sut.apply(.stop)
      await context.sut.drainReadyWork()

      #expect(wrapper.testKernel.state == .discarded)
      #expect(
        KernelDictationDriver.endedWithoutSaveKind(for: .discarded) == .discard,
        "an ordinary too-short tap is still safe to delete")
    }

    @Test("a sub-minimum INTERRUPTED recording floors to .audioInterrupted, not .discarded")
    func subMinimumInterruptedFloorsRatherThanDiscards() async {
      let (_, wrapper) = makeWrapper()
      await wrapper.apply(.start)
      await wrapper.drainReadyWork()

      // No buffers delivered — `bufferCountThisSession == 0` trips the same
      // minimum-recording gate the user-stop test above lands on.
      wrapper.testKernel.externalEngineInterrupted(.engineLost)
      await wrapper.drainReadyWork()

      #expect(wrapper.testKernel.state == .audioInterrupted)
      #expect(
        KernelDictationDriver.endedWithoutSaveKind(for: .audioInterrupted) == .failure,
        "the floor must convert the spool-deleting terminal into a spool-retaining one")
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

      #expect(wrapper.testKernel.state == .audioInterrupted)
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

      #expect(wrapper.testKernel.state == .audioInterrupted)
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
        wrapper.testKernel.state == .audioInterrupted,
        "reached \(wrapper.testKernel.state) — a wedge would leave a non-terminal state")
      #expect(wrapper.testKernel.state.isTerminal, "the session must not wedge")
      #expect(context.paste.pasteCount == 0)
    }

    /// Every terminal the floor rewrites must be reachable from the state its
    /// call site runs in. A rewrite into an illegal transition is refused by
    /// `transition(to:)`, `finishTerminal` returns early, and the app hangs with a
    /// live overlay and no terminal. Drive each floored site for real.
    @Test(
      "every floored terminal site actually terminates (no illegal-transition wedge)",
      arguments: [
        // (engine behavior, vad evidence, buffers, amplitude) -> each floored site
        FlooredSite(name: "sub-minimum discard", buffers: 0, amplitude: 0.1, deadAirVAD: false),
        FlooredSite(name: "VAD-gate no-speech", buffers: 1, amplitude: 0.001, deadAirVAD: true),
      ])
    func everyFlooredSiteTerminates(site: FlooredSite) async {
      let (context, wrapper) = makeWrapper()
      if site.deadAirVAD { context.vad.evidence = .confirmedNoSpeech }
      await startRecording(context, buffers: site.buffers, amplitude: site.amplitude)

      wrapper.testKernel.externalEngineInterrupted(.engineLost)
      await wrapper.drainReadyWork()

      #expect(
        wrapper.testKernel.state == .audioInterrupted,
        "\(site.name): reached \(wrapper.testKernel.state)")
      #expect(wrapper.testKernel.state.isTerminal, "\(site.name): wedged")
    }

    /// THE INVARIANT. Absent an explicit user cancel, a session whose exit was a
    /// salvageable interruption terminates in exactly one of two states. There is
    /// no third outcome, and neither outcome deletes a spool today's code retains.
    @Test(
      "invariant: a salvageable interruption ends .completed or .audioInterrupted, never a third state",
      arguments: EngineInterruptionCause.allCases.filter(\.hasRecoverableAudio), [0, 1, 3])
    func salvageTerminatesInExactlyTwoStates(
      cause: EngineInterruptionCause, bufferCount: Int
    ) async {
      let (context, wrapper) = makeWrapper()
      await startRecording(context, buffers: bufferCount)

      wrapper.testKernel.externalEngineInterrupted(cause)
      await wrapper.drainReadyWork()

      let terminal = wrapper.testKernel.state
      #expect(
        terminal == .completed || terminal == .audioInterrupted,
        "salvage produced a third terminal: \(terminal)")
      if terminal != .completed {
        #expect(KernelDictationDriver.endedWithoutSaveKind(for: terminal) == .failure)
      }
    }

    /// The one sanctioned third outcome. A user who sees the disconnect notice
    /// and cancels has asked us to throw the take away; flooring `.cancelled`
    /// would override an explicit instruction to protect data the user just told
    /// us to discard. Its retain/delete disposition belongs to the driver's
    /// `pendingCancelDisposition`, not to the floor.
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
        wrapper.testKernel.state == .transcribing,
        "precondition: the salvage tail must still be in flight, got \(wrapper.testKernel.state)")

      await wrapper.apply(.cancel)
      await wrapper.drainReadyWork()

      #expect(wrapper.testKernel.state == .cancelled)
      #expect(context.paste.pasteCount == 0)
      #expect(
        KernelDictationDriver.endedWithoutSaveKind(for: .cancelled) == nil,
        "`.cancelled` is resolved dynamically by pendingCancelDisposition, not the static map")
    }

    /// Every terminal state the FSM can reach. `RecordingSessionState` has
    /// associated values so it cannot be `CaseIterable`; this list is the manual
    /// mirror, and `KernelDictationDriver.endedWithoutSaveKind` is an exhaustive
    /// switch, so a new state forces a decision there and gets caught here.
    private static let allTerminals: [RecordingSessionState] = [
      .completed, .cancelled, .discarded, .noSpeech, .audioInterrupted, .asrInterrupted,
      .failed(.prepareFailed), .failed(.permissionDenied), .failed(.modelWedged),
      .failed(.modelLoadFailed), .failed(.captureStartFailed), .failed(.noAudioCaptured),
      .failed(.asrEmpty), .failed(.asrFailed), .failed(.asrWedged),
      .failed(.emptyAfterProcessing), .failed(.captureStalled),
    ]

    /// The floor's mapped set and the driver's `.discard` set are two lists of
    /// one fact: "this terminal deletes the crash-recovery spool." They live in
    /// different types and can drift. This test couples them, so adding a new
    /// spool-deleting terminal without flooring it reddens here rather than
    /// silently destroying a user's only surviving copy of a dictation.
    @Test("the floor covers EVERY terminal that would delete the spool")
    func floorCoversEverySpoolDeletingTerminal() async {
      let (_, wrapper) = makeWrapper()
      wrapper.telemetryState.interruptionCause = .engineLost
      let kernel = wrapper.testKernel

      for terminal in Self.allTerminals {
        let deletesSpool = KernelDictationDriver.endedWithoutSaveKind(for: terminal) == .discard
        let floored = kernel.testInterruptedTerminalFloor(terminal)
        if deletesSpool {
          #expect(
            floored == .audioInterrupted,
            "\(terminal) deletes the spool but the floor let it through")
        }
      }
    }

    /// The floor must not over-reach. A user who cancels has asked us to discard;
    /// a completion delivered a transcript; every other `.failed` reason is
    /// already spool-retaining and keeps its own honest cause.
    @Test("the floor leaves every non-spool-deleting terminal alone, except noAudioCaptured")
    func floorLeavesOtherTerminalsAlone() async {
      let (_, wrapper) = makeWrapper()
      wrapper.telemetryState.interruptionCause = .deviceRemoved
      let kernel = wrapper.testKernel

      #expect(kernel.testInterruptedTerminalFloor(.completed) == .completed)
      #expect(
        kernel.testInterruptedTerminalFloor(.cancelled) == .cancelled,
        "an explicit user cancel is never overridden")
      #expect(kernel.testInterruptedTerminalFloor(.asrInterrupted) == .asrInterrupted)
      #expect(kernel.testInterruptedTerminalFloor(.failed(.asrEmpty)) == .failed(.asrEmpty))
      #expect(kernel.testInterruptedTerminalFloor(.failed(.asrFailed)) == .failed(.asrFailed))
      // Folded in with the spool-deleting pair: already retaining, but all three
      // no-transcript endings land on one terminal so none of them keeps a
      // different overlay for a reason no user could name.
      #expect(kernel.testInterruptedTerminalFloor(.failed(.noAudioCaptured)) == .audioInterrupted)
    }

    // MARK: 2b. The floor is unconditional — the SENTENCE is what varies

    /// SAFETY, for every cause. A spool-deleting terminal is rewritten no matter
    /// which interruption fired. Letting the cap fall through to `.discarded`
    /// because "no microphone disconnected" would be a NEW data loss dressed up
    /// as honesty. The honesty belongs in the message, not the terminal.
    @Test(
      "every no-transcript terminal is floored for EVERY recoverable cause",
      arguments: EngineInterruptionCause.allCases.filter(\.hasRecoverableAudio))
    func spoolDeletingTerminalsAreFlooredForEveryCause(cause: EngineInterruptionCause) async {
      let (_, wrapper) = makeWrapper()
      wrapper.telemetryState.interruptionCause = cause
      let kernel = wrapper.testKernel

      #expect(kernel.testInterruptedTerminalFloor(.discarded) == .audioInterrupted)
      #expect(kernel.testInterruptedTerminalFloor(.noSpeech) == .audioInterrupted)
      #expect(kernel.testInterruptedTerminalFloor(.failed(.noAudioCaptured)) == .audioInterrupted)
    }

    /// #1408 A3 retired `.maxDurationReached`: the hard cap is a normal
    /// auto-stop routed through the typed `.maxDuration` exit, so it can no
    /// longer stamp a cause, reach the floor, or claim an interruption at all.
    /// This freeze keeps the retirement honest — a resurrected cap case would
    /// change the enum's shape and redden here before it could lie again.
    @Test("the cause enum has exactly the three genuine interruption causes")
    func causeEnumHasNoDurationCap() {
      #expect(
        EngineInterruptionCause.allCases == [
          .deviceRemoved, .engineLost, .xpcConnectionLost,
        ])
      #expect(EngineInterruptionCause(rawValue: "max_duration_reached") == nil)
      // #1524 retired the capture-session backend and its cause with it. The
      // wire value must no longer resolve — `hostCause` collapses it to
      // `.engineLost` via the unknown-value fallback (EngineInterruptionCauseTests).
      #expect(EngineInterruptionCause(rawValue: "capture_session_lost") == nil)
    }

    /// Outside an interruption the floor is a no-op on every terminal. If it were
    /// not, an ordinary too-short tap would retain a spool forever.
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

    /// The cause now lives on the shared `KernelTelemetryState`, cleared ONLY by
    /// `resetForNewSession()`. Two clearers would let a stale cause leak into the
    /// next session, and the floor would then convert an ordinary too-short tap
    /// into `.audioInterrupted` with a retained spool. This test is the guard.
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
        "a stale cause would make the next ordinary too-short tap retain a spool")

      // And the floor is genuinely inert again: an ordinary stop discards.
      await wrapper.apply(.stop)
      await wrapper.drainReadyWork()
      #expect(wrapper.testKernel.state == .discarded)
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

    /// First-wins. A second interruption arriving in the post-latch window must
    /// not overwrite the cause the winning exit will be judged by — otherwise an
    /// already-owned `.xpcConnectionLost` could be replaced by a later
    /// `.engineLost` and salvage a recording whose samples are gone.
    @Test("a racing second interruption cannot flip an unsalvageable cause to a salvageable one")
    func secondInterruptionCannotUnlockSalvage() async {
      let (context, wrapper) = makeWrapper()
      await startRecording(context)

      wrapper.testKernel.externalEngineInterrupted(.xpcConnectionLost)
      wrapper.testKernel.externalEngineInterrupted(.engineLost)
      await wrapper.drainReadyWork()

      #expect(wrapper.testKernel.lastAudioInterruptionCause == .xpcConnectionLost)
      #expect(wrapper.testKernel.state == .audioInterrupted)
      #expect(context.paste.pasteCount == 0)
    }
  }

  // MARK: - The predicate itself (#1408)

  @Suite("EngineInterruptionCause.hasRecoverableAudio (#1408)")
  struct EngineInterruptionCauseRecoverabilityTests {

    /// `salvage_attempted` in telemetry and the kernel's salvage guard read this
    /// one property. If it ever disagrees with the kernel's behavior, one of the
    /// two grew a second copy of the switch.
    @Test("exactly one cause has no recoverable audio")
    func onlyXPCConnectionLostIsUnrecoverable() {
      let unrecoverable = EngineInterruptionCause.allCases.filter { !$0.hasRecoverableAudio }
      #expect(unrecoverable == [.xpcConnectionLost])
    }

    /// Recoverability is NOT the same question as "does this cause already have a
    /// telemetry owner." Two causes answer these questions differently, and
    /// conflating them is how a duplicated switch would drift.
    @Test("recoverability is not the telemetry-capture set")
    func recoverabilityDivergesFromCaptureSet() {
      #expect(!EngineInterruptionCause.xpcConnectionLost.hasRecoverableAudio)
      #expect(EngineInterruptionCause.engineLost.hasRecoverableAudio)
      #expect(EngineInterruptionCause.deviceRemoved.hasRecoverableAudio)
    }

    /// And `isDeviceLoss` is a THIRD question. An engine that failed to recover
    /// with the device still attached is salvaged like a disconnect but is not
    /// one: telling that user "Microphone disconnected," or badging their
    /// transcript with a crossed-out microphone, would describe an event that
    /// never happened. (#1524 retired `.captureSessionLost`, which carried this
    /// same shape; `.engineLost` is now the sole exemplar.)
    @Test("an engine loss is recoverable but is NOT a device loss")
    func engineLossIsRecoverableButNotDeviceLoss() {
      #expect(EngineInterruptionCause.engineLost.hasRecoverableAudio)
      #expect(!EngineInterruptionCause.engineLost.isDeviceLoss)
    }

    /// Exactly one cause is backed by a real `DeviceIsAlive` check. Each exclusion
    /// is a claim we could not back: `.engineLost` also covers a recovery timeout
    /// and a failed engine restart with the mic still attached;
    /// `.xpcConnectionLost` means our helper died, not the mic.
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

    /// The helper ran the `DeviceIsAlive` check; the host cannot re-run it because
    /// the device is already gone. Collapsing `.deviceRemoved` at the XPC boundary
    /// would throw away the one piece of evidence the disclosure depends on — and
    /// the helper IS the shipping capture backend, so this is the path a real
    /// Bluetooth disconnect takes.
    @Test("the XPC relay preserves a verified removal, and still collapses the rest")
    func xpcRelayPreservesDeviceRemoved() {
      #expect(
        EngineInterruptionCause.hostCause(forRelayedRawValue: "device_removed")
          == .deviceRemoved)
      // #1408 A3: the retired cap raw value is a legacy unknown now — it fails
      // toward visibility like anything else, never resurrects the cap.
      #expect(
        EngineInterruptionCause.hostCause(forRelayedRawValue: "max_duration_reached")
          == .engineLost)
      #expect(
        EngineInterruptionCause.hostCause(forRelayedRawValue: "capture_session_lost")
          == .engineLost)
      #expect(
        EngineInterruptionCause.hostCause(forRelayedRawValue: "xpc_connection_lost")
          == .engineLost)
      #expect(EngineInterruptionCause.hostCause(forRelayedRawValue: "engine_lost") == .engineLost)
      // Unknown / legacy raw values fail toward visibility, never toward a
      // disconnect claim.
      #expect(
        EngineInterruptionCause.hostCause(forRelayedRawValue: "from_the_future")
          == .engineLost)
    }

    /// The two predicates answer two different questions. If they ever collapse
    /// into one, this reddens rather than silently changing behavior.
    @Test("the two predicates are genuinely distinct sets")
    func predicatesAreDistinct() {
      let recoverable = Set(EngineInterruptionCause.allCases.filter(\.hasRecoverableAudio))
      let deviceLoss = Set(EngineInterruptionCause.allCases.filter(\.isDeviceLoss))
      #expect(recoverable != deviceLoss, "recoverability and device-loss are different questions")
      // An engine loss is salvageable but is not a disconnect...
      #expect(recoverable.contains(.engineLost))
      #expect(!deviceLoss.contains(.engineLost))
      // ...and a dead helper is neither: its samples are gone AND it is our
      // process that died, not the user's microphone.
      #expect(!recoverable.contains(.xpcConnectionLost))
      #expect(!deviceLoss.contains(.xpcConnectionLost))
      // Device loss is a strict subset of recoverable: if the mic vanished, the
      // capture manager is still alive and still holding what was said.
      #expect(deviceLoss.isStrictSubset(of: recoverable))
    }
  }

  // MARK: - The interruption sentence

  /// #1408 (Codex code-diff r4, founder-approved copy). `.audioInterrupted` is
  /// now the single no-transcript terminal for EVERY interruption, so it can no
  /// longer carry "Microphone disconnected" unconditionally — that string was a
  /// lie for a recovery failure, the duration cap, and our own helper crashing.
  ///
  /// `InterruptionMessages.message(for:)` is the one authority for which sentence
  /// a user reads, and the three `KernelDictationDriver` render sites all route
  /// through it. These tests are what keep the claim honest: exactly the causes
  /// backed by a real Core Audio removal may say a microphone disconnected.
  @Suite("The interruption sentence never claims more than we know (#1408)")
  struct InterruptionMessageTests {

    @Test("only a verified device loss says the microphone disconnected")
    func onlyDeviceLossClaimsADisconnect() {
      for cause in EngineInterruptionCause.allCases {
        let sentence = InterruptionMessages.message(for: cause)
        if cause.isDeviceLoss {
          #expect(sentence == "Microphone disconnected", "\(cause) earns the claim")
        } else {
          #expect(
            sentence == "Recording interrupted",
            "\(cause) is not a microphone walking away, so it must not say one did")
        }
      }
    }

    /// The set that may claim a disconnect is exactly the set `isDeviceLoss`
    /// names. Coupled rather than restated, so a sixth cause cannot quietly
    /// inherit the disconnect sentence by being added to the wrong list.
    @Test("the claiming set is exactly the isDeviceLoss set")
    func claimingSetEqualsDeviceLossSet() {
      let claims = Set(
        EngineInterruptionCause.allCases.filter {
          InterruptionMessages.message(for: $0) == "Microphone disconnected"
        })
      let deviceLoss = Set(EngineInterruptionCause.allCases.filter(\.isDeviceLoss))
      #expect(claims == deviceLoss)
      #expect(claims == [.deviceRemoved])
    }

    /// An `.audioInterrupted` terminal with no stamped cause should never be
    /// reachable (the kernel refuses salvage and logs), but if it ever is, the
    /// absence of evidence must not read as evidence of a disconnect.
    @Test("no stamped cause falls back to the neutral line, never a disconnect")
    func missingCauseIsNeutral() {
      #expect(InterruptionMessages.message(for: nil) == "Recording interrupted")
    }

    /// Rule 6: no em-dashes or en-dashes in anything a user reads.
    @Test("neither sentence carries a dash a human would see")
    func noDashesInUserFacingCopy() {
      for sentence in [
        InterruptionMessages.micDisconnected, InterruptionMessages.recordingInterrupted,
      ] {
        #expect(!sentence.contains("\u{2014}"), "em-dash in user-facing copy: \(sentence)")
        #expect(!sentence.contains("\u{2013}"), "en-dash in user-facing copy: \(sentence)")
      }
    }
  }

#endif
