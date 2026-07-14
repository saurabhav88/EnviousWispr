import Foundation
import Testing

@testable import EnviousWisprCore

@Suite("HeartPathContexts")
struct HeartPathContextsTests {

  @Test("CaptureStallContext is Sendable and carries all fields")
  func captureStallContextRoundTrip() {
    let ctx = CaptureStallContext(
      sessionID: 42,
      armedAtUptimeNs: 1_000_000_000,
      firedAtUptimeNs: 1_800_000_000,
      route: "built_in_mic",
      sourceType: "hal_device_input",
      engineStartedSuccessfully: true,
      tapInstalled: true,
      formatMismatchObserved: false,
      inputDeviceUIDPreferred: "BuiltInMicrophoneDevice",
      inputDeviceUIDSystemDefault: "BuiltInMicrophoneDevice",
      failureMode: .noBuffers
    )
    #expect(ctx.sessionID == 42)
    #expect(ctx.firedAtUptimeNs - ctx.armedAtUptimeNs == 800_000_000)
    #expect(ctx.sourceType == "hal_device_input")
    #expect(ctx.formatMismatchObserved == false)
  }

  @Test("#1523: enrichedWithStabilizationFlags preserves the source-stamped channel count")
  func enrichmentPreservesChannelCount() {
    let source = CaptureStallContext(
      sessionID: 1,
      armedAtUptimeNs: 0,
      firedAtUptimeNs: 1,
      route: "hal_device_input",
      sourceType: "hal_device_input",
      engineStartedSuccessfully: true,
      tapInstalled: true,
      formatMismatchObserved: false,
      inputDeviceUIDPreferred: nil,
      inputDeviceUIDSystemDefault: nil,
      failureMode: .noBuffers,
      nativeChannelCount: 6
    )
    // The kernel merges its stabilization observations without reconstructing
    // the context from scratch, so the source-stamped channel count must survive.
    let enriched = source.enrichedWithStabilizationFlags(
      formatStabilized: true, captureRebuiltForFormat: false)
    #expect(enriched.nativeChannelCount == 6)
    #expect(enriched.formatStabilized == true)
    // A source that never stamps a count leaves it nil through enrichment.
    #expect(
      source.enrichedWithStabilizationFlags(formatStabilized: nil, captureRebuiltForFormat: nil)
        .nativeChannelCount == 6)
    let unstamped = CaptureStallContext(
      sessionID: 1, armedAtUptimeNs: 0, firedAtUptimeNs: 1, route: "proxy",
      sourceType: "proxy", engineStartedSuccessfully: true, tapInstalled: true,
      formatMismatchObserved: false, inputDeviceUIDPreferred: nil,
      inputDeviceUIDSystemDefault: nil, failureMode: .noBuffers
    )
    #expect(
      unstamped.enrichedWithStabilizationFlags(
        formatStabilized: nil, captureRebuiltForFormat: nil
      ).nativeChannelCount == nil)
  }

  @Test("#1543: enrichedWithManagerRoute overlays session id + route, preserves source fields")
  func managerRouteEnrichmentOverlaysAndPreserves() {
    // A HAL-built stall: per-source generation id, coarse `hal_device_input`
    // route, nil resolved-route fields, but real source-stamped health fields.
    let halBuilt = CaptureStallContext(
      sessionID: 1,  // per-source generation — repeats across source rebuilds
      armedAtUptimeNs: 100,
      firedAtUptimeNs: 200,
      route: "hal_device_input",
      sourceType: "hal_device_input",
      engineStartedSuccessfully: true,
      tapInstalled: true,
      formatMismatchObserved: false,
      inputDeviceUIDPreferred: "BuiltInMicrophoneDevice",
      inputDeviceUIDSystemDefault: "BuiltInMicrophoneDevice",
      failureMode: .noBuffers,
      nativeRateHz: 48_000,
      rateDivergenceDetected: true,
      nativeChannelCount: 2
    )
    let enriched = halBuilt.enrichedWithManagerRoute(
      sessionID: 7,  // manager's app-lifetime id
      route: "built_in_mic",
      selectedTransport: "builtin",
      effectiveTransport: "builtin",
      routeReason: "no_bt_auto_input",
      routeFallbackReason: nil,
      inputSelectionMode: "auto",
      outputTransport: "speaker",
      routeResolutionSource: "app_derived")
    // Overlaid: app-lifetime session id + real route bucket + transport detail.
    #expect(enriched.sessionID == 7)
    #expect(enriched.route == "built_in_mic")
    #expect(enriched.selectedTransport == "builtin")
    #expect(enriched.routeReason == "no_bt_auto_input")
    // Preserved: source-stamped health + device fields + failure mode.
    #expect(enriched.nativeRateHz == 48_000)
    #expect(enriched.rateDivergenceDetected == true)
    #expect(enriched.nativeChannelCount == 2)
    #expect(enriched.inputDeviceUIDPreferred == "BuiltInMicrophoneDevice")
    #expect(enriched.failureMode == .noBuffers)
    #expect(enriched.armedAtUptimeNs == 100)
  }
}
