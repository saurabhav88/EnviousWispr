import Foundation
import Testing

@testable import EnviousWisprAudio

// #1377 slice 2a — locks the capture-backend bake-off control plane: the DEBUG
// runtime policy override, the force-policy → sourceType mapping, the
// no-BT-output vs BT-output-active `.automatic` routing split (`.halDeviceInput`
// was dormant under `.automatic` at slice 2a; #1427 made it the live BT-output
// route — see the two `automaticNeverEmitsDormantCaseWithoutBTOutput` /
// `automaticRoutesToHALWithBTOutput` tests below, #1434), and the
// additive device-target default (nil = built-in, byte-identical to today).
//
// Behavioral capture correctness (which device actually binds, non-silent audio,
// WER) is hardware-and-driver dependent and lives in the bake-off Live UAT
// (`Tests/RuntimeUAT/`) per the plan's §3a earliest-failure point — no unit test
// can substitute. These suites lock the pure routing/config logic that CAN be
// asserted without hardware.

#if DEBUG
  @MainActor
  @Suite("Capture bake-off DEBUG policy override — #1377")
  struct CaptureBakeoffPolicyOverrideTests {

    private func makeDefaults() -> UserDefaults {
      // Unique in-memory-ish suite per test so we never touch the real store.
      let suite = "test.captureBakeoff.\(UUID().uuidString)"
      let defaults = UserDefaults(suiteName: suite)!
      defaults.removePersistentDomain(forName: suite)
      return defaults
    }

    @Test("unset key → nil (build behaves as .automatic)")
    func unsetIsNil() {
      let defaults = makeDefaults()
      #expect(CaptureRouteResolver.debugPolicyOverride(defaults: defaults) == nil)
    }

    @Test("forceEngine string → .forceEngine")
    func forceEngineMaps() {
      let defaults = makeDefaults()
      defaults.set("forceEngine", forKey: CaptureRouteResolver.debugPolicyOverrideKey)
      #expect(CaptureRouteResolver.debugPolicyOverride(defaults: defaults) == .forceEngine)
    }

    @Test("forceHALDeviceInput string → .forceHALDeviceInput")
    func forceHALDeviceInputMaps() {
      let defaults = makeDefaults()
      defaults.set("forceHALDeviceInput", forKey: CaptureRouteResolver.debugPolicyOverrideKey)
      #expect(
        CaptureRouteResolver.debugPolicyOverride(defaults: defaults) == .forceHALDeviceInput)
    }

    @Test("unknown string → nil (never silently forces a candidate)")
    func garbageIsNil() {
      let defaults = makeDefaults()
      defaults.set("forceMysteryEngine", forKey: CaptureRouteResolver.debugPolicyOverrideKey)
      #expect(CaptureRouteResolver.debugPolicyOverride(defaults: defaults) == nil)
    }
  }
#endif

@MainActor
@Suite("Capture route resolver — force mapping + dormancy — #1377")
struct CaptureRouteResolverForceMappingTests {

  @Test("forceEngine policy → .audioEngine / .forcedEngine (no hardware)")
  func forceEngineDecision() {
    var resolver = CaptureRouteResolver()
    resolver.policy = .forceEngine
    let d = resolver.resolve(preferredInputDeviceUID: "", noiseSuppression: false)
    #expect(d.sourceType == .audioEngine)
    #expect(d.reason == .forcedEngine)
  }

  @Test("forceHALDeviceInput policy → .halDeviceInput / .forcedHALDeviceInput (no hardware)")
  func forceHALDeviceInputDecision() {
    var resolver = CaptureRouteResolver()
    resolver.policy = .forceHALDeviceInput
    let d = resolver.resolve(preferredInputDeviceUID: "", noiseSuppression: false)
    #expect(d.sourceType == .halDeviceInput)
    #expect(d.reason == .forcedHALDeviceInput)
  }

  // Non-Bluetooth invariant: with no Bluetooth OUTPUT device active, the
  // `.automatic` route always yields a SHIPPING capture backend, never
  // `.halDeviceInput`. Hardware-independent via injected closures — #1434
  // found this test previously read the REAL system default output device
  // with no override, so it silently depended on the test machine having no
  // Bluetooth output connected at run time (false whenever a real BT
  // headset, e.g. AirPods or Bose, is the current system default output).
  // #1524 TIGHTENED: with the capture-session backend deleted, the non-BT
  // `.automatic` answer is `.audioEngine` and nothing else. This is now the
  // EMPIRICAL half of the closed-world argument the deletion rested on — the
  // plan proved it by reading the three returns of `resolveAutomatic`; this
  // proves it by executing them.
  @Test("automatic route with no BT output always resolves to the engine backend")
  func automaticNeverEmitsDormantCaseWithoutBTOutput() {
    var resolver = CaptureRouteResolver()  // .automatic by default
    resolver.defaultOutputDeviceID = { nil }
    resolver.isBluetoothOutputDevice = { _ in false }
    for pref in ["", "some-device-uid"] {
      let d = resolver.resolve(preferredInputDeviceUID: pref, noiseSuppression: false)
      #expect(d.sourceType == .audioEngine)
    }
  }

  // Companion case (#1434): with a Bluetooth OUTPUT device active, `.automatic`
  // is INTENDED to route through `.halDeviceInput` — this is the live,
  // already-shipped behavior (#1427 "Honor system default input for auto
  // capture") that #1434's degraded-lead salvage work depends on actually
  // firing. `resolveAutomatic` in CaptureRouteResolver.swift routes
  // unconditionally to `.halDeviceInput` once `isBluetoothOutputDevice`
  // reports true — `.halDeviceInput` is not dormant under real Bluetooth.
  @Test("automatic route with BT output active routes through HAL device input")
  func automaticRoutesToHALWithBTOutput() {
    var resolver = CaptureRouteResolver()  // .automatic by default
    resolver.defaultOutputDeviceID = { 99 }
    resolver.isBluetoothOutputDevice = { _ in true }
    for pref in ["", "some-device-uid"] {
      let d = resolver.resolve(preferredInputDeviceUID: pref, noiseSuppression: false)
      #expect(d.sourceType == .halDeviceInput)
    }
  }
}
