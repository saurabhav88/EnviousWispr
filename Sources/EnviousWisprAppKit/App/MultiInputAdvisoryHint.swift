import CoreAudio
import EnviousWisprAudio
import EnviousWisprCore

/// #2664. Facts the silent-take advisory needs to name a multi-input device.
///
/// Built at PRESENT time from settings + the device list, and it carries the
/// device NAME only (founder, Gate 2, 2026-09-05). It makes no claim about which
/// input is configured or was recorded, so present-time evaluation, a later
/// settings change, or a refused channel map cannot make the sentence false: the
/// device named is the one the user will find selected in Settings, and "no
/// audio came through" is what the take established. Presentation-only; never
/// enters telemetry.
struct MultiInputAdvisoryHint: Equatable, Sendable {
  let deviceName: String

  /// nil for `.noTransport` (no device was ever opened, so there is no socket to
  /// try), nil when no device is known (including an empty device list), and nil
  /// for a one-input device — in every nil case the locked seventh sentence
  /// shows, byte-identical to today.
  static func make(reason: TerminalAdvisoryReason, socketDevice: AudioInputDevice?) -> Self? {
    switch reason {
    case .noTransport:
      return nil
    case .zeroSignal, .vadGateNoSpeech:
      break
    }
    guard let socketDevice, socketDevice.inputChannelCount > 1 else { return nil }
    return Self(deviceName: socketDevice.name)
  }
}

/// #2664. The ONE rule for "which device would the Microphone settings row
/// describe right now": the pinned device when one is set, else the device Auto
/// would actually OPEN (not the raw system default — since #2022 those differ
/// when the default is a virtual or aggregate device the ladder refuses). The
/// settings row and the advisory hint both call this, so they can never name
/// two different devices for one state.
enum InputSocket {
  static func socketDevice(
    preferredInputDeviceIDOverride: String,
    devices: [AudioInputDevice],
    resolvedAutoInputDeviceID: () -> AudioDeviceID?
  ) -> AudioInputDevice? {
    if !preferredInputDeviceIDOverride.isEmpty {
      // Same rule as the picker's own lookup: first match by UID.
      return devices.first { $0.uid == preferredInputDeviceIDOverride }
    }
    guard let resolvedID = resolvedAutoInputDeviceID() else { return nil }
    return devices.first { $0.id == resolvedID }
  }
}
