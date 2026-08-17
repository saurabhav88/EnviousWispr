import Foundation
import Testing

@testable import EnviousWisprPipeline

// MARK: - #1714 kernel input-resolution freeze
//
// The kernel freezes WHY the final engine-start attempt's microphone was chosen,
// so a take can be attributed after it completes OR after it fails. The failing
// population is the whole point: #1714 exists because 226 recordings across 19
// installs aborted at start, and a fix whose own failures are unattributable
// cannot be measured.
//
// LAST-WINS across the one permitted rebuild retry. That is not the terminal
// first-wins rule — that one decides which competing OUTCOME owns the session;
// this is an attempt fact updated through the controlled retry before any
// terminal is published.
//
// Hardware-free: every value is scripted on `FakeAudioCapture`, which only
// publishes what the interface would report per attempt and never decides when
// the kernel reads it.
@MainActor
@Suite("RecordingSessionKernel — #1714 input-resolution freeze")
struct KernelInputResolutionFreezeTests {

  private func makeWrapper() -> (FakeAudioCapture, KernelRecordingSession) {
    let clock = FakeClock()
    let engine = FakeEngine(behavior: .batchSuccess(text: "hello"), clock: clock)
    let capture = FakeAudioCapture()
    let vad = FakeVADSignalSource()
    let paste = FakePasteTarget()
    let wrapper = KernelRecordingSession(
      engine: engine, capture: capture, vad: vad, clock: clock, paste: paste)
    return (capture, wrapper)
  }

  /// #1857: `concluding: true` for the fault-injected starts whose caller then
  /// asserts the kernel reached its FAILED terminal. Epoch quiescence can settle
  /// while the failure path is still a ready task, so `state` would read the
  /// in-flight value. A healthy start has no terminal coming and keeps the plain
  /// drain — the conclusion wait would spin to its livelock cap there.
  private func startAndSettle(_ wrapper: KernelRecordingSession, concluding: Bool = false) async {
    await wrapper.apply(.start)
    if concluding {
      await wrapper.drainUntilConcluded()
    } else {
      await wrapper.drainReadyWork()
    }
  }

  // MARK: 1 — the ordinary success path

  @Test("a successful first engine-start attempt freezes its source")
  func successfulFirstAttemptFreezes() async {
    let (capture, wrapper) = makeWrapper()
    capture.stabilizationResults = [true]
    capture.inputResolutionSourcePerAttempt = ["system_default"]

    await startAndSettle(wrapper)

    #expect(capture.startEnginePhaseCallCount == 1, "no rebuild on a stable device")
    #expect(wrapper.testKernel.lastInputResolutionSource == "system_default")
  }

  // MARK: 2 — the failing population this issue exists to measure

  @Test("an initial engine-start FAILURE freezes its source before the terminal")
  func initialFailureFreezesBeforeTerminal() async {
    let (capture, wrapper) = makeWrapper()
    capture.inputResolutionSourcePerAttempt = ["list_fallback"]
    capture.failEngineStart = true

    await startAndSettle(wrapper, concluding: true)

    // Asserted AFTER the kernel reached its failed terminal, not before the
    // throw: a pre-throw assertion would prove the fake, not the freeze.
    #expect(wrapper.testKernel.state == .idle, "the kernel must have finished a terminal")
    #expect(wrapper.testKernel.lastInputResolutionSource == "list_fallback")
  }

  // MARK: 3-4 — last-wins across the single rebuild retry

  @Test("a successful rebuild retry uses attempt 2's source, not attempt 1's")
  func successfulRebuildUsesSecondAttempt() async {
    let (capture, wrapper) = makeWrapper()
    // Unstable device: one rebuild, so two engine-start attempts.
    capture.stabilizationResults = [false, true]
    // Two DISTINCT non-nil values, so last-wins cannot pass vacuously.
    capture.inputResolutionSourcePerAttempt = ["system_default", "list_fallback"]

    await startAndSettle(wrapper)

    #expect(capture.startEnginePhaseCallCount == 2, "the rebuild retry must have run")
    #expect(wrapper.testKernel.lastInputResolutionSource == "list_fallback")
  }

  @Test("a THROWING rebuild retry uses attempt 2's source before the failed terminal")
  func throwingRebuildUsesSecondAttempt() async {
    let (capture, wrapper) = makeWrapper()
    capture.stabilizationResults = [false, true]
    capture.inputResolutionSourcePerAttempt = ["system_default", "list_fallback"]
    // Attempt 1 succeeds; the rebuild attempt throws.
    capture.failEngineStartOnAttempt = 2

    await startAndSettle(wrapper, concluding: true)

    #expect(capture.startEnginePhaseCallCount == 2)
    #expect(wrapper.testKernel.state == .idle)
    #expect(
      wrapper.testKernel.lastInputResolutionSource == "list_fallback",
      "a retry that lands elsewhere must not file the failure against attempt 1's device")
  }

  // MARK: 5 — the final attempt's nil is what gets frozen

  @Test("a final attempt reporting nil is frozen as nil")
  func finalAttemptNilIsFrozen() async {
    let (capture, wrapper) = makeWrapper()
    capture.stabilizationResults = [false, true]
    capture.inputResolutionSourcePerAttempt = ["system_default", nil]

    await startAndSettle(wrapper)

    // This proves PLACEMENT: the sole freeze reads attempt 2 after the retry.
    // It cannot distinguish plain assignment from `??` today because exactly one
    // of the three mutually exclusive freeze sites executes per session. An
    // earlier name claimed it proved nil-OVERWRITE; it never did.
    #expect(capture.startEnginePhaseCallCount == 2)
    #expect(wrapper.testKernel.lastInputResolutionSource == nil)
  }

  // MARK: 6 — no cross-session bleed

  @Test("a new session clears the prior frozen source")
  func newSessionClearsPriorSource() async {
    let (capture, wrapper) = makeWrapper()
    capture.stabilizationResults = [true]
    capture.inputResolutionSourcePerAttempt = ["list_fallback"]

    await startAndSettle(wrapper)
    #expect(wrapper.testKernel.lastInputResolutionSource == "list_fallback")

    // Return to idle before starting again. `.start` on a still-recording
    // kernel is a no-op, and an earlier draft of this test missed that — it
    // asserted a "cleared" value that was really just session 1's, never
    // overwritten because session 2 never ran.
    await wrapper.apply(.stop)
    await wrapper.drainUntilConcluded()
    #expect(wrapper.testKernel.state == .idle, "session 1 must have finished")

    // Park session 2 AFTER engine start publishes its new source but BEFORE the
    // kernel's common success-path freeze. At that instant only
    // `resetSessionState()` can explain a nil — a second draft asserted nil
    // after the freeze had already written one, so deleting the reset entirely
    // would still have passed.
    capture.stabilizationResults = [true, true]
    capture.inputResolutionSourcePerAttempt = ["list_fallback", "pinned_uid"]
    capture.gateStabilizationCall = 2

    await wrapper.apply(.start)
    await capture.awaitStabilizationGateReached()

    #expect(capture.startEnginePhaseCallCount == 2, "session 2 must have run engine start")
    #expect(capture.currentInputResolutionSource == "pinned_uid")
    #expect(
      wrapper.testKernel.lastInputResolutionSource == nil,
      "resetSessionState must clear session 1 before session 2 reaches its final freeze")

    capture.releaseStabilizationGate()
    await wrapper.drainReadyWork()

    #expect(wrapper.testKernel.lastInputResolutionSource == "pinned_uid")
  }

  // MARK: 7 — a stop immediately after startup still keeps the frozen source

  @Test("stop right after successful engine startup leaves the source frozen")
  func stopAfterStartupKeepsFrozenSource() async {
    let (capture, wrapper) = makeWrapper()
    capture.stabilizationResults = [true]
    capture.inputResolutionSourcePerAttempt = ["pinned_uid"]

    await startAndSettle(wrapper)
    await wrapper.apply(.stop)
    await wrapper.drainReadyWork()

    #expect(wrapper.testKernel.lastInputResolutionSource == "pinned_uid")
  }

  // MARK: 8 — the route freeze is independent

  @Test("the route freeze remains independent of input-resolution freezing")
  func routeFreezeIsIndependent() async {
    let (capture, wrapper) = makeWrapper()
    capture.stabilizationResults = [true]
    capture.inputResolutionSourcePerAttempt = ["list_fallback"]

    await startAndSettle(wrapper)

    // The fake reports no resolved route, so route attribution stays nil while
    // input attribution is populated. Two separate facts, two separate freezes.
    #expect(wrapper.testKernel.lastInputResolutionSource == "list_fallback")
    #expect(wrapper.testKernel.lastResolvedRoute == nil)
  }
}
