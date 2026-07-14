import CoreAudio

/// #1408. What Core Audio told us when we asked whether an input device is still
/// there. The third case is the one that matters: "we could not find out" is not
/// the same answer as "it is gone," and only the latter may reach the user.
public enum DeviceLiveness: Sendable, Equatable {
  /// `DeviceIsAlive` answered yes. A Bluetooth codec switch, not a disconnect.
  case alive

  /// The device is gone: either it reported dead, or its object no longer
  /// resolves. Entitles the caller to `.deviceRemoved`.
  case removed

  /// Core Audio failed the query for a reason that does not name a missing
  /// device. We know the capture is broken; we do NOT know the microphone left.
  case unverified
}

/// The single home for reading `kAudioDevicePropertyDeviceIsAlive` and turning
/// the result into a `DeviceLiveness`.
///
/// The capture source (`HALDeviceInputSource`, from its liveness listener) asks
/// this question. It used to inline the read, ignore the returned `OSStatus`,
/// and test the `isAlive` out-parameter alone. That is wrong in BOTH directions
/// once the answer drives user-facing copy:
///
/// - `isAlive` is a zero-initialized out-parameter. On any failed read it stays
///   zero, so an unchecked read reports "dead" for a transient error and would
///   stamp a permanent crossed-out-microphone badge on a recording whose
///   microphone never left (Codex review r3).
/// - But a REMOVED device's `AudioDeviceID` stops naming a valid object, so the
///   query for a genuinely unplugged mic returns `kAudioHardwareBadObjectError`
///   rather than `noErr` + `isAlive == 0`. Treating every non-`noErr` status as
///   "unverified" would therefore suppress the disconnect notice on exactly the
///   case #1408 exists for. Verified empirically: querying a nonexistent
///   `AudioDeviceID` returns `'!obj'` and leaves `isAlive` at zero.
public enum CoreAudioDeviceLiveness {

  /// The pure decision, split out so it can be tested across the whole status
  /// space without a real device to unplug.
  ///
  /// - Parameter isAlive: the out-parameter as Core Audio left it. Meaningful
  ///   ONLY when `status == noErr`; on every other status it is still its zero
  ///   initializer and is deliberately not read.
  public static func interpret(status: OSStatus, isAlive: UInt32) -> DeviceLiveness {
    switch status {
    case noErr:
      return isAlive == 0 ? .removed : .alive

    // The ID does not name a live object / device. A removed device's ID is
    // invalidated, so this IS the disconnect — not a failure to observe one.
    case kAudioHardwareBadObjectError, kAudioHardwareBadDeviceError:
      return .removed

    // Anything else (bad property size, unknown property, an in-flight HAL
    // reconfiguration): the read failed for a reason that says nothing about
    // whether the device is present. Never claim a disconnect from here.
    default:
      return .unverified
    }
  }

  /// Performs the read against Core Audio and interprets it.
  public static func classify(deviceID: AudioDeviceID) -> DeviceLiveness {
    var isAlive: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceIsAlive,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &isAlive)
    return interpret(status: status, isAlive: isAlive)
  }
}

/// #1317. What Core Audio told us when we asked whether an input device is
/// muted at the OS/process level. A running, alive device legitimately
/// zero-fills its stream while muted — this is the discriminator that keeps
/// the #1317 harness-glitch detector from misfiring on a genuinely muted mic
/// (out of scope; no hardware-mute UX is built here, §3.0).
public enum DeviceMuteState: Sendable, Equatable {
  /// `Mute` answered yes — a running device zero-filling by design, not a
  /// harness glitch.
  case muted
  /// `Mute` answered no.
  case unmuted
  /// Core Audio failed the query, or it doesn't support the property (common
  /// on devices with no hardware mute control). We do NOT know whether the
  /// device is muted, so the caller must fail closed — same posture as
  /// `DeviceLiveness.unverified`.
  case unverified
}

/// The single home for reading `kAudioDevicePropertyMute` on the INPUT scope
/// and turning the result into a `DeviceMuteState`. Mirrors
/// `CoreAudioDeviceLiveness`'s split (pure `interpret` + `classify` read) so
/// the decision unit-tests across the whole status space without a real
/// device.
public enum CoreAudioDeviceMute {

  /// The pure decision, split out for boundary testing.
  ///
  /// - Parameter isMuted: the out-parameter as Core Audio left it. Meaningful
  ///   ONLY when `status == noErr`; on every other status it is still its
  ///   zero initializer and is deliberately not read.
  public static func interpret(status: OSStatus, isMuted: UInt32) -> DeviceMuteState {
    switch status {
    case noErr:
      return isMuted == 0 ? .unmuted : .muted

    // Many input devices (most built-in mics) have no hardware mute control
    // and simply don't implement this property — that is NOT evidence the
    // device is unmuted, so it must fail closed to `.unverified`, same as
    // any other non-`noErr` status.
    default:
      return .unverified
    }
  }

  /// Performs the read against Core Audio and interprets it. INPUT scope
  /// (not global) — `kAudioDevicePropertyMute` on the global scope answers a
  /// different (usually unsupported) question for an input-only device.
  public static func classify(deviceID: AudioDeviceID) -> DeviceMuteState {
    var isMuted: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyMute,
      mScope: kAudioObjectPropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectHasProperty(deviceID, &addr) else { return .unverified }
    let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &isMuted)
    return interpret(status: status, isMuted: isMuted)
  }
}

/// #1317 §3.0: the single, shared "is this device eligible for harness-glitch
/// recovery" decision — device `.alive` AND NOT muted. Both the app-side
/// reactive detector (`AudioCaptureProxy`) and the kernel's STOP-time
/// classification read through this ONE function so the discriminator has a
/// single authority, not two independent alive+mute combinations.
public enum ZeroSignalDeviceDiscriminator {
  /// Fails closed: any non-`.alive` liveness or non-`.unmuted` mute state —
  /// including `.unverified` — returns false. #1317 adds no hardware-mute
  /// UX; ambiguity must never be read as "safe to run harness recovery."
  public static func isEligible(deviceID: AudioDeviceID) -> Bool {
    CoreAudioDeviceLiveness.classify(deviceID: deviceID) == .alive
      && CoreAudioDeviceMute.classify(deviceID: deviceID) == .unmuted
  }
}
