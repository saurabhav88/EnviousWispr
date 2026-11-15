import CoreAudio
import EnviousWisprAudio
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprServices

/// #4528 D6a: Settings' Microphone tab and Setup's Practice screen both build their picker from
/// `MicrophonePickerModel`. When these fail, the user sees the picker name a different microphone
/// than the one they chose, offer an input socket on a one-input microphone, or save a microphone
/// that was unplugged. Driven with fixture devices whose IDs no Mac hands out and frozen
/// `MicrophoneFacts` (#4021: the model reads no hardware), so the answers are the same on every
/// Mac, including hosted runners with no microphone.
@MainActor
@Suite("Microphone picker model (#4528 D6a)", .tags(.productOutcome))
struct MicrophonePickerModelTests {
  static let builtIn = AudioInputDevice(
    id: 987_141, name: "MacBook Pro Microphone", uid: "fixture-d6a-builtin", inputChannelCount: 1)
  static let interface = AudioInputDevice(
    id: 987_701, name: "Scarlett 2i2", uid: "fixture-d6a-usb-2in", inputChannelCount: 2)

  static func facts(
    _ devices: [AudioInputDevice], auto: AudioDeviceID? = nil, tokens: [AudioDeviceID: String] = [:]
  ) -> MicrophoneFacts {
    MicrophoneFacts(devices: devices, resolvedAutoDeviceID: auto, transportTokens: tokens)
  }

  static func settings(preferred: String) -> SettingsManager {
    let name = "ew.tests.4528.d6a.\(UUID().uuidString)"
    let defaults = TestDefaults.suite(name)!
    defaults.removePersistentDomain(forName: name)
    let settings = SettingsManager(defaults: defaults)
    settings.chooseInputDevice(uid: preferred)
    return settings
  }

  @Test("a chosen microphone is the one the card names and the one whose inputs are offered")
  func chosenMicrophoneIsDescribed() {
    let devices = [Self.builtIn, Self.interface]
    let model = MicrophonePickerModel(
      settingsManager: Self.settings(preferred: Self.interface.uid), facts: Self.facts(devices))
    #expect(model.devices == devices)
    #expect(model.socketDevice == Self.interface)
    #expect(model.multiInputDevice == Self.interface)
    #expect(model.presentation.isAutomatic == false)
    #expect(model.presentation.deviceName == "Scarlett 2i2")
    #expect(model.presentation.deviceUID == Self.interface.uid)
    #expect(model.selection.wrappedValue == Self.interface.uid)
  }

  @Test("a one-input microphone offers no input socket")
  func oneInputMicrophoneOffersNoSocket() {
    let model = MicrophonePickerModel(
      settingsManager: Self.settings(preferred: Self.builtIn.uid),
      facts: Self.facts([Self.builtIn, Self.interface]))
    #expect(model.socketDevice == Self.builtIn)
    #expect(model.multiInputDevice == nil)
  }

  @Test("a saved microphone that is not connected is not named after another device")
  func missingMicrophoneBorrowsNoName() {
    let model = MicrophonePickerModel(
      settingsManager: Self.settings(preferred: "fixture-d6a-unplugged"), facts: Self.facts([Self.builtIn]))
    #expect(model.socketDevice == nil)
    #expect(model.multiInputDevice == nil)
    #expect(model.presentation.deviceName == nil)
    #expect(model.presentation.deviceUID == nil)
  }

  @Test("choosing Auto saves both preferences; a microphone unplugged since the menu opened saves nothing")
  func selectionWritesThroughTheGuard() {
    let settings = Self.settings(preferred: Self.interface.uid)
    let model = MicrophonePickerModel(
      settingsManager: settings, facts: Self.facts([Self.builtIn, Self.interface]))

    // A UID the system does not list right now (#3486): the fixture interface is never connected.
    model.selection.wrappedValue = "fixture-d6a-unplugged-\(UUID().uuidString)"
    #expect(settings.preferredInputDeviceIDOverride == Self.interface.uid)
    #expect(settings.selectedInputDeviceUID == Self.interface.uid)

    model.selection.wrappedValue = ""
    #expect(settings.preferredInputDeviceIDOverride == "")
    #expect(settings.selectedInputDeviceUID == "")
  }

  @Test("Auto names the device in the snapshot's Auto answer, with its transport badge, reading no hardware")
  func autoUsesFrozenFacts() {
    let model = MicrophonePickerModel(
      settingsManager: Self.settings(preferred: ""),
      facts: Self.facts(
        [Self.builtIn, Self.interface], auto: Self.interface.id,
        tokens: [Self.builtIn.id: "built_in", Self.interface.id: "usb"]))
    #expect(model.socketDevice == Self.interface)
    #expect(model.presentation.isAutomatic)
    #expect(model.presentation.deviceName == "Scarlett 2i2")
    #expect(model.presentation.transportBadge == MicrophoneDevicePresentation.transportBadge(for: "usb"))
    #expect(model.transportTokens == [Self.builtIn.id: "built_in", Self.interface.id: "usb"])
  }

  @Test("Before the first device snapshot a saved microphone stays saved and unresolved")
  func beforeFirstSnapshotKeepsTheSavedPin() {
    let settings = Self.settings(preferred: Self.interface.uid)
    let model = MicrophonePickerModel(settingsManager: settings, facts: .empty)
    #expect(model.devices.isEmpty)
    #expect(model.socketDevice == nil)
    #expect(model.presentation.isAutomatic == false)
    #expect(model.presentation.deviceName == nil)
    #expect(model.selection.wrappedValue == Self.interface.uid)
    #expect(settings.preferredInputDeviceIDOverride == Self.interface.uid)
  }
}
