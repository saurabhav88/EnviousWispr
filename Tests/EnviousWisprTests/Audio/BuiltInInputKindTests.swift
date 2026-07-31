import Foundation
import Testing

@testable import EnviousWisprAudio

// MARK: - BuiltInInputKindTests (#1845)
//
// `effectiveTransport` reports `built_in` for BOTH the internal microphone and
// a microphone plugged into the 3.5 mm jack, because macOS routes the jack
// through the same audio codec. Measured on the founder's Mac 2026-07-31:
//
//   MacBook Pro Microphone -> BuiltInMicrophoneDevice      -> bltn
//   External Microphone    -> BuiltInHeadphoneInputDevice  -> bltn
//
// Without a discriminator those two collapse into one bucket, and the jack case
// is the population #1845 exists to measure. These tests freeze the mapping and,
// just as importantly, freeze what must NEVER be emitted.

@Suite("AudioDeviceEnumerator.builtInInputKind (#1845)")
struct BuiltInInputKindTests {

  @Test("the two Apple built-in-family UIDs map to distinct kinds")
  func mapsTheBuiltInFamily() {
    #expect(
      AudioDeviceEnumerator.builtInInputKind(forUID: "BuiltInMicrophoneDevice") == "built_in_mic")
    #expect(
      AudioDeviceEnumerator.builtInInputKind(forUID: "BuiltInHeadphoneInputDevice") == "jack_input")
  }

  /// The whole point: these two must not be the same value. A refactor that
  /// collapsed them would silently restore the ambiguity this field removes,
  /// and every assertion above would still pass if both returned the same
  /// non-nil string.
  @Test("the internal microphone and the jack input are never the same kind")
  func internalAndJackAreDistinct() {
    let internalKind = AudioDeviceEnumerator.builtInInputKind(forUID: "BuiltInMicrophoneDevice")
    let jackKind = AudioDeviceEnumerator.builtInInputKind(forUID: "BuiltInHeadphoneInputDevice")

    #expect(internalKind != nil)
    #expect(jackKind != nil)
    #expect(internalKind != jackKind)
  }

  /// Non-built-in transports return nil on purpose. `usb` and `bluetooth` are
  /// already unambiguous in the transport label, so a value here would be a
  /// second authority for a fact that already has one.
  @Test(
    "non-built-in and unknown UIDs return nil",
    arguments: [
      "AppleUSBAudioEngine:Plantronics:Plantronics Blackwire 5220 Series:CBB85FCE:1",
      "BC-87-FA-9C-7E-71:input",
      "BlackHole2ch_UID",
      "MSLoopbackDriverDevice_UID",
      "SomeFutureAppleInput",
      "",
    ]
  )
  func returnsNilOutsideTheBuiltInFamily(uid: String) {
    #expect(AudioDeviceEnumerator.builtInInputKind(forUID: uid) == nil)
  }

  @Test("a nil UID returns nil rather than guessing")
  func nilUIDReturnsNil() {
    #expect(AudioDeviceEnumerator.builtInInputKind(forUID: nil) == nil)
  }

  /// PRIVACY FREEZE. The returned value must be one of exactly two closed
  /// constants and must never echo any part of the input UID.
  ///
  /// This matters because the real UIDs we refuse are genuinely sensitive: the
  /// USB form embeds the unit's SERIAL NUMBER and the Bluetooth form IS the peer
  /// MAC address. A future "just pass the UID through" refactor would ship
  /// hardware identifiers, and it would look harmless in review.
  @Test(
    "the output is a closed vocabulary and never echoes the UID",
    arguments: [
      "BuiltInMicrophoneDevice",
      "BuiltInHeadphoneInputDevice",
      "AppleUSBAudioEngine:Plantronics:Blackwire:CBB85FCE8061435CB8C2E9EC589C0931:1",
      "BC-87-FA-9C-7E-71:input",
    ]
  )
  func outputIsClosedVocabularyAndLeaksNothing(uid: String) {
    let allowed: Set<String> = ["built_in_mic", "jack_input"]

    guard let kind = AudioDeviceEnumerator.builtInInputKind(forUID: uid) else { return }

    #expect(allowed.contains(kind), "unexpected value '\(kind)' escaped the closed vocabulary")
    #expect(!kind.contains("CBB85FCE"), "a device serial reached the emitted value")
    #expect(!kind.contains("BC-87-FA"), "a MAC address reached the emitted value")
    #expect(kind != uid, "the raw UID was passed straight through")
  }
}
