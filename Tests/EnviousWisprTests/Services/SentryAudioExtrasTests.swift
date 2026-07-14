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
      sourceType: "hal_device_input",
      sessionID: 3,
      isActivelyCapturing: true,
      inputDeviceUIDPreferred: "ABC",
      inputDeviceUIDSystemDefault: "ABC",
      failureMode: "stalled"
    )
    #expect(extras["capture.source_type"] as? String == "hal_device_input")
    #expect(extras["capture.route"] as? String == "built_in_mic")
    #expect(extras["capture.failure_mode"] as? String == "stalled")
    #expect(extras["capture.is_actively_capturing"] as? Bool == true)
    #expect(extras["capture_session_id"] as? Int == 3)
    #expect(extras["capture.preferred_input_set"] as? Bool == true)
    #expect(extras["capture.input_device_divergence"] as? Bool == false)
  }

  @Test("divergence flag true when preferred differs from system default")
  func divergence() {
    let extras = SentryAudioExtras.buildCaptureExtras(
      route: "bt",
      sourceType: "hal_device_input",
      sessionID: 1,
      isActivelyCapturing: true,
      inputDeviceUIDPreferred: "MacBookMic",
      inputDeviceUIDSystemDefault: "AirPodsPro",
      failureMode: "no_audio_captured"
    )
    #expect(extras["capture.preferred_input_set"] as? Bool == true)
    #expect(extras["capture.input_device_divergence"] as? Bool == true)
  }

  @Test("divergence false when no preferred input is set")
  func noPreferredInputIsNotDivergence() {
    let extras = SentryAudioExtras.buildCaptureExtras(
      route: "built_in_mic",
      sourceType: "xpc_proxy",
      sessionID: 1,
      isActivelyCapturing: false,
      inputDeviceUIDPreferred: nil,
      inputDeviceUIDSystemDefault: "BuiltInMicrophoneDevice",
      failureMode: "zombie_engine_zero_peak"
    )
    #expect(extras["capture.preferred_input_set"] as? Bool == false)
    #expect(extras["capture.input_device_uid_preferred"] is NSNull)
    #expect(
      extras["capture.input_device_uid_system_default"] as? String == "BuiltInMicrophoneDevice")
    #expect(extras["capture.input_device_divergence"] as? Bool == false)
  }

  @Test("divergence false when both input UIDs are unknown")
  func bothUnknownInputUIDsAreNotDivergence() {
    let extras = SentryAudioExtras.buildCaptureExtras(
      route: "built_in_mic",
      sourceType: "xpc_proxy",
      sessionID: 1,
      isActivelyCapturing: false,
      inputDeviceUIDPreferred: nil,
      inputDeviceUIDSystemDefault: nil,
      failureMode: "zombie_engine_zero_peak"
    )
    #expect(extras["capture.preferred_input_set"] as? Bool == false)
    #expect(extras["capture.input_device_uid_preferred"] is NSNull)
    #expect(extras["capture.input_device_uid_system_default"] is NSNull)
    #expect(extras["capture.input_device_divergence"] as? Bool == false)
  }

  @Test("empty preferred input behaves like no preferred input")
  func emptyPreferredInputUIDIsNotSet() {
    let extras = SentryAudioExtras.buildCaptureExtras(
      route: "built_in_mic",
      sourceType: "xpc_proxy",
      sessionID: 1,
      isActivelyCapturing: false,
      inputDeviceUIDPreferred: "",
      inputDeviceUIDSystemDefault: "BuiltInMicrophoneDevice",
      failureMode: "zombie_engine_zero_peak"
    )
    #expect(extras["capture.preferred_input_set"] as? Bool == false)
    #expect(extras["capture.input_device_uid_preferred"] is NSNull)
    #expect(extras["capture.input_device_divergence"] as? Bool == false)
  }

  @Test("stall context adds stall-specific keys + window ms math")
  func stallContextAddsKeys() {
    let ctx = CaptureStallContext(
      sessionID: 9,
      armedAtUptimeNs: 1_000_000_000,
      firedAtUptimeNs: 1_800_000_000,
      route: "bt",
      sourceType: "hal_device_input",
      engineStartedSuccessfully: true,
      tapInstalled: true,
      formatMismatchObserved: true,
      inputDeviceUIDPreferred: nil,
      inputDeviceUIDSystemDefault: nil,
      failureMode: .noBuffers
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
    #expect(extras["capture.preferred_input_set"] as? Bool == false)
    #expect(extras["capture.format_mismatch"] as? Bool == true)
    #expect(extras["capture.tap_installed"] as? Bool == true)
    #expect(extras["polish.recent_model_swap_ms"] as? Int == 4500)
    // #1523: a source that never stamped a channel count omits the key.
    #expect(extras["capture.native_channel_count"] == nil)
  }

  @Test("#1523: a source-stamped channel count rides the stall extras")
  func stallContextCarriesChannelCount() {
    let ctx = CaptureStallContext(
      sessionID: 9,
      armedAtUptimeNs: 1_000_000_000,
      firedAtUptimeNs: 1_800_000_000,
      route: "bt",
      sourceType: "hal_device_input",
      engineStartedSuccessfully: true,
      tapInstalled: true,
      formatMismatchObserved: true,
      inputDeviceUIDPreferred: nil,
      inputDeviceUIDSystemDefault: nil,
      failureMode: .noBuffers,
      nativeChannelCount: 2
    )
    let extras = SentryAudioExtras.buildCaptureExtras(
      route: ctx.route,
      sourceType: ctx.sourceType,
      sessionID: ctx.sessionID,
      isActivelyCapturing: true,
      inputDeviceUIDPreferred: nil,
      inputDeviceUIDSystemDefault: nil,
      failureMode: "stalled",
      stallContext: ctx
    )
    #expect(extras["capture.native_channel_count"] as? Int == 2)
  }

  @Test("nil polish swap omits the key entirely")
  func polishSwapOmission() {
    let extras = SentryAudioExtras.buildCaptureExtras(
      route: "built_in_mic",
      sourceType: "hal_device_input",
      sessionID: 1,
      isActivelyCapturing: true,
      inputDeviceUIDPreferred: nil,
      inputDeviceUIDSystemDefault: nil,
      failureMode: "thrown_start"
    )
    #expect(extras["polish.recent_model_swap_ms"] == nil)
  }

  @Test("zombie telemetry extras: nil inputs omit the key")
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
      timeSinceLastSuccessfulRecordingMs: 45_000
    )
    #expect(extras["capture.time_since_last_successful_recording_ms"] as? Int == 45_000)
  }
}
