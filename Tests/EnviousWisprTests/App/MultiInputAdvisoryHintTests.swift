import CoreAudio
import EnviousWisprAudio
import EnviousWisprCore
import Testing

@testable import EnviousWisprAppKit

// #2664: the silent-take notice names the multi-input box the user would find
// selected in Settings, and ONLY that box. When this fails, the user sees the
// wrong device named, or the "try a different input" hint on a one-input
// microphone that has no other input to try.
@Suite("MultiInputAdvisoryHint and the shared socket-device rule — #2664", .tags(.productOutcome))
struct MultiInputAdvisoryHintTests {

  private static let scarlett = AudioInputDevice(
    id: 42, name: "Scarlett 2i2 USB", uid: "scarlett-2i2-uid", inputChannelCount: 2)
  private static let builtIn = AudioInputDevice(
    id: 7, name: "MacBook Pro Microphone", uid: "builtin-uid", inputChannelCount: 1)

  // MARK: - The hint

  @Test("a two-input device on a silent take names the device")
  func multiInputDeviceProducesHint() {
    let hint = MultiInputAdvisoryHint.make(reason: .zeroSignal, socketDevice: Self.scarlett)
    #expect(hint == MultiInputAdvisoryHint(deviceName: "Scarlett 2i2 USB"))
    #expect(
      MultiInputAdvisoryHint.make(reason: .vadGateNoSpeech, socketDevice: Self.scarlett)
        == MultiInputAdvisoryHint(deviceName: "Scarlett 2i2 USB"))
  }

  @Test("a one-input device never gets the hint: there is no other input to try")
  func oneInputDeviceHasNoHint() {
    #expect(MultiInputAdvisoryHint.make(reason: .zeroSignal, socketDevice: Self.builtIn) == nil)
  }

  @Test("no known device (empty list, nothing resolved) means the locked sentence")
  func noDeviceHasNoHint() {
    #expect(MultiInputAdvisoryHint.make(reason: .zeroSignal, socketDevice: nil) == nil)
  }

  @Test("noTransport never hints: no device was opened, so there is no socket to try")
  func noTransportHasNoHint() {
    #expect(MultiInputAdvisoryHint.make(reason: .noTransport, socketDevice: Self.scarlett) == nil)
  }

  // MARK: - The shared device rule (settings row and hint read the same one)

  @Test("a pinned device is found by UID, whatever Auto would resolve")
  func pinnedDeviceWinsByUID() {
    var resolverCalls = 0
    let device = InputSocket.socketDevice(
      preferredInputDeviceIDOverride: "scarlett-2i2-uid",
      devices: [Self.builtIn, Self.scarlett],
      resolvedAutoInputDeviceID: {
        resolverCalls += 1
        return 7
      })
    #expect(device == Self.scarlett)
    #expect(resolverCalls == 0, "a pinned choice must not pay for the Auto ladder")
  }

  @Test("a pinned device that is not connected yields nothing, never a substitute")
  func pinnedDeviceMissingYieldsNil() {
    let device = InputSocket.socketDevice(
      preferredInputDeviceIDOverride: "unplugged-uid",
      devices: [Self.builtIn, Self.scarlett],
      resolvedAutoInputDeviceID: { 7 })
    #expect(device == nil)
  }

  @Test("Auto names the device the ladder would OPEN, matched by runtime id")
  func autoResolvesByID() {
    let device = InputSocket.socketDevice(
      preferredInputDeviceIDOverride: "",
      devices: [Self.builtIn, Self.scarlett],
      resolvedAutoInputDeviceID: { 42 })
    #expect(device == Self.scarlett)
  }

  @Test("Auto with nothing resolved, or an empty device list, yields nothing")
  func autoUnresolvedYieldsNil() {
    #expect(
      InputSocket.socketDevice(
        preferredInputDeviceIDOverride: "", devices: [Self.builtIn, Self.scarlett],
        resolvedAutoInputDeviceID: { nil }) == nil)
    #expect(
      InputSocket.socketDevice(
        preferredInputDeviceIDOverride: "", devices: [], resolvedAutoInputDeviceID: { 42 })
        == nil)
    #expect(
      InputSocket.socketDevice(
        preferredInputDeviceIDOverride: "scarlett-2i2-uid", devices: [],
        resolvedAutoInputDeviceID: { 42 }) == nil)
  }

  @Test("Auto flipping between a one-input and a two-input device hints only on the second")
  func autoFlipHintsOnlyForMultiInput() {
    let onBuiltIn = InputSocket.socketDevice(
      preferredInputDeviceIDOverride: "", devices: [Self.builtIn, Self.scarlett],
      resolvedAutoInputDeviceID: { 7 })
    let onScarlett = InputSocket.socketDevice(
      preferredInputDeviceIDOverride: "", devices: [Self.builtIn, Self.scarlett],
      resolvedAutoInputDeviceID: { 42 })
    #expect(MultiInputAdvisoryHint.make(reason: .zeroSignal, socketDevice: onBuiltIn) == nil)
    #expect(
      MultiInputAdvisoryHint.make(reason: .zeroSignal, socketDevice: onScarlett)?.deviceName
        == "Scarlett 2i2 USB")
  }
}
