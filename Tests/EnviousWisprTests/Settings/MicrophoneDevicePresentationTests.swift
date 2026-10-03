import EnviousWisprAudio
import Testing

@testable import EnviousWisprAppKit

/// #3385: what the Microphone tab says about the microphone. **When this fails, the
/// tab names a microphone the app would not open, or calls a device "USB" or "Built-in" when
/// it is not.** Fake devices and transport tokens only; no hardware is read.
@Suite("Microphone device presentation (#3385)", .tags(.productOutcome))
struct MicrophoneDevicePresentationTests {
  static let builtIn = AudioInputDevice(
    id: 41, name: "MacBook Pro Microphone", uid: "BuiltInMicrophoneDevice", inputChannelCount: 1)
  static let usb = AudioInputDevice(
    id: 77, name: "Scarlett 2i2", uid: "AppleUSBAudioEngine:Focusrite:Scarlett", inputChannelCount: 2)

  @Test("Auto names the device the resolver chose, with its transport")
  func autoNamesResolvedDevice() {
    let p = MicrophoneDevicePresentation.make(
      preferredUID: "", resolvedDevice: Self.builtIn, transportToken: "built_in")
    #expect(p.isAutomatic == true)
    #expect(p.deviceName == "MacBook Pro Microphone")
    #expect(p.deviceUID == "BuiltInMicrophoneDevice")
    #expect(p.deviceIcon == "mic")
    #expect(p.transportBadge == "Built-in")
  }

  @Test("an explicit choice stays explicit and names its own device")
  func explicitSelectionStaysExplicit() {
    let p = MicrophoneDevicePresentation.make(
      preferredUID: Self.usb.uid, resolvedDevice: Self.usb, transportToken: "usb")
    #expect(p.isAutomatic == false)
    #expect(p.deviceName == "Scarlett 2i2")
    #expect(p.deviceUID == "AppleUSBAudioEngine:Focusrite:Scarlett")
    #expect(p.deviceIcon == "cable.connector")
    #expect(p.transportBadge == "USB")
  }

  @Test("selectable titles retain the name and known transport grammar")
  @MainActor
  func optionTitlesAreUnchanged() {
    #expect(MicrophoneDevicePicker.optionTitle(for: Self.usb, transportToken: "usb") == "Scarlett 2i2 · USB")
    #expect(MicrophoneDevicePicker.optionTitle(for: Self.builtIn, transportToken: "built_in") == "MacBook Pro Microphone · Built-in")
    #expect(MicrophoneDevicePicker.optionTitle(for: Self.usb, transportToken: "unknown") == "Scarlett 2i2")
  }

  @Test("the three named transports map to their badges")
  func supportedBadges() {
    #expect(MicrophoneDevicePresentation.transportBadge(for: "built_in") == "Built-in")
    #expect(MicrophoneDevicePresentation.transportBadge(for: "usb") == "USB")
    #expect(MicrophoneDevicePresentation.transportBadge(for: "bluetooth") == "Bluetooth")
  }

  @Test(
    "an unreadable, unknown or unnamed transport shows no badge",
    arguments: [nil, "unknown", "aggregate", "virtual", "continuity_capture_wireless", "thunderbolt"]
      as [String?])
  func unsupportedTokensShowNoBadge(_ token: String?) {
    #expect(MicrophoneDevicePresentation.transportBadge(for: token) == nil)
    let p = MicrophoneDevicePresentation.make(
      preferredUID: "", resolvedDevice: Self.builtIn, transportToken: token)
    #expect(p.transportBadge == nil)
    #expect(p.deviceIcon == "mic")
    #expect(p.deviceName == "MacBook Pro Microphone", "the name does not depend on the badge")
  }

  @Test("Bluetooth denotes a connection, never a guessed headphone or device model")
  func bluetoothIconIsTransportOnly() {
    #expect(MicrophoneDevicePresentation.deviceIcon(for: "bluetooth") == "dot.radiowaves.left.and.right")
  }

  @Test("an unresolved saved microphone borrows no other device's name or badge")
  func mismatchedDeviceNamesNothing() {
    let p = MicrophoneDevicePresentation.make(
      preferredUID: "Some:Unplugged:UID", resolvedDevice: Self.builtIn, transportToken: "built_in")
    #expect(p.isAutomatic == false, "the saved preference is kept")
    #expect(p.deviceName == nil)
    #expect(p.deviceUID == nil)
    #expect(p.deviceIcon == "mic")
    #expect(p.transportBadge == nil)
  }

  @Test("no device resolved names nothing, for Auto and for a saved choice")
  func missingDeviceNamesNothing() {
    for preferred in ["", Self.usb.uid] {
      let p = MicrophoneDevicePresentation.make(
        preferredUID: preferred, resolvedDevice: nil, transportToken: "usb")
      #expect(p.deviceName == nil)
    #expect(p.deviceUID == nil)
    #expect(p.deviceIcon == "mic")
      #expect(p.transportBadge == nil)
      #expect(p.isAutomatic == preferred.isEmpty)
    }
  }
}
