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
}
