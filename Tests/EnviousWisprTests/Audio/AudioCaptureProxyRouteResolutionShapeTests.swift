import Testing

@testable import EnviousWisprAudio

// #1533 (r2 finding 1) — the route flip lives in the shared `CaptureRouteResolver`,
// which has TWO runtime consumers: the helper-side `AudioCaptureManager` (the
// authoritative source construction) and the app-side `AudioCaptureProxy`
// (telemetry-only route facts). The helper consumer is covered by
// `CaptureRouteResolverTests`; this suite locks the SECOND consumer so it cannot
// silently disappear — the proxy must still own a working resolver and derive a
// non-nil app-side route through it.
@MainActor
@Suite("AudioCaptureProxy route-resolution shape — #1533")
struct AudioCaptureProxyRouteResolutionShapeTests {

  @Test("proxy derives an app-side resolved route through its own resolver")
  func proxyDerivesTelemetryRoute() {
    let proxy = AudioCaptureProxy()
    // Before any derivation the proxy reports the unknown placeholder.
    #expect(proxy.currentAudioRoute == "unknown")
    #expect(proxy.currentResolvedRoute == nil)

    proxy.deriveResolvedRouteForTest()

    // The resolver ran and produced telemetry regardless of which output device
    // is live: a real coarse route label and a resolved-route observation.
    #expect(proxy.currentAudioRoute != "unknown")
    #expect(proxy.currentResolvedRoute != nil)
    // Post-cutover the coarse label is always one of the two surviving reasons'
    // labels — never the deleted engine's `"audio_engine"`.
    #expect(["built_in_mic", "hal_device_input"].contains(proxy.currentAudioRoute))
    #expect(proxy.currentResolvedRoute?.routeReason != nil)
  }
}
