import CoreAudio
import Foundation
import Testing

@testable import EnviousWisprAudio

// #1317 §3.0 — `resolveEffectiveInputDevice` feeds the harness-glitch
// discriminator. Codex code-diff review (round 2): an explicit UID that
// fails to resolve (the selected/bound device vanished — a hardware-removal
// case, out of #1317's scope) must fail CLOSED, not silently substitute the
// system-default device's alive/mute state for a different microphone.
@Suite("AudioDeviceEnumerator.resolveEffectiveInputDevice (#1317)")
struct AudioDeviceEnumeratorResolveTests {

  private let nonexistentUID = "com.enviouswispr.test.nonexistent-device-uid"

  @Test("no explicit selection (both empty) falls through to the system default")
  func noExplicitSelectionUsesDefault() {
    // #1529 — inject a fixed fake default device instead of two independent
    // live CoreAudio reads (one inside the resolver, one in the assertion),
    // which could disagree if the live default device changed between calls.
    let fakeDefaultDeviceID = AudioDeviceID(42)
    let resolved = AudioDeviceEnumerator.resolveEffectiveInputDevice(
      preferredOverride: "", selected: "",
      defaultInputDeviceIDProvider: { fakeDefaultDeviceID })
    #expect(resolved == fakeDefaultDeviceID)
  }

  @Test(
    "an explicit preferred override that does not resolve fails closed (nil), never the default")
  func vanishedPreferredOverrideFailsClosed() {
    let resolved = AudioDeviceEnumerator.resolveEffectiveInputDevice(
      preferredOverride: nonexistentUID, selected: "")
    #expect(resolved == nil)
  }

  @Test("an explicit selected UID that does not resolve fails closed (nil), never the default")
  func vanishedSelectedUIDFailsClosed() {
    let resolved = AudioDeviceEnumerator.resolveEffectiveInputDevice(
      preferredOverride: "", selected: nonexistentUID)
    #expect(resolved == nil)
  }
}
