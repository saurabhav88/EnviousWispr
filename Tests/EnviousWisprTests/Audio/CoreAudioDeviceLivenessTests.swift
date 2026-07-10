import CoreAudio
import Foundation
import Testing

@testable import EnviousWisprAudio

// #1408 — the liveness read that decides whether the app may tell a user their
// microphone disconnected.
//
// Both capture sources used to inline this read, DISCARD the returned `OSStatus`,
// and branch on the `isAlive` out-parameter alone. `isAlive` is zero-initialized,
// so every failed read looked exactly like "the device is dead." Once #1408 made
// that answer drive a pill and a permanent History badge, an unchecked status
// meant a transient Core Audio error could permanently mislabel a recording whose
// microphone never left (Codex code-diff review r3).
//
// The naive repair — "any non-noErr status means we could not verify removal" —
// is WRONG in the other direction, and this suite exists mainly to stop someone
// from applying it. A removed device's `AudioDeviceID` is invalidated, so the
// query for a genuinely unplugged microphone does not return `noErr` + `isAlive
// == 0`; it returns `kAudioHardwareBadObjectError`. Collapsing that to
// "unverified" would suppress the disconnect notice on exactly the case the whole
// issue exists for.
@Suite("Core Audio device-liveness classification (#1408)")
struct CoreAudioDeviceLivenessTests {

  // MARK: - The three answers

  @Test("noErr + isAlive == 1 → alive (a Bluetooth codec switch, not a disconnect)")
  func aliveWhenCoreAudioSaysYes() {
    #expect(CoreAudioDeviceLiveness.interpret(status: noErr, isAlive: 1) == .alive)
  }

  @Test("noErr + isAlive == 0 → removed (the device reported itself dead)")
  func removedWhenCoreAudioSaysNo() {
    #expect(CoreAudioDeviceLiveness.interpret(status: noErr, isAlive: 0) == .removed)
  }

  /// The dominant real-world disconnect path: the device object is gone, so the
  /// ID no longer names anything. If this ever returns `.unverified`, unplugging
  /// a USB mic mid-sentence stops showing the disconnect notice.
  @Test(
    "a status naming a missing object/device → removed",
    arguments: [kAudioHardwareBadObjectError, kAudioHardwareBadDeviceError])
  func removedWhenTheObjectIsGone(status: OSStatus) {
    #expect(CoreAudioDeviceLiveness.interpret(status: status, isAlive: 0) == .removed)
  }

  /// Codex r3's finding, locked. These statuses say nothing about whether the
  /// device is present, and `isAlive` is still its zero initializer underneath
  /// them — the exact shape that used to read as "dead."
  @Test(
    "any other failure → unverified, never a disconnect claim",
    arguments: [
      kAudioHardwareBadPropertySizeError,
      kAudioHardwareUnknownPropertyError,
      kAudioHardwareNotRunningError,
      kAudioHardwareUnspecifiedError,
      kAudioHardwareIllegalOperationError,
      OSStatus(-1),
    ])
  func unverifiedOnATransientFailure(status: OSStatus) {
    #expect(CoreAudioDeviceLiveness.interpret(status: status, isAlive: 0) == .unverified)
  }

  /// A failed read must not be rescued by a stale non-zero out-parameter either.
  /// The status is the authority; `isAlive` is only meaningful under `noErr`.
  @Test("a failed read ignores isAlive entirely")
  func failedReadDoesNotConsultIsAlive() {
    #expect(
      CoreAudioDeviceLiveness.interpret(status: kAudioHardwareNotRunningError, isAlive: 1)
        == .unverified)
    #expect(
      CoreAudioDeviceLiveness.interpret(status: kAudioHardwareBadObjectError, isAlive: 1)
        == .removed)
  }

  // MARK: - The claim boundary

  /// The whole point of the `.unverified` case: only a confirmed removal may
  /// reach `isDeviceLoss`, which is what gates the pill and the badge. An
  /// unverified read still interrupts and still salvages — it just stays silent.
  @Test("only a confirmed removal earns a user-facing disconnect claim")
  func onlyRemovedEarnsTheClaim() {
    let causeFor: (DeviceLiveness) -> EngineInterruptionCause = {
      $0 == .removed ? .deviceRemoved : .engineLost
    }
    #expect(causeFor(.removed).isDeviceLoss)
    #expect(!causeFor(.unverified).isDeviceLoss)

    // ...and neither answer costs the user their dictation.
    #expect(causeFor(.removed).hasRecoverableAudio)
    #expect(causeFor(.unverified).hasRecoverableAudio)
  }

  // MARK: - Against the real system

  /// Guards the premise the pure cases are built on, using the machine's own
  /// default input device rather than a hand-written status. If Core Audio ever
  /// stopped answering `kAudioHardwareBadObjectError` for an ID that names
  /// nothing, `.removed` would be reached through a status this suite never
  /// enumerates.
  @Test("a nonexistent device ID classifies as removed on the real Core Audio")
  func nonexistentDeviceIsRemovedAgainstRealCoreAudio() {
    #expect(CoreAudioDeviceLiveness.classify(deviceID: AudioDeviceID(999_999)) == .removed)
    #expect(
      CoreAudioDeviceLiveness.classify(deviceID: AudioDeviceID(kAudioObjectUnknown)) == .removed)
  }
}
