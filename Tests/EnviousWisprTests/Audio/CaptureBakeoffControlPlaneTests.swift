import Foundation
import Testing

@testable import EnviousWisprAudio

// #1377 slice 2a — locks the capture-backend bake-off control plane: the DEBUG
// runtime policy override, the force-policy → sourceType mapping, the dormancy
// invariant (the `.automatic` route never emits a non-shipping backend), and the
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

    @Test("forceCaptureSession string → .forceCaptureSession")
    func forceCaptureSessionMaps() {
      let defaults = makeDefaults()
      defaults.set("forceCaptureSession", forKey: CaptureRouteResolver.debugPolicyOverrideKey)
      #expect(
        CaptureRouteResolver.debugPolicyOverride(defaults: defaults) == .forceCaptureSession)
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

  @Test("forceCaptureSession policy → .captureSession / .forcedCaptureSession (no hardware)")
  func forceCaptureSessionDecision() {
    var resolver = CaptureRouteResolver()
    resolver.policy = .forceCaptureSession
    let d = resolver.resolve(preferredInputDeviceUID: "", noiseSuppression: false)
    #expect(d.sourceType == .captureSession)
    #expect(d.reason == .forcedCaptureSession)
  }

  // Dormancy lock: whatever the test machine's audio hardware, the `.automatic`
  // route only ever yields a SHIPPING capture backend. When slices 2b/2c add
  // `.halDeviceInput` / `.voiceProcessingIO`, this assertion stays the two
  // shipping cases, so it guards that the automatic route never emits a dormant
  // candidate (the §4 invariant) — hardware-independent because it asserts
  // membership, not a specific device-derived result.
  @Test("automatic route only ever emits a shipping backend (dormancy)")
  func automaticNeverEmitsDormantCase() {
    var resolver = CaptureRouteResolver()  // .automatic by default
    for pref in ["", "some-device-uid"] {
      let d = resolver.resolve(preferredInputDeviceUID: pref, noiseSuppression: false)
      #expect(d.sourceType == .audioEngine || d.sourceType == .captureSession)
    }
  }
}
