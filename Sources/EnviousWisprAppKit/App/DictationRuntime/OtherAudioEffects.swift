import CoreAudio
import Foundation

// #1413 — the seams `OtherAudioHold` drives. The LIVE implementations (CoreAudio
// output writes, Apple events to Music/Spotify) live in `EnviousWisprDesktopEffects`
// and are chosen in `LiveApplication`; this module and the unit-test target only
// ever see these protocols, for the same reason `DesktopHotkeyEffects` exists:
// a suite must never lower the developer's speakers or pause their Spotify.

/// The original values of the default output device, captured before any write.
/// `nil` means the device exposes no such (settable) property, which is a fact
/// about the device, not a read failure.
package struct OutputVolumeSnapshot: Codable, Equatable, Sendable {
  package var deviceUID: String
  package var volume: Float?
  package var muted: Bool?
  package init(deviceUID: String, volume: Float? = nil, muted: Bool? = nil) {
    self.deviceUID = deviceUID
    self.volume = volume
    self.muted = muted
  }
}

/// A CoreAudio property read is three-valued. `unsupported` (the device has no
/// settable property of that kind) and `unreadable` (the read itself failed) are
/// different facts and must never collapse into one another or into a fabricated
/// zero or `false`.
package enum OutputPropertyRead<Value: Equatable & Sendable>: Equatable, Sendable {
  case value(Value)
  case unsupported
  case unreadable
}

/// A device's identity for the record and for telemetry shape. `transportTypeRaw`
/// is the CoreAudio transport constant; the hold maps it through the existing
/// `AudioDeviceEnumerator.transportLabel(forTransportType:)` vocabulary, so this
/// module owns no second label table.
package struct OutputDeviceIdentity: Equatable, Sendable {
  package var id: AudioDeviceID
  package var uid: String
  package var transportTypeRaw: UInt32?
  package init(id: AudioDeviceID, uid: String, transportTypeRaw: UInt32?) {
    self.id = id
    self.uid = uid
    self.transportTypeRaw = transportTypeRaw
  }
}

/// Reads and writes of the OUTPUT scope of an output device. Writes are desktop
/// effects; the live conformer is `LiveOutputVolumeEffects` in DesktopEffects.
@MainActor
package protocol OutputVolumeControlling: AnyObject {
  /// UID and transport of a device id (the hold reads the DEFAULT output id
  /// through `AudioDeviceEnumerator`, the existing authority).
  func identity(of device: AudioDeviceID) -> OutputDeviceIdentity?
  /// Resolves a device by UID across ALL devices, including output-only ones.
  /// (`AudioDeviceEnumerator.deviceID(forUID:)` enumerates inputs only and is
  /// not this function.)
  func device(forUID uid: String) -> AudioDeviceID?
  func readVolume(of device: AudioDeviceID) -> OutputPropertyRead<Float>
  func readMute(of device: AudioDeviceID) -> OutputPropertyRead<Bool>
  /// Returns false when the write was refused or reported an error.
  func setVolume(_ volume: Float, of device: AudioDeviceID) -> Bool
  func setMute(_ muted: Bool, of device: AudioDeviceID) -> Bool
}

/// Result of one media operation, reported back to the hold off the effect's own
/// queue. `pausedTargets` are bundle identifiers of players that accepted `pause`.
package enum MediaPauseOutcome: Equatable, Sendable {
  case paused(targets: [String])
  case nothingPlaying
  case consentNeeded
  case consentDenied
  case failed
}

package enum MediaResumeOutcome: Equatable, Sendable {
  case resumed
  case nothingToResume
  case failed
}

/// Pause/resume of the scriptable players. Every operation is keyed by the hold
/// that owns it so a late completion can never be attributed to another take.
/// The live conformer is `LiveMediaPlaybackEffects` in DesktopEffects; it owns
/// the serial Apple-events queue, the consent policy and the `ended` set.
@MainActor
package protocol MediaPlaybackControlling: AnyObject {
  /// Enqueue a pause for `holdID`. `completion` is called on the main actor
  /// exactly once, possibly after the hold has already ended.
  func pause(holdID: UUID, completion: @escaping @MainActor (MediaPauseOutcome) -> Void)
  /// Marks `holdID` ended (a queued pause that has not started issues no events)
  /// and enqueues the resume of whatever that hold's pause recorded.
  func resume(holdID: UUID, completion: @escaping @MainActor (MediaResumeOutcome) -> Void)
  /// Resume from a persisted record of a dead process: only these targets, and
  /// only if each is still running and still paused.
  func resumeOrphan(
    holdID: UUID, targets: [String],
    completion: @escaping @MainActor (MediaResumeOutcome) -> Void)
  /// Raise the Automation consent prompt for running targets, off the main
  /// actor. Called from the Settings picker when `Pause music` is chosen.
  func preflightConsent()
}

/// The pair `WisprBootstrapper.init` requires, non-defaulted, like
/// `makeHotkeyEffects` (#2455 C1): a default would let this test-linked module
/// assemble a root that reaches the real desktop.
package struct OtherAudioEffects {
  let volume: any OutputVolumeControlling
  let media: any MediaPlaybackControlling
  package init(volume: any OutputVolumeControlling, media: any MediaPlaybackControlling) {
    self.volume = volume
    self.media = media
  }
}
