import CoreAudio
import Foundation
import Testing

@testable import EnviousWisprAudio

// #1317 §3.0 — `resolveEffectiveInputDevice` feeds the harness-glitch
// discriminator. It mirrors HAL's own resolution (#1533): explicit override
// wins when set, otherwise the system default; `selectedInputDeviceUID` is
// never consulted (HAL never opens it). Codex code-diff review (round 2): an
// explicit override that fails to resolve (the device vanished — a
// hardware-removal case, out of #1317's scope) must fail CLOSED, not silently
// substitute the system-default device's alive/mute state for a different mic.
@Suite("AudioDeviceEnumerator.resolveEffectiveInputDevice (#1317)")
struct AudioDeviceEnumeratorResolveTests {

  private let nonexistentUID = "com.enviouswispr.test.nonexistent-device-uid"

  @Test("no explicit override falls through to the system default")
  func noExplicitOverrideUsesDefault() {
    // #1529 — inject a fixed fake default device instead of two independent
    // live CoreAudio reads (one inside the resolver, one in the assertion),
    // which could disagree if the live default device changed between calls.
    let fakeDefaultDeviceID = AudioDeviceID(42)
    let resolved = AudioDeviceEnumerator.resolveEffectiveInputDevice(
      preferredOverride: "",
      defaultInputDeviceIDProvider: { fakeDefaultDeviceID })
    #expect(resolved == fakeDefaultDeviceID)
  }

  @Test(
    "an explicit preferred override that does not resolve fails closed (nil), never the default")
  func vanishedPreferredOverrideFailsClosed() {
    let resolved = AudioDeviceEnumerator.resolveEffectiveInputDevice(
      preferredOverride: nonexistentUID,
      defaultInputDeviceIDProvider: { AudioDeviceID(42) })
    #expect(resolved == nil)
  }

  @Test(
    "on Auto the remembered selection is ignored — the default is used, not a stale UID (#1533)")
  func autoIgnoresRememberedSelection() {
    // Pre-cutover this branch consulted selectedInputDeviceUID; HAL now follows
    // the system default on Auto and never opens the remembered device, so the
    // discriminator must resolve the default regardless of any remembered UID.
    // With no override, the resolver returns the default even though a stale
    // selection would not have resolved to a live device.
    let fakeDefaultDeviceID = AudioDeviceID(42)
    let resolved = AudioDeviceEnumerator.resolveEffectiveInputDevice(
      preferredOverride: "",
      defaultInputDeviceIDProvider: { fakeDefaultDeviceID })
    #expect(resolved == fakeDefaultDeviceID)
  }
}
