import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprServices

@Suite("SentryAudioExtras")
@MainActor
struct SentryAudioExtrasTests {

  @Test("base extras include core fields with stable keys")
  func baseExtras() {
    let extras = SentryAudioExtras.buildCaptureExtras(
      route: "built_in_mic",
      sourceType: "av_audio_engine",
      sessionID: 3,
      isActivelyCapturing: true,
      inputDeviceUIDPreferred: "ABC",
      inputDeviceUIDSystemDefault: "ABC",
      failureMode: "stalled"
    )
    #expect(extras["capture.source_type"] as? String == "av_audio_engine")
    #expect(extras["capture.route"] as? String == "built_in_mic")
    #expect(extras["capture.failure_mode"] as? String == "stalled")
    #expect(extras["capture.is_actively_capturing"] as? Bool == true)
    #expect(extras["capture_session_id"] as? Int == 3)
    #expect(extras["capture.input_device_divergence"] as? Bool == false)
  }

  @Test("divergence flag true when preferred differs from system default")
  func divergence() {
    let extras = SentryAudioExtras.buildCaptureExtras(
      route: "bt",
      sourceType: "av_capture_session",
      sessionID: 1,
      isActivelyCapturing: true,
      inputDeviceUIDPreferred: "MacBookMic",
      inputDeviceUIDSystemDefault: "AirPodsPro",
      failureMode: "no_audio_captured"
    )
    #expect(extras["capture.input_device_divergence"] as? Bool == true)
  }

  @Test("stall context adds stall-specific keys + window ms math")
  func stallContextAddsKeys() {
    let ctx = CaptureStallContext(
      sessionID: 9,
      armedAtUptimeNs: 1_000_000_000,
      firedAtUptimeNs: 1_800_000_000,
      route: "bt",
      sourceType: "av_capture_session",
      engineStartedSuccessfully: true,
      tapInstalled: true,
      formatMismatchObserved: true,
      inputDeviceUIDPreferred: nil,
      inputDeviceUIDSystemDefault: nil
    )
    let extras = SentryAudioExtras.buildCaptureExtras(
      route: ctx.route,
      sourceType: ctx.sourceType,
      sessionID: ctx.sessionID,
      isActivelyCapturing: true,
      inputDeviceUIDPreferred: nil,
      inputDeviceUIDSystemDefault: nil,
      failureMode: "stalled",
      stallContext: ctx,
      polishModelSwapMs: 4500
    )
    #expect(extras["capture.stall.window_ms"] as? Int == 800)
    #expect(extras["capture.format_mismatch"] as? Bool == true)
    #expect(extras["capture.tap_installed"] as? Bool == true)
    #expect(extras["polish.recent_model_swap_ms"] as? Int == 4500)
  }

  @Test("nil polish swap omits the key entirely")
  func polishSwapOmission() {
    let extras = SentryAudioExtras.buildCaptureExtras(
      route: "built_in_mic",
      sourceType: "av_audio_engine",
      sessionID: 1,
      isActivelyCapturing: true,
      inputDeviceUIDPreferred: nil,
      inputDeviceUIDSystemDefault: nil,
      failureMode: "thrown_start"
    )
    #expect(extras["polish.recent_model_swap_ms"] == nil)
  }

  @Test("zombie telemetry extras: nil inputs omit both keys")
  func zombieExtrasOmitted() {
    let extras = SentryAudioExtras.buildCaptureExtras(
      route: "bt",
      sourceType: "xpc_proxy",
      sessionID: 1,
      isActivelyCapturing: false,
      inputDeviceUIDPreferred: nil,
      inputDeviceUIDSystemDefault: nil,
      failureMode: "zombie_engine_zero_peak"
    )
    #expect(extras["capture.time_since_last_successful_recording_ms"] == nil)
    #expect(extras["capture.config_change_count_since_launch"] == nil)
  }

  @Test("zombie telemetry extras: values passed through with stable keys")
  func zombieExtrasPassthrough() {
    let extras = SentryAudioExtras.buildCaptureExtras(
      route: "bt",
      sourceType: "xpc_proxy",
      sessionID: 1,
      isActivelyCapturing: false,
      inputDeviceUIDPreferred: nil,
      inputDeviceUIDSystemDefault: nil,
      failureMode: "zombie_engine_zero_peak",
      timeSinceLastSuccessfulRecordingMs: 45_000,
      configChangeCountSinceLaunch: 0
    )
    #expect(extras["capture.time_since_last_successful_recording_ms"] as? Int == 45_000)
    #expect(extras["capture.config_change_count_since_launch"] as? Int == 0)
  }
}
