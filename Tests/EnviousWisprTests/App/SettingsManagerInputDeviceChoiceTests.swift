import AppKit
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprAudio
@testable import EnviousWisprServices

/// #3454: Settings and the menu bar's Microphone submenu both save the user's choice through
/// `SettingsManager.chooseInputDevice(uid:)`. When these fail, the user sees the menu and Settings
/// disagree, or Auto snap back to a microphone they turned away from.
@MainActor
@Suite("Choosing a microphone — #3454", .tags(.productOutcome))
struct SettingsManagerInputDeviceChoiceTests {
  init() { _ = NSApplication.shared }

  private static func freshSuite() -> (UserDefaults, String) {
    let name = "ew.inputDeviceChoiceTest." + UUID().uuidString
    let defaults = TestDefaults.suite(name)!
    defaults.removePersistentDomain(forName: name)
    return (defaults, name)
  }

  private static func device(_ uid: String) -> AudioInputDevice {
    AudioInputDevice(id: 1, name: uid, uid: uid, inputChannelCount: 1)
  }

  @Test("choosing a device saves both keys, override first, as a user write")
  func choosingADeviceSavesBothKeys() {
    let (defaults, _) = Self.freshSuite()
    let settings = SettingsManager(defaults: defaults)

    var changes: [(SettingsManager.SettingKey, Bool)] = []
    settings.onChange = { changes.append(($0, settings.isApplyingSystemWrite)) }

    settings.chooseInputDevice(uid: "usb-mic")

    #expect(settings.preferredInputDeviceIDOverride == "usb-mic")
    #expect(settings.selectedInputDeviceUID == "usb-mic")
    #expect(changes.map(\.0) == [.preferredInputDeviceIDOverride, .selectedInputDeviceUID])
    #expect(changes.map(\.1) == [false, false])
    // Persisted: a fresh manager on the same store reads the choice back.
    let reloaded = SettingsManager(defaults: defaults)
    #expect(reloaded.preferredInputDeviceIDOverride == "usb-mic")
    #expect(reloaded.selectedInputDeviceUID == "usb-mic")
  }

  @Test("choosing Auto after a connected device clears both keys and stays Auto")
  func choosingAutoClearsBothKeys() {
    let (defaults, _) = Self.freshSuite()
    let settings = SettingsManager(defaults: defaults)
    settings.chooseInputDevice(uid: "usb-mic")

    settings.chooseInputDevice(uid: "")

    #expect(settings.preferredInputDeviceIDOverride == "")
    #expect(settings.selectedInputDeviceUID == "")
    // The device is still plugged in: reconciliation must not pin it again.
    InputDevicePreferenceReconciler(settings: settings)
      .reconcile(availableDevices: [Self.device("usb-mic")])
    #expect(settings.preferredInputDeviceIDOverride == "")
    #expect(settings.selectedInputDeviceUID == "")
    let reloaded = SettingsManager(defaults: defaults)
    #expect(reloaded.preferredInputDeviceIDOverride == "")
    #expect(reloaded.selectedInputDeviceUID == "")
  }

  @Test("choose A, unplug A, choose Auto, replug A: A does not come back")
  func autoChosenWhileUnpluggedSurvivesReplug() {
    let (defaults, _) = Self.freshSuite()
    let settings = SettingsManager(defaults: defaults)
    let reconciler = InputDevicePreferenceReconciler(settings: settings)
    let builtIn = Self.device("built-in")
    let usb = Self.device("usb-mic")

    settings.chooseInputDevice(uid: "usb-mic")
    reconciler.reconcile(availableDevices: [builtIn, usb])
    #expect(settings.preferredInputDeviceIDOverride == "usb-mic")

    // Unplug: the existing behavior falls back to Auto and remembers the device.
    reconciler.reconcile(availableDevices: [builtIn])
    #expect(settings.preferredInputDeviceIDOverride == "")
    #expect(settings.selectedInputDeviceUID == "usb-mic")

    // The user then chooses Auto on purpose, which forgets the remembered device.
    settings.chooseInputDevice(uid: "")

    reconciler.reconcile(availableDevices: [builtIn, usb])
    #expect(settings.preferredInputDeviceIDOverride == "")
    #expect(settings.selectedInputDeviceUID == "")
  }

  @Test("control: without choosing Auto, a replugged remembered device comes back")
  func rememberedDeviceComesBackWithoutAutoChoice() {
    let (defaults, _) = Self.freshSuite()
    let settings = SettingsManager(defaults: defaults)
    let reconciler = InputDevicePreferenceReconciler(settings: settings)
    let builtIn = Self.device("built-in")
    let usb = Self.device("usb-mic")

    settings.chooseInputDevice(uid: "usb-mic")
    reconciler.reconcile(availableDevices: [builtIn])
    reconciler.reconcile(availableDevices: [builtIn, usb])

    #expect(settings.preferredInputDeviceIDOverride == "usb-mic")
    #expect(settings.selectedInputDeviceUID == "usb-mic")
  }
}
