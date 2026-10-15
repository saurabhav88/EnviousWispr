import EnviousWisprAudio
import EnviousWisprServices

/// The Audio screen's input-socket row (#2664): which device gets the row, which input it
/// shows, and what a pick writes. The screen and the dev control door call this (moved out of
/// `AudioSettingsView` by #3765 PR-C); the index policy itself stays in
/// `InputChannelPreference`.
@MainActor
enum InputChannelSettings {
  static func offersChoice(uid: String, inputChannelCount: Int) -> Bool {
    inputChannelCount > 1 && !uid.isEmpty
  }

  static func selection(for uid: String, inputChannelCount: Int, in preference: [String: Int])
    -> Int
  {
    InputChannelPreference.effectiveChannel(
      requested: InputChannelPreference.requested(for: uid, in: preference),
      availableChannels: inputChannelCount)
  }

  /// The inputs the row offers for a device with `inputChannelCount` inputs: 0 to count - 1.
  static func offers(_ channel: Int, inputChannelCount: Int) -> Bool {
    (0..<inputChannelCount).contains(channel)
  }

  static func choose(_ channel: Int, for uid: String, in settings: SettingsManager) {
    settings.inputChannelByDeviceUID[uid] = channel
  }
}
