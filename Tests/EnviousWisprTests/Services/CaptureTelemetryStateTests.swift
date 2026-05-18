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
    state.recordSuccessfulRecording()
    #expect(state.shouldEmitZombie(route: "bt", window: .seconds(30)) == true)
  }

  @Test("recordSuccessfulRecording sets a time-since baseline")
  func successSetsBaseline() {
    let state = CaptureTelemetryState()
    #expect(state.timeSinceLastSuccessfulRecordingMs() == nil)
    state.recordSuccessfulRecording()
    let ms = state.timeSinceLastSuccessfulRecordingMs()
    #expect(ms != nil)
    #expect((ms ?? -1) >= 0)
  }

  @Test("incrementConfigChange is monotonic")
  func configChangeMonotonic() {
    let state = CaptureTelemetryState()
    #expect(state.configurationChangeCount == 0)
    state.incrementConfigChange()
    state.incrementConfigChange()
    state.incrementConfigChange()
    #expect(state.configurationChangeCount == 3)
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
    state.recordSuccessfulRecording()
    clock.advance(by: .milliseconds(2_500))
    #expect(state.timeSinceLastSuccessfulRecordingMs() == 2_500)
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
