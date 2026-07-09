import EnviousWisprAudio
import EnviousWisprServices

@MainActor
final class InputDevicePreferenceReconciler {
  private let settings: SettingsManager

  init(settings: SettingsManager) {
    self.settings = settings
  }

  func reconcile(availableDevices: [AudioInputDevice]) {
    let connectedUIDs = Set(availableDevices.map(\.uid))
    let reconciled = InputDevicePreferencePolicy.reconciled(
      preferredOverride: settings.preferredInputDeviceIDOverride,
      selectedUID: settings.selectedInputDeviceUID,
      connectedUIDs: connectedUIDs
    )

    let preferredChanged = reconciled.preferredOverride != settings.preferredInputDeviceIDOverride
    let selectedChanged = reconciled.selectedUID != settings.selectedInputDeviceUID
    guard preferredChanged || selectedChanged else { return }

    settings.isApplyingSystemWrite = true
    defer { settings.isApplyingSystemWrite = false }

    if preferredChanged {
      settings.preferredInputDeviceIDOverride = reconciled.preferredOverride
    }
    if selectedChanged {
      settings.selectedInputDeviceUID = reconciled.selectedUID
    }
  }
}
