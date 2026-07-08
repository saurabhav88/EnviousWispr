import AppKit
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprAudio
@testable import EnviousWisprServices

@MainActor
@Suite("Input device preference reconciliation — #1378")
struct InputDevicePreferenceReconcilerTests {
  init() { _ = NSApplication.shared }

  private static func freshSuite() -> UserDefaults {
    let name = "ew.inputDevicePreferenceTest." + UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  private static func device(_ uid: String) -> AudioInputDevice {
    AudioInputDevice(id: 1, name: uid, uid: uid)
  }

  @Test(
    "policy covers full preferred x selected grid",
    arguments: [
      ("", "", ["connected"], "", ""),
      ("", "connected", ["connected"], "connected", "connected"),
      ("", "missing", ["connected"], "", "missing"),
      ("connected", "", ["connected"], "connected", "connected"),
      ("connected", "connected", ["connected"], "connected", "connected"),
      ("connected", "missing", ["connected"], "connected", "connected"),
      ("missing", "", ["connected"], "", "missing"),
      ("missing", "connected", ["connected"], "", "missing"),
      ("missing", "missing", ["connected"], "", "missing"),
    ])
  func policyGrid(
    preferred: String,
    selected: String,
    connected: [String],
    expectedPreferred: String,
    expectedSelected: String
  ) {
    let result = InputDevicePreferencePolicy.reconciled(
      preferredOverride: preferred,
      selectedUID: selected,
      connectedUIDs: Set(connected)
    )

    #expect(result.preferredOverride == expectedPreferred)
    #expect(result.selectedUID == expectedSelected)
  }

  @Test("reconciler writes only when values change")
  func reconcilerWritesOnlyWhenValuesChange() {
    let settings = SettingsManager(defaults: Self.freshSuite())
    settings.preferredInputDeviceIDOverride = "usb"
    settings.selectedInputDeviceUID = "usb"

    var changes: [SettingsManager.SettingKey] = []
    settings.onChange = { changes.append($0) }

    let reconciler = InputDevicePreferenceReconciler(settings: settings)
    reconciler.reconcile(availableDevices: [Self.device("usb")])

    #expect(changes.isEmpty)
  }

  @Test("launch reconcile closes the gap before the next hardware notification")
  func explicitLaunchReconcileClosesInitialGap() {
    let settings = SettingsManager(defaults: Self.freshSuite())
    settings.preferredInputDeviceIDOverride = "usb"
    settings.selectedInputDeviceUID = ""
    let audioDeviceList = AudioDeviceList()
    audioDeviceList.availableInputDevices = [Self.device("usb")]

    let reconciler = InputDevicePreferenceReconciler(settings: settings)
    audioDeviceList.onDevicesChanged = { devices in
      reconciler.reconcile(availableDevices: devices)
    }
    reconciler.reconcile(availableDevices: audioDeviceList.availableInputDevices)

    #expect(settings.preferredInputDeviceIDOverride == "usb")
    #expect(settings.selectedInputDeviceUID == "usb")
  }

  @Test("automatic reconciliation marks changed writes as system writes")
  func changedWritesAreSystemWrites() {
    let settings = SettingsManager(defaults: Self.freshSuite())
    settings.preferredInputDeviceIDOverride = "usb"
    settings.selectedInputDeviceUID = ""

    var sources: [Bool] = []
    settings.onChange = { _ in sources.append(settings.isApplyingSystemWrite) }

    let reconciler = InputDevicePreferenceReconciler(settings: settings)
    reconciler.reconcile(availableDevices: [Self.device("usb")])

    #expect(sources == [true])
    #expect(settings.isApplyingSystemWrite == false)
  }

  @Test("disconnected explicit pick returns to Auto but remains remembered")
  func disconnectedExplicitPickReturnsToAutoButStaysRemembered() {
    let settings = SettingsManager(defaults: Self.freshSuite())
    settings.preferredInputDeviceIDOverride = "gone"
    settings.selectedInputDeviceUID = "old"

    let reconciler = InputDevicePreferenceReconciler(settings: settings)
    reconciler.reconcile(availableDevices: [])

    #expect(settings.preferredInputDeviceIDOverride == "")
    #expect(settings.selectedInputDeviceUID == "gone")
  }

  @Test("system fallback to Auto does not clear the remembered device")
  func systemFallbackDoesNotClearRememberedDevice() {
    let settings = SettingsManager(defaults: Self.freshSuite())
    settings.preferredInputDeviceIDOverride = "usb"
    settings.selectedInputDeviceUID = "usb"

    let reconciler = InputDevicePreferenceReconciler(settings: settings)
    reconciler.reconcile(availableDevices: [])

    #expect(settings.preferredInputDeviceIDOverride == "")
    #expect(settings.selectedInputDeviceUID == "usb")
  }
}
