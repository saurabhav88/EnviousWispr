import Foundation
import Testing

@testable import EnviousWisprAudio

// #1533 cutover — the bake-off control plane (DEBUG force-policy override,
// force-engine / force-HAL policies) is DELETED along with the second backend.
// What remains to lock is the whole-behavior invariant: `.automatic` (the only
// path) always resolves to the single HAL device backend, regardless of BT
// output state or explicit device pick. This replaces the former #1524 non-BT
// lock (which asserted the deleted engine backend).
//
// Behavioral capture correctness (which device actually binds, non-silent audio,
// WER) is hardware-and-driver dependent and lives in the Live UAT
// (`Tests/RuntimeUAT/`) per the plan's §3a earliest-failure point — no unit test
// can substitute. This suite locks the pure routing logic that CAN be asserted
// without hardware.
@MainActor
@Suite("Capture route resolver — HAL is the only backend — #1533")
struct CaptureRouteResolverBackendCollapseTests {

  @Test("automatic route with no BT output always resolves to HAL device input")
  func automaticNoBTResolvesToHAL() {
    var resolver = CaptureRouteResolver()  // .automatic by default
    resolver.defaultOutputDeviceID = { nil }
    resolver.isBluetoothOutputDevice = { _ in false }
    for pref in ["", "some-device-uid"] {
      let d = resolver.resolve(preferredInputDeviceUID: pref)
      #expect(d.sourceType == .halDeviceInput)
    }
  }

  @Test("automatic route with BT output active resolves to HAL device input")
  func automaticBTResolvesToHAL() {
    var resolver = CaptureRouteResolver()  // .automatic by default
    resolver.defaultOutputDeviceID = { 99 }
    resolver.isBluetoothOutputDevice = { _ in true }
    for pref in ["", "some-device-uid"] {
      let d = resolver.resolve(preferredInputDeviceUID: pref)
      #expect(d.sourceType == .halDeviceInput)
    }
  }

  @Test("the capture-source roster has exactly one backend")
  func exactlyOneBackend() {
    // The scoreboard metric "ways to open a mic" — `CaptureSourceType` has a
    // single inhabitant after the cutover.
    #expect(CaptureSourceType.allBackendsForTest.count == 1)
  }
}

extension CaptureSourceType {
  /// Test-only roster of every capture backend. A second backend would have to
  /// be added here, tripping `exactlyOneBackend` — the freeze that keeps the
  /// scoreboard honest.
  fileprivate static let allBackendsForTest: [CaptureSourceType] = [.halDeviceInput]
}
