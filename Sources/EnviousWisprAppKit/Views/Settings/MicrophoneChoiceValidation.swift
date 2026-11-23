import EnviousWisprAudio

/// Whether a microphone choice may still be saved (#3479, #3486).
///
/// A microphone unplugged while the Settings dropdown or the menu bar Microphone submenu is open
/// leaves a clickable row. Saving that device writes both preference keys and nothing corrects
/// them afterwards, so recording silently falls back to another input. Both doors ask here, at
/// click time, because the cached list in `AudioDeviceList` refreshes on a separately scheduled
/// task and can still hold the removed device.
///
/// #4021: the click-time read runs on `CoreAudioQueryLane`, never on the main actor (a stuck
/// third-party driver froze the app there). If the lane cannot answer in time, a non-Auto
/// choice is not selectable, exactly as if the device were unplugged: nothing is saved.
enum MicrophoneChoiceValidation {
  /// Auto ("") is always valid; any other UID must be in `connectedUIDs`. Pure: no Core Audio
  /// read of its own (the DEBUG dev control passes its own list).
  @MainActor
  static func isSelectable(uid: String, connectedUIDs: () -> [String]) -> Bool {
    uid.isEmpty || connectedUIDs().contains(uid)
  }

  /// The click-time check for real choices: the system's input UIDs, read on the lane.
  @MainActor
  static func isSelectable(
    uid: String, lane: CoreAudioQueryLane,
    connectedUIDs: @escaping @Sendable () -> [String] = {
      AudioDeviceEnumerator.allInputDevices().map(\.uid)
    }
  ) async -> Bool {
    if uid.isEmpty { return true }
    // The read runs inside the lane's worker, never before entering it.
    guard case .value(let uids) = await lane.bounded("choice_validation", connectedUIDs) else {
      return false
    }
    return uids.contains(uid)
  }
}
