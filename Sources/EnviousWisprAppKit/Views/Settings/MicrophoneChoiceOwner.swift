import EnviousWisprAudio

/// Saves a microphone choice only if it is still the latest one after its fresh check (#4021).
///
/// One instance, built and kept by `WisprBootstrapper` and shared by the Settings and Setup
/// picker and the menu bar Microphone submenu, so a slow check for an older click can never
/// overwrite a newer choice made on another screen. The check runs on the shared
/// `CoreAudioQueryLane` (`MicrophoneChoiceValidation`), so a stuck driver cannot freeze the app.
@MainActor
final class MicrophoneChoiceOwner {
  private let lane: CoreAudioQueryLane
  private let connectedUIDs: @Sendable () -> [String]
  private var latest = 0
  /// Called when a choice is settled: saved, or dropped (not connected, no answer, or superseded).
  /// The signal tests wait on; nothing in the app depends on it.
  var onSettled: ((_ uid: String, _ saved: Bool) -> Void)?

  init(
    lane: CoreAudioQueryLane,
    connectedUIDs: @escaping @Sendable () -> [String] = {
      AudioDeviceEnumerator.allInputDevices().map(\.uid)
    }
  ) {
    self.lane = lane
    self.connectedUIDs = connectedUIDs
  }

  /// Every choice takes a new token before anything else, so an older pending check can no longer
  /// save. Auto ("") saves at once without asking the lane. Any other device is checked off the
  /// main actor and saved only if it is still connected and still the latest choice.
  func choose(uid: String, save: @escaping @MainActor (String) -> Void) {
    latest &+= 1
    let token = latest
    if uid.isEmpty {
      save(uid)
      onSettled?(uid, true)
      return
    }
    let lane = lane
    let connectedUIDs = connectedUIDs
    Task { [weak self] in
      let selectable = await MicrophoneChoiceValidation.isSelectable(
        uid: uid, lane: lane, connectedUIDs: connectedUIDs)
      guard let self else { return }
      guard token == self.latest, selectable else {
        self.onSettled?(uid, false)
        return
      }
      save(uid)
      self.onSettled?(uid, true)
    }
  }
}
