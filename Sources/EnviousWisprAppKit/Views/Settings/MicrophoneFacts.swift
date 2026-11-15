import CoreAudio
import EnviousWisprAudio

/// The microphone facts a screen shows, frozen from the last accepted device snapshot (#4021).
///
/// Built by `AudioDeviceList.microphoneFacts`; read by the Settings and Setup microphone picker
/// and the menu bar instead of asking Core Audio on the main thread, where a stuck third-party
/// driver froze the app. Owns no refresh and no selection policy. Before the first snapshot it is
/// empty: no devices, no Auto device, no labels, so screens offer Auto only and a saved pin stays
/// saved and unresolved.
struct MicrophoneFacts: Equatable {
  /// The microphones to list, in system order.
  let devices: [AudioInputDevice]
  /// The device Auto would open, from the snapshot's resolver pass; nil when none or unknown.
  let resolvedAutoDeviceID: AudioDeviceID?
  /// Each listed device's transport token, keyed by device ID; missing when unreadable.
  let transportTokens: [AudioDeviceID: String]

  static let empty = MicrophoneFacts(devices: [], resolvedAutoDeviceID: nil, transportTokens: [:])
}
