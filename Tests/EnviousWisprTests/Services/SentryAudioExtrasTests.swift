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
      sourceType: "hal_device_input",
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
      sourceType: "hal_device_input",
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
      sourceType: "hal_device_input",
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
      sourceType: "hal_device_input",
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
      sourceType: "hal_device_input",
      sessionID: 1,
      isActivelyCapturing: false,
      inputDeviceUIDPreferred: nil,
      inputDeviceUIDSystemDefault: nil,
      failureMode: "zombie_engine_zero_peak",
      timeSinceLastSuccessfulRecordingMs: 45_000
    )
    #expect(extras["capture.time_since_last_successful_recording_ms"] as? Int == 45_000)
  }

  // MARK: - #1714 input-resolution source

  @Test("input resolution source rides under the settled capture. key")
  func inputResolutionSourceEmitted() {
    let extras = SentryAudioExtras.buildCaptureExtras(
      route: "built_in",
      sourceType: "hal_device_input",
      sessionID: 1,
      isActivelyCapturing: false,
      inputDeviceUIDPreferred: nil,
      inputDeviceUIDSystemDefault: nil,
      failureMode: "no_microphone_found",
      inputResolutionSource: "list_fallback"
    )
    #expect(extras["capture.input_resolution_source"] as? String == "list_fallback")
  }

  @Test("a nil input resolution source omits the key entirely")
  func nilInputResolutionSourceOmitted() {
    // Absent, not NSNull, not "unknown", not empty — an omitted key is what
    // lets a query distinguish "no attribution" from "attributed as unknown".
    let extras = SentryAudioExtras.buildCaptureExtras(
      route: "built_in",
      sourceType: "hal_device_input",
      sessionID: 1,
      isActivelyCapturing: false,
      inputDeviceUIDPreferred: nil,
      inputDeviceUIDSystemDefault: nil,
      failureMode: "no_microphone_found"
    )
    #expect(extras["capture.input_resolution_source"] == nil)
    #expect(extras.keys.contains("capture.input_resolution_source") == false)
  }

  @Test("input and ROUTE resolution sources are distinct keys carrying distinct values")
  func inputAndRouteResolutionSourcesAreDistinct() {
    // The two names are one word apart and answer different questions. Freezing
    // them together is what stops a future edit collapsing them, which would
    // make every query over either one ambiguous.
    let extras = SentryAudioExtras.buildCaptureExtras(
      route: "built_in",
      sourceType: "hal_device_input",
      sessionID: 1,
      isActivelyCapturing: false,
      inputDeviceUIDPreferred: nil,
      inputDeviceUIDSystemDefault: nil,
      failureMode: "no_microphone_found",
      routeResolutionSource: "app_derived",
      inputResolutionSource: "pinned_uid"
    )
    #expect(extras["capture.route_resolution_source"] as? String == "app_derived")
    #expect(extras["capture.input_resolution_source"] as? String == "pinned_uid")
  }

  // MARK: - #2021 tag promotion

  @Test("both promoted fields become tags when present")
  func promotesBothFields() {
    let tags = SentryAudioExtras.promotedTags(from: [
      "capture.effective_transport": "bluetooth",
      "capture.failure_mode": "all_zero_from_start",
      "capture.route": "built_in_mic",
    ])
    #expect(tags["capture.effective_transport"] == "bluetooth")
    #expect(tags["capture.failure_mode"] == "all_zero_from_start")
    // Only the promotion list is promoted; an unrelated extra stays an extra.
    #expect(tags["capture.route"] == nil)
    #expect(tags.count == 2)
  }

  @Test("an absent transport produces NO key, never an empty bucket")
  func absentTransportOmitsTheKey() {
    // The two-way control for the exact defect #2021 reports: aggregating on a
    // field that was written as "" returns one empty bucket, which reads as data
    // and is the instrument. An absent value must not create a key at all.
    let tags = SentryAudioExtras.promotedTags(from: [
      "capture.failure_mode": "became_zero_mid_capture"
    ])
    #expect(tags["capture.effective_transport"] == nil)
    #expect(tags.keys.contains("capture.effective_transport") == false)
    #expect(tags.count == 1)
  }

  @Test("an empty-string value is dropped rather than promoted")
  func emptyStringIsDropped() {
    let tags = SentryAudioExtras.promotedTags(from: [
      "capture.effective_transport": "",
      "capture.failure_mode": "no_buffers",
    ])
    #expect(tags["capture.effective_transport"] == nil)
    #expect(tags.count == 1)
  }

  @Test("nil extras promote nothing")
  func nilExtrasPromoteNothing() {
    #expect(SentryAudioExtras.promotedTags(from: nil).isEmpty)
  }

  @Test("a non-String value is skipped, not stringified")
  func nonStringIsSkipped() {
    // A coerced tag would be a value no query could ever match, which is worse
    // than an absent one.
    let tags = SentryAudioExtras.promotedTags(from: [
      "capture.effective_transport": 42,
      "capture.failure_mode": "all_zero_from_start",
    ])
    #expect(tags["capture.effective_transport"] == nil)
    #expect(tags.count == 1)
  }

  @Test("the promotion list matches keys the builder actually writes")
  func promotionListCannotDriftFromTheBuilder() {
    // Freezes the one way these can silently diverge: a renamed extra key would
    // leave the promotion list pointing at a key nobody writes, and every tag
    // would quietly vanish with no test failing.
    let extras = SentryAudioExtras.buildCaptureExtras(
      route: "built_in_mic",
      sourceType: "hal_device_input",
      sessionID: 1,
      isActivelyCapturing: true,
      inputDeviceUIDPreferred: nil,
      inputDeviceUIDSystemDefault: nil,
      failureMode: "all_zero_from_start",
      effectiveTransport: "usb")
    for key in SentryAudioExtras.promotedTagKeys {
      #expect(extras[key] != nil, "builder no longer writes \(key)")
    }
    let tags = SentryAudioExtras.promotedTags(from: extras)
    #expect(tags["capture.failure_mode"] == "all_zero_from_start")
    #expect(tags["capture.effective_transport"] == "usb")
  }
}
