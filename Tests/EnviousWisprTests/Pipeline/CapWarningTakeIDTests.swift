import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprPipeline

// MARK: - Approaching-cap warning carries the take key (#1846 chunk 10)
//
// `recording.cap_warning_shown` was the last of the thirteen planned events
// with no per-dictation identity. The route the plan chose is the one already
// fenced at source: `VADWarningSignal` carries the `SessionID` of the run that
// produced it, and the kernel validates that stamp against the current session
// before forwarding. Chunk 10 stops discarding it.
//
// All three tests here are BEHAVIOURAL — they drive the real forwarding code
// rather than scanning it. The first two emit through the fake VAD seam; the
// third invokes the kernel-side callback the driver installed in `start()`.
//
// `#if DEBUG`-gated like the rest of the simulator suites: the harness depends
// on kernel test hooks that only exist in DEBUG.

#if DEBUG

  @MainActor
  @Suite("Approaching-cap warning take key (#1846)")
  struct CapWarningTakeIDTests {

    // MARK: Kernel — the warning stream forwards the validated identity

    private func makeWrapper() -> (SimulatorContext, KernelRecordingSession) {
      let clock = FakeClock()
      let engine = FakeEngine(behavior: .batchSuccess(text: "hello"), clock: clock)
      let capture = FakeAudioCapture()
      let vad = FakeVADSignalSource()
      let paste = FakePasteTarget()
      let wrapper = KernelRecordingSession(
        engine: engine, capture: capture, vad: vad, clock: clock, paste: paste)
      let context = SimulatorContext(
        sut: wrapper, engine: engine, capture: capture, vad: vad, clock: clock, paste: paste)
      return (context, wrapper)
    }

    /// Drive to `.live` — the only state the warning forward accepts. Reaching
    /// `.live` needs the first converted buffer (the #1548 D1 transport gate).
    private func startToRecording(_ context: SimulatorContext) async {
      await context.sut.apply(.start)
      await context.sut.drainReadyWork()
      context.capture.deliverBuffer()
      await context.sut.drainReadyWork()
    }

    @Test("a live warning carries this recording's take key")
    func liveWarningCarriesTakeKey() async throws {
      let (context, wrapper) = makeWrapper()
      let observed = WarningLog()
      wrapper.testKernel.onApproachingMaxDuration = { remaining, takeID in
        observed.append(remaining: remaining, takeID: takeID)
      }

      await startToRecording(context)
      context.vad.emitWarning(remainingSeconds: 45)
      await context.sut.drainReadyWork()

      #expect(observed.entries.count == 1, "the warning must reach the callback exactly once")
      let entry = try #require(observed.entries.first)
      let sessionTakeID = try #require(wrapper.telemetryState.takeID)
      #expect(entry.remaining == 45)
      #expect(entry.takeID.isEmpty == false)
      // The identity assertion. `start(config:)` projects `telemetryState.takeID`
      // from the same `SessionID` the warning is stamped with and validated
      // against, so on this path the two are the same value — and that is the
      // value every other take-keyed event in this session already carries.
      #expect(
        entry.takeID == sessionTakeID,
        "the warning's key must be the same take key the rest of the session emits")
      #expect(UUID(uuidString: entry.takeID) != nil, "the take key is a session UUID string")
    }

    /// A mismatched stamp is dropped before forwarding. The positive control in
    /// the same live session proves the callback is reachable, so the empty result
    /// is the session-stamp guard working rather than a dead fixture.
    ///
    /// Named for what the fixture actually builds: `emitStaleWarning` mints a
    /// fresh `SessionID`, which is non-current but not a proven PRIOR session.
    /// Rejection of a mismatched stamp is the invariant, and that is what is
    /// asserted — the earlier "superseded session" wording overstated the setup.
    @Test("a warning with a non-current session stamp is dropped")
    func nonCurrentWarningIsDropped() async throws {
      let (context, wrapper) = makeWrapper()
      let observed = WarningLog()
      wrapper.testKernel.onApproachingMaxDuration = { remaining, takeID in
        observed.append(remaining: remaining, takeID: takeID)
      }

      await startToRecording(context)
      context.vad.emitStaleWarning(remainingSeconds: 45)
      await context.sut.drainReadyWork()

      #expect(observed.entries.isEmpty, "a non-current stamp must not reach the callback")

      // Positive control in the same session: the drop above is the stamp check
      // doing its job, not the callback being unreachable from this fixture.
      context.vad.emitWarning(remainingSeconds: 30)
      await context.sut.drainReadyWork()
      #expect(observed.entries.count == 1)
      let entry = try #require(observed.entries.first)
      let sessionTakeID = try #require(wrapper.telemetryState.takeID)
      #expect(entry.takeID == sessionTakeID)
    }

    // MARK: Driver — the public callback forwards both values unchanged

    @Test("the driver forwards the kernel's take key to its public callback")
    func driverForwardsTakeKey() async throws {
      let fixture = Self.makeDriverFixture()
      let observed = WarningLog()
      fixture.driver.onApproachingMaxDuration = { remaining, takeID in
        observed.append(remaining: remaining, takeID: takeID)
      }

      // `driver.start()` (in the fixture) installs the kernel-side closure; this
      // exercises that installed closure, which is the line under test. Driving a
      // real cap warning through the kernel is covered above — duplicating it
      // here would not isolate the driver's own forwarding.
      let expected = UUID().uuidString
      fixture.kernel.onApproachingMaxDuration?(45, expected)

      #expect(observed.entries.count == 1)
      let entry = try #require(observed.entries.first)
      #expect(entry.remaining == 45)
      #expect(
        entry.takeID == expected,
        """
        the driver must forward the kernel's key unchanged — never substitute `lastTakeID`, \
        which is the CONCLUDED key and is not yet stamped mid-recording
        """)
    }

    private struct DriverFixture {
      let driver: KernelDictationDriver
      let kernel: RecordingSessionKernel
    }

    private static func makeDriverFixture() -> DriverFixture {
      let steps = LimbSteps(
        wordCorrection: WordCorrectionStep(),
        fillerRemoval: FillerRemovalStep(),
        emojiFormatter: EmojiFormatterStep(),
        inverseTextNormalization: InverseTextNormalizationStep(),
        llmPolish: LLMPolishStep(keychainManager: KeychainManager()),
        emojiRestore: EmojiRestoreStep())
      let adapter = FakeEngine(behavior: .batchSuccess(text: "x"), clock: FakeClock())
      let kernel = RecordingSessionKernel(
        adapter: adapter,
        audioCapture: FakeAudioCapture(),
        vad: FakeVADSignalSource(),
        currentTick: { 0 }, sleepTicks: { _ in },
        processText: { raw, _ in raw },
        store: { _, _, _ in }, deliver: { _, _ in .pasted },
        engineMutationScope: .alwaysAllowedForTesting,
        minimumRecordingTicks: 0)
      let observer = KernelHeartPathTelemetryObserver(
        kernel: kernel, audioCapture: FakeAudioCapture(),
        emitter: HeartPathTelemetryEmitter(
          backend: .parakeet, captureTelemetry: CaptureTelemetryState()),
        emitLifecycleEvent: { _ in })
      let driver = KernelDictationDriver(
        kernel: kernel, observer: observer, outcome: KernelFinalizationOutcome(),
        context: KernelSessionContext(), steps: steps, adapter: adapter,
        engineMutationScope: .alwaysAllowedForTesting)
      driver.start()
      return DriverFixture(driver: driver, kernel: kernel)
    }

    /// Reference-type log so the `@MainActor` callbacks can record without the
    /// closures capturing a mutating local.
    @MainActor
    final class WarningLog {
      struct Entry {
        let remaining: TimeInterval
        let takeID: String
      }
      private(set) var entries: [Entry] = []
      func append(remaining: TimeInterval, takeID: String) {
        entries.append(Entry(remaining: remaining, takeID: takeID))
      }
    }
  }

#endif
