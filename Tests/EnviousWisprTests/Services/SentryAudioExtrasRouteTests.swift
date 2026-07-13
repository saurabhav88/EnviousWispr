import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprServices

// #1376 — locks the effective-device route keys on the Sentry capture-error
// extras: present when supplied, omitted when nil (mirroring the existing
// optional-extras pattern), the honest `capture.effective_transport` name (NOT
// the Phase-3-reserved `actual_started_transport`, CR1), and only allowed
// low-cardinality metadata (no dictated content — `telemetry-privacy-boundary`).
@Suite("SentryAudioExtras route fields — #1376")
@MainActor
struct SentryAudioExtrasRouteTests {

  @Test("route params populate the capture.* keys")
  func routeKeysPresent() {
    let extras = SentryAudioExtras.buildCaptureExtras(
      route: "hal_device_input", sourceType: "xpc_proxy", sessionID: 1,
      isActivelyCapturing: true, inputDeviceUIDPreferred: nil,
      inputDeviceUIDSystemDefault: nil, failureMode: "no_audio_captured",
      selectedTransport: "bluetooth", effectiveTransport: "built_in",
      routeReason: "btOutputUserSelectedDevice", routeFallbackReason: nil,
      inputSelectionMode: "explicit", outputTransport: "bluetooth",
      routeResolutionSource: "app_derived")

    #expect(extras["capture.selected_transport"] as? String == "bluetooth")
    #expect(extras["capture.effective_transport"] as? String == "built_in")
    #expect(extras["capture.route_reason"] as? String == "btOutputUserSelectedDevice")
    #expect(extras["capture.input_selection_mode"] as? String == "explicit")
    #expect(extras["capture.output_transport"] as? String == "bluetooth")
    #expect(extras["capture.route_resolution_source"] as? String == "app_derived")

    // Nil fallback reason → key omitted (presence IS the fallback-rung signal).
    #expect(extras["capture.route_fallback_reason"] == nil)
    // CR1: the Phase-3-reserved name must never appear this phase.
    #expect(extras["capture.actual_started_transport"] == nil)
  }

  @Test("absent route params omit every capture.* route key")
  func routeKeysOmitted() {
    let extras = SentryAudioExtras.buildCaptureExtras(
      route: "built_in_mic", sourceType: "av_audio_engine", sessionID: 2,
      isActivelyCapturing: false, inputDeviceUIDPreferred: nil,
      inputDeviceUIDSystemDefault: nil, failureMode: "stalled")

    #expect(extras["capture.selected_transport"] == nil)
    #expect(extras["capture.effective_transport"] == nil)
    #expect(extras["capture.route_reason"] == nil)
    #expect(extras["capture.input_selection_mode"] == nil)
    #expect(extras["capture.output_transport"] == nil)
    #expect(extras["capture.route_resolution_source"] == nil)
    // The pre-existing keys are unaffected.
    #expect(extras["capture.route"] as? String == "built_in_mic")
  }

  @Test("a fallback rung's route_fallback_reason is emitted when supplied")
  func fallbackReasonPresent() {
    let extras = SentryAudioExtras.buildCaptureExtras(
      route: "failed", sourceType: "av_audio_engine", sessionID: 3,
      isActivelyCapturing: false, inputDeviceUIDPreferred: nil,
      inputDeviceUIDSystemDefault: nil, failureMode: "no_audio_captured",
      routeReason: "failedNoFallback", routeFallbackReason: "failedNoFallback")
    #expect(extras["capture.route_fallback_reason"] as? String == "failedNoFallback")
  }
}
