import Foundation
import Testing

@testable import EnviousWisprServices

@Suite("CaptureTelemetryState")
@MainActor
struct CaptureTelemetryStateTests {

  @Test("shouldEmitZombie on first call returns true")
  func firstCallEmits() {
    let state = CaptureTelemetryState()
    #expect(state.shouldEmitZombie(route: "bt", window: .seconds(30)) == true)
  }

  @Test("shouldEmitZombie within window on same route returns false")
  func sameRouteSuppressed() {
    let state = CaptureTelemetryState()
    state.markZombieEmitted(route: "bt")
    #expect(state.shouldEmitZombie(route: "bt", window: .seconds(30)) == false)
  }

  @Test("shouldEmitZombie when route changes returns true")
  func routeChangeReEmits() {
    let state = CaptureTelemetryState()
    state.markZombieEmitted(route: "bt")
    #expect(state.shouldEmitZombie(route: "built_in_mic", window: .seconds(30)) == true)
  }

  @Test("shouldEmitZombie when window is zero always returns true")
  func zeroWindowAlwaysEmits() {
    let state = CaptureTelemetryState()
    state.markZombieEmitted(route: "bt")
    #expect(state.shouldEmitZombie(route: "bt", window: .zero) == true)
  }

  @Test("recordSuccessfulRecording clears dedupe so the next zombie re-emits")
  func successResetsDedupe() {
    let state = CaptureTelemetryState()
    state.markZombieEmitted(route: "bt")
    state.recordSuccessfulRecording(recoveryTransport: "builtin", sessionID: 1)
    #expect(state.shouldEmitZombie(route: "bt", window: .seconds(30)) == true)
  }

  @Test("recordSuccessfulRecording sets a time-since baseline")
  func successSetsBaseline() {
    let state = CaptureTelemetryState()
    #expect(state.timeSinceLastSuccessfulRecordingMs() == nil)
    state.recordSuccessfulRecording(recoveryTransport: "builtin", sessionID: 1)
    let ms = state.timeSinceLastSuccessfulRecordingMs()
    #expect(ms != nil)
    #expect((ms ?? -1) >= 0)
  }

  // MARK: - Injected-clock boundary tests (#784 PR1, 2026-05-18)
  //
  // `shouldEmitZombie` returns true iff `currentInstant() - last >= window`.
  // The `>=` comparator means equality is at-threshold (emit allowed) and
  // strict-below is suppressed. These three tests pin both edges of `>=`
  // and the at-equality case using a fake clock.

  @Test("shouldEmitZombie returns true at exactly the window boundary")
  func emitsAtExactWindow() {
    let clock = ManualInstantClock()
    let state = CaptureTelemetryState(currentInstant: { clock.now })
    state.markZombieEmitted(route: "bt")
    clock.advance(by: .seconds(30))
    #expect(state.shouldEmitZombie(route: "bt", window: .seconds(30)) == true)
  }

  @Test("shouldEmitZombie returns false just below the window boundary")
  func doesNotEmitJustBelowWindow() {
    let clock = ManualInstantClock()
    let state = CaptureTelemetryState(currentInstant: { clock.now })
    state.markZombieEmitted(route: "bt")
    clock.advance(by: .milliseconds(29_999))
    #expect(state.shouldEmitZombie(route: "bt", window: .seconds(30)) == false)
  }

  @Test("shouldEmitZombie returns true just above the window boundary")
  func emitsJustAboveWindow() {
    let clock = ManualInstantClock()
    let state = CaptureTelemetryState(currentInstant: { clock.now })
    state.markZombieEmitted(route: "bt")
    clock.advance(by: .milliseconds(30_001))
    #expect(state.shouldEmitZombie(route: "bt", window: .seconds(30)) == true)
  }

  @Test("timeSinceLastSuccessfulRecordingMs uses the injected clock")
  func timeSinceLastSuccessfulRecordingUsesInjectedClock() {
    let clock = ManualInstantClock()
    let state = CaptureTelemetryState(currentInstant: { clock.now })
    #expect(state.timeSinceLastSuccessfulRecordingMs() == nil)
    state.recordSuccessfulRecording(recoveryTransport: "builtin", sessionID: 1)
    clock.advance(by: .milliseconds(2_500))
    #expect(state.timeSinceLastSuccessfulRecordingMs() == 2_500)
  }

  // MARK: - Dead-mic recovery watch (#1520 heartpath 5b)

  @Test("arm then a LATER session's success → recovered=true, later_success, gap from clock")
  func armThenSuccessRecovers() {
    let clock = ManualInstantClock()
    let state = CaptureTelemetryState(currentInstant: { clock.now })

    #expect(
      state.armDeadMicWatch(
        DeadMicRetireWatch(shape: "all_zero_from_start", transport: "bluetooth"), sessionID: 1)
        == nil)
    clock.advance(by: .milliseconds(1_200))
    let outcome = state.recordSuccessfulRecording(recoveryTransport: "bluetooth", sessionID: 2)

    #expect(outcome?.recovered == true)
    #expect(outcome?.resolution == "later_success")
    #expect(outcome?.retireShape == "all_zero_from_start")
    #expect(outcome?.retireTransport == "bluetooth")
    #expect(outcome?.recoveryTransport == "bluetooth")
    #expect(outcome?.transportChanged == false)
    #expect(outcome?.gapMs == 1_200)
  }

  @Test("the SAME session that armed the watch cannot resolve its own recovery (#1520 P1)")
  func sameSessionCannotResolveItsOwnWatch() {
    let state = CaptureTelemetryState()
    // A becameZeroMidCapture take arms the watch at stop (session 7) AND then
    // completes successfully by salvaging its prefix — the SAME session 7.
    state.armDeadMicWatch(
      DeadMicRetireWatch(shape: "became_zero_mid_capture", transport: "bluetooth"), sessionID: 7)
    // Its own completion must NOT be credited as a recovery.
    #expect(state.recordSuccessfulRecording(recoveryTransport: "bluetooth", sessionID: 7) == nil)
    // The watch is still pending: a genuinely later session (8) resolves it.
    let later = state.recordSuccessfulRecording(recoveryTransport: "bluetooth", sessionID: 8)
    #expect(later?.recovered == true)
    #expect(later?.resolution == "later_success")
  }

  @Test(
    "arm while a watch is pending → prior resolves recovered=false, later_retire; new watch armed")
  func armWhilePendingResolvesPriorAsNotRecovered() {
    let clock = ManualInstantClock()
    let state = CaptureTelemetryState(currentInstant: { clock.now })

    #expect(
      state.armDeadMicWatch(
        DeadMicRetireWatch(shape: "all_zero_from_start", transport: "bluetooth"), sessionID: 1)
        == nil)
    clock.advance(by: .milliseconds(800))
    let prior = state.armDeadMicWatch(
      DeadMicRetireWatch(shape: "became_zero_mid_capture", transport: "bluetooth"), sessionID: 2)

    #expect(prior?.recovered == false)
    #expect(prior?.resolution == "later_retire")
    #expect(prior?.retireShape == "all_zero_from_start")
    #expect(prior?.gapMs == 800)

    // The new watch is now pending: a later success resolves IT, not the prior.
    let resolved = state.recordSuccessfulRecording(recoveryTransport: "builtin", sessionID: 3)
    #expect(resolved?.recovered == true)
    #expect(resolved?.retireShape == "became_zero_mid_capture")
    #expect(resolved?.transportChanged == true)  // bluetooth armed → builtin recovered
  }

  @Test("success with no pending watch → nil (no fabricated outcome)")
  func successWithNoWatchIsNil() {
    let state = CaptureTelemetryState()
    #expect(state.recordSuccessfulRecording(recoveryTransport: "builtin", sessionID: 1) == nil)
  }

  @Test("transport_changed reflects a transport-class change at resolution")
  func transportChangedFlag() {
    let state = CaptureTelemetryState()
    state.armDeadMicWatch(
      DeadMicRetireWatch(shape: "all_zero_from_start", transport: "bluetooth"), sessionID: 1)
    let outcome = state.recordSuccessfulRecording(recoveryTransport: "builtin", sessionID: 2)
    #expect(outcome?.transportChanged == true)
  }
}

/// Fake monotonic instant clock for tests that need deterministic
/// `ContinuousClock.Instant` arithmetic without real wall-clock sleeps.
/// Snapshots `.now` at construction; subsequent `advance(by:)` calls move
/// the snapshot forward via `.advanced(by:)`. Same shape duplicated in
/// `HeartPathTelemetryEmitterTests.swift` per #784 PR1 plan — DRY violation
/// is cheaper than introducing a shared test-utilities target for 5 lines.
@MainActor
private final class ManualInstantClock {
  private(set) var now: ContinuousClock.Instant = .now
  func advance(by duration: Duration) {
    now = now.advanced(by: duration)
  }
}
