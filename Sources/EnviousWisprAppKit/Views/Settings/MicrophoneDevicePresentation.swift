import EnviousWisprAudio
import Foundation

/// What the Microphone tab says about the microphone (#3385), as plain
/// values. Built from inputs the caller has already read: the saved preference,
/// the device the existing resolver chose, and that device's transport token.
/// It reads no hardware and writes nothing.
///
/// Honest by construction: Auto is a selection rule, not a kind of device, so
/// it is its own flag beside the transport badge; a transport the app cannot
/// name in the UI shows no badge rather than a guess; an unresolved
/// preference borrows neither another device's name nor its badge.
struct MicrophoneDevicePresentation: Equatable {
  let isAutomatic: Bool
  let deviceName: String?
  let deviceUID: String?
  let deviceIcon: String
  let transportBadge: String?

  static func make(
    preferredUID: String,
    resolvedDevice: AudioInputDevice?,
    transportToken: String?
  ) -> Self {
    let isAutomatic = preferredUID.isEmpty
    // An explicit preference names only a matching resolved device.
    // A missing or mismatched result does not establish disconnection.
    let device = resolvedDevice.flatMap { device in
      isAutomatic || device.uid == preferredUID ? device : nil
    }
    return Self(
      isAutomatic: isAutomatic,
      deviceName: device?.name,
      deviceUID: device?.uid,
      deviceIcon: device == nil ? "mic" : deviceIcon(for: transportToken),
      transportBadge: device == nil ? nil : transportBadge(for: transportToken))
  }

  /// Transport evidence supports a connection icon, not a guessed device model.
  /// Built-in also includes an audio jack, so it must not imply a laptop microphone.
  static func deviceIcon(for token: String?) -> String {
    switch token {
    case "usb": return "cable.connector"
    case "bluetooth": return "dot.radiowaves.left.and.right"
    default: return "mic"
    }
  }

  /// The three transports the picker names, from `AudioDeviceEnumerator`'s
  /// tokens. Every other token, nil included, shows no badge.
  static func transportBadge(for token: String?) -> String? {
    switch token {
    case "built_in":
      return String(
        localized: "Built-in",
        comment: "Microphone settings: the microphone is built into the Mac (or its audio jack).")
    case "usb":
      return String(
        localized: "USB", comment: "Microphone settings: the microphone is connected over USB.")
    case "bluetooth":
      return String(
        localized: "Bluetooth",
        comment: "Microphone settings: the microphone is connected over Bluetooth.")
    default:
      return nil
    }
  }
}
