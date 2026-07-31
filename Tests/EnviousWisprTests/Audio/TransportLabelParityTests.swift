import CoreAudio
import Foundation
import Testing

@testable import EnviousWisprAudio

// #1376 — locks `AudioDeviceEnumerator.transportLabel(forTransportType:)`, the
// single transport-string authority extracted from
// `AudioEnvironmentSnapshotter.deviceTransport`. Byte-identical mapping incl the
// nil case, so the existing `input_device_transport` / `output_device_transport`
// Sentry values do not drift after the extraction.
@Suite("TransportLabel parity — #1376")
struct TransportLabelParityTests {

  @Test("each CoreAudio transport constant maps to its stable label")
  func mapping() {
    let cases: [(UInt32, String)] = [
      (kAudioDeviceTransportTypeBuiltIn, "built_in"),
      (kAudioDeviceTransportTypeBluetooth, "bluetooth"),
      (kAudioDeviceTransportTypeBluetoothLE, "bluetooth"),
      (kAudioDeviceTransportTypeUSB, "usb"),
      (kAudioDeviceTransportTypeAggregate, "aggregate"),
      (kAudioDeviceTransportTypeVirtual, "virtual"),
      (kAudioDeviceTransportTypeDisplayPort, "display_port"),
      (kAudioDeviceTransportTypeHDMI, "hdmi"),
      (kAudioDeviceTransportTypeAirPlay, "air_play"),
      (kAudioDeviceTransportTypePCI, "pci"),
      (kAudioDeviceTransportTypeFireWire, "fire_wire"),
      (kAudioDeviceTransportTypeThunderbolt, "thunderbolt"),
      // #1714 founder decision 2026-07-30: these three are ACCEPTED by the
      // capture allow-list, so they must not report as `unknown`.
      (kAudioDeviceTransportTypeContinuityCaptureWired, "continuity_capture_wired"),
      (kAudioDeviceTransportTypeContinuityCaptureWireless, "continuity_capture_wireless"),
      (kAudioDeviceTransportTypeAVB, "avb"),
    ]
    #expect(cases.count == 15, "the frozen table must cover every named transport")
    for (raw, expected) in cases {
      #expect(AudioDeviceEnumerator.transportLabel(forTransportType: raw) == expected)
    }
  }

  @Test("nil raw transport preserves nil (load-bearing for optional Sentry keys)")
  func nilPreserved() {
    #expect(AudioDeviceEnumerator.transportLabel(forTransportType: nil) == nil)
  }

  @Test("an unmapped transport constant falls back to unknown, not nil")
  func unknownFallback() {
    #expect(AudioDeviceEnumerator.transportLabel(forTransportType: 0xFFFF_FFFF) == "unknown")
  }
}

// #1714 whole-diff review: the per-device channel-count read has the same
// failure-vs-empty split as the transport read above. `inputChannelCountRaw`
// preserves it; `inputChannelCount` deliberately collapses it for the settings
// picker and bind-time telemetry, whose behaviour must not change.
@Suite("input channel count — failure vs empty (#1714)")
struct InputChannelCountNilPreservationTests {

  @Test("the collapsing wrapper is defined as the raw value or zero")
  func collapsingWrapperMatchesRaw() {
    // Both read the same live device id. The point is not the number — it is
    // that the collapsing form never returns nil and the raw form is what the
    // capture snapshot consumes. A device id no machine assigns exercises the
    // failure path without depending on this machine's hardware.
    let absentDeviceID: AudioDeviceID = 0xFFFF_FFFE

    let raw = AudioDeviceEnumerator.inputChannelCountRaw(for: absentDeviceID)
    let collapsed = AudioDeviceEnumerator.inputChannelCount(for: absentDeviceID)

    #expect(raw == nil, "a failed read must be nil, not zero")
    #expect(collapsed == 0, "the collapsing wrapper preserves today's behaviour for its callers")
  }
}
