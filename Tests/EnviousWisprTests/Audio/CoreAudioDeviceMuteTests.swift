import CoreAudio
import Foundation
import Testing

@testable import EnviousWisprAudio

// #1317 §3.0 — the mute read that discriminates a genuinely muted mic (a
// running, alive device legitimately zero-filling by design) from the
// mic-HARNESS glitch (a running, alive, UNMUTED device zero-filling because
// the capture pipe broke). #1317 adds no hardware-mute UX; the whole point of
// `.unverified` here is fail-closed — ambiguity must never be read as
// "unmuted, safe to run harness recovery."
@Suite("Core Audio device-mute classification (#1317)")
struct CoreAudioDeviceMuteTests {

  // MARK: - The three answers

  @Test("noErr + isMuted == 1 → muted")
  func mutedWhenCoreAudioSaysYes() {
    #expect(CoreAudioDeviceMute.interpret(status: noErr, isMuted: 1) == .muted)
  }

  @Test("noErr + isMuted == 0 → unmuted")
  func unmutedWhenCoreAudioSaysNo() {
    #expect(CoreAudioDeviceMute.interpret(status: noErr, isMuted: 0) == .unmuted)
  }

  /// On a non-`noErr` status the out-parameter's contents are not trustworthy, so
  /// there is nothing to read and this must fail closed — never "confirmed
  /// unmuted."
  ///
  /// Not because devices lack a mute control: measured across built-in / USB
  /// webcam / two virtual drivers, all four implement `kAudioDevicePropertyMute`
  /// on the INPUT scope and all four are settable (#1809, #1578). The earlier
  /// wording here claimed the opposite and was false on our own hardware.
  /// (Property-absence IS a separate real path to `.unverified`, but it short-
  /// circuits in `classify` before `interpret` is ever called, so it is out of
  /// scope for this parameterised case.)
  @Test(
    "any non-noErr status → unverified, never an unmuted claim",
    arguments: [
      kAudioHardwareBadObjectError,
      kAudioHardwareBadPropertySizeError,
      kAudioHardwareUnknownPropertyError,
      kAudioHardwareNotRunningError,
      kAudioHardwareUnspecifiedError,
      OSStatus(-1),
    ])
  func unverifiedOnAnyFailure(status: OSStatus) {
    #expect(CoreAudioDeviceMute.interpret(status: status, isMuted: 0) == .unverified)
  }

  /// A failed read must not be rescued by a stale non-zero out-parameter —
  /// the status is the authority, `isMuted` only meaningful under `noErr`.
  @Test("a failed read ignores isMuted entirely")
  func failedReadDoesNotConsultIsMuted() {
    #expect(
      CoreAudioDeviceMute.interpret(status: kAudioHardwareNotRunningError, isMuted: 0)
        == .unverified)
  }

  // MARK: - Against the real system

  /// Guards the premise the pure cases are built on: a nonexistent device ID
  /// has no property to read, so the classifier must fail closed rather than
  /// crash or default to "unmuted."
  @Test("a nonexistent device ID classifies as unverified on the real Core Audio")
  func nonexistentDeviceIsUnverifiedAgainstRealCoreAudio() {
    #expect(CoreAudioDeviceMute.classify(deviceID: AudioDeviceID(999_999)) == .unverified)
  }
}
