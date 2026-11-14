import EnviousWisprAudio
import EnviousWisprServices
import SwiftUI

/// The microphone picker's caller logic, shared by every screen that shows
/// `MicrophoneDevicePicker` (#4528 D6a): Settings' Microphone tab and Setup's
/// Practice screen. It moved here unchanged from `AudioSettingsView.body`, so the
/// two screens describe the same device, name the same transports and save a
/// choice through the same guarded write.
///
/// A value built once per body from the live settings and device list, never
/// stored or observed itself: the caller's view re-renders when those owners
/// change and builds a fresh one, so it never holds a stale device.
@MainActor
struct MicrophonePickerModel {
  /// The device the screen describes: the saved choice, or under Auto the device
  /// the resolver ladder would open. Nil when neither is in `devices`.
  let socketDevice: AudioInputDevice?
  /// `socketDevice` when it offers an input-socket choice, else nil.
  let multiInputDevice: AudioInputDevice?
  /// The microphones the menu lists.
  let devices: [AudioInputDevice]
  /// Each listed device's transport token, keyed by device ID.
  let transportTokens: [UInt32: String]
  /// The dropdown card's name, icon and transport badge.
  let presentation: MicrophoneDevicePresentation
  /// The picker's choice: "" is Auto, otherwise a device UID.
  let selection: Binding<String>

  init(settingsManager: SettingsManager, devices: [AudioInputDevice]) {
    // #2664: the device this page describes, computed ONCE per body (the Auto
    // branch runs the resolver ladder, so two computed properties would pay for
    // it twice). Since #2022 Auto names the device the ladder would actually
    // OPEN, not the raw system default: printing "Using Krisp" while recording
    // from the built-in microphone is the one thing the pill must not do. The
    // "Using X" pill and the socket row both read this local, and the advisory
    // hint uses the same rule, so the three can never disagree about one state.
    // (#3385: the "Using X" pill became the dropdown card's own name line; it
    // still reads this one local.)
    let socketDevice = InputSocket.socketDevice(
      preferredInputDeviceIDOverride: settingsManager.preferredInputDeviceIDOverride,
      devices: devices,
      resolvedAutoInputDeviceID: AudioDeviceEnumerator.resolvedAutoInputDeviceID)
    let inputDeviceSelection = Binding<String>(
      get: { settingsManager.preferredInputDeviceIDOverride },
      // #3486: a mic unplugged while the dropdown was open must not be saved.
      set: { uid in
        guard MicrophoneChoiceValidation.isSelectable(uid: uid) else { return }
        settingsManager.chooseInputDevice(uid: uid)
      }
    )
    // #2664: the socket control sits on the SAME line as the device picker,
    // sized to its own text (founder, 2026-09-05: a full-width segmented bar
    // for two options read as a giant purple slab). Only for a device
    // reporting more than one input, and never for one whose UID could not
    // be read (nothing to key a choice on, and an empty key would be shared
    // by every such device). The DISPLAYED selection goes through the same
    // pure rule HAL applies, so a saved index the device no longer has shows
    // as Input 1. Stored 0-based; labelled from 1 like the sockets on the box.
    let multiInputDevice = socketDevice.flatMap { device in
      InputChannelSettings.offersChoice(uid: device.uid, inputChannelCount: device.inputChannelCount)
        ? device : nil
    }
    // #3385: each device's transport, read once per body through the one
    // vocabulary (`AudioDeviceEnumerator.transportLabel`) and reused by the
    // menu rows and the card, so the two can never disagree.
    let transportTokens = Dictionary(
      devices.compactMap { device in
        AudioDeviceEnumerator.transportLabel(for: device.id).map { (device.id, $0) }
      },
      uniquingKeysWith: { first, _ in first })
    let devicePresentation = MicrophoneDevicePresentation.make(
      preferredUID: settingsManager.preferredInputDeviceIDOverride,
      resolvedDevice: socketDevice,
      transportToken: socketDevice.flatMap { transportTokens[$0.id] })

    self.socketDevice = socketDevice
    self.multiInputDevice = multiInputDevice
    self.devices = devices
    self.transportTokens = transportTokens
    self.presentation = devicePresentation
    self.selection = inputDeviceSelection
  }
}

extension MicrophoneDevicePicker {
  /// The picker exactly as Settings shows it: every argument comes from one model,
  /// so a screen cannot pair one device list with another source's card.
  init(model: MicrophonePickerModel) {
    self.init(
      selection: model.selection,
      devices: model.devices,
      presentation: model.presentation,
      transportTokens: model.transportTokens)
  }
}
