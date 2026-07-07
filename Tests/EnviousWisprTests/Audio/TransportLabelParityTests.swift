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
    ]
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
