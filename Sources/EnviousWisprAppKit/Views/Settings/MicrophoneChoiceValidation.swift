import EnviousWisprAudio

/// Whether a microphone choice may still be saved (#3479, #3486).
///
/// A microphone unplugged while the Settings dropdown or the menu bar Microphone submenu is open
/// leaves a clickable row. Saving that device writes both preference keys and nothing corrects
/// them afterwards, so recording silently falls back to another input. Both doors ask here, at
/// click time, because the cached list in `AudioDeviceList` refreshes on a separately scheduled
/// task and can still hold the removed device.
enum MicrophoneChoiceValidation {
  /// Auto ("") is always valid; any other UID must be an input the system lists right now.
  @MainActor
  static func isSelectable(
    uid: String,
    connectedUIDs: () -> [String] = { AudioDeviceEnumerator.allInputDevices().map(\.uid) }
  ) -> Bool {
    uid.isEmpty || connectedUIDs().contains(uid)
  }
}
