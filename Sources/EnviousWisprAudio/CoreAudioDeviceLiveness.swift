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
  /// We have no trustworthy answer. `classify` reaches this two ways: the device
  /// does not advertise the property (`AudioObjectHasProperty` is false, so no
  /// read happens at all), or the read returned a non-`noErr` status, whose
  /// out-parameter contents are not trustworthy. Either way we do NOT know
  /// whether the device is muted, so the caller must fail closed — same posture
  /// as `DeviceLiveness.unverified`.
  ///
  /// Property absence is a real path. On the four devices measured on macOS 26.6,
  /// however, the input-scope property was present and settable (#1809; three
  /// re-measured in #1578).
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
  ///   ONLY when `status == noErr`; on every other status its contents are not
  ///   trustworthy — `AudioObjectGetPropertyData` promises nothing about what it
  ///   leaves there — so it is deliberately not read.
  public static func interpret(status: OSStatus, isMuted: UInt32) -> DeviceMuteState {
    switch status {
    case noErr:
      return isMuted == 0 ? .unmuted : .muted

    // On a non-`noErr` status the out-parameter's contents are NOT trustworthy —
    // `AudioObjectGetPropertyData` makes no promise about what it leaves there —
    // so there is nothing to read. Absence of an answer is not an answer of
    // "unmuted", so this fails closed to `.unverified`.
    //
    // The previous justification here — "most built-in mics have no hardware
    // mute control and simply don't implement this property" — was measurably
    // FALSE on our hardware: built-in, USB webcam and both virtual drivers all
    // implement it and all are settable (#1809 measured four, #1578 three). The
    // conclusion was right for the wrong reason, which is worse than no comment,
    // because it invites the next reader to trust a claim that does not hold.
    //
    // Two things this comment deliberately does NOT claim, both because a review
    // of its first draft caught them as fresh unsupported premises:
    //   * that the buffer is left untouched or still holds its zero initializer.
    //     It is merely untrustworthy; the guarantee does not exist.
    //   * that property-absence cannot produce `.unverified`. It can — `classify`
    //     returns early when `AudioObjectHasProperty` is false, without reaching
    //     this switch at all.
    //
    // And the genuinely interesting caveat lives one level up, independent of
    // status: a VIRTUAL driver can accept a mute write and keep reading 0 — the
    // Teams loopback did exactly that (#1809). So even `noErr` is not proof.
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

/// #1578: WHY the zero-signal discriminator answered as it did. The Boolean
/// `isEligible` collapsed identity mismatch, not-alive, muted and mute-unknown
/// into one `false`, so a refusal recorded no reason at all — which is the
/// defect #1578 exists to close.
///
/// Diagnostic classification, NEVER a failure: only `.eligible` permits
/// `fireDeadAirStall`, and every other case leaves the take on today's silent
/// no-speech path unchanged.
public enum ZeroSignalEligibility: String, Sendable, CaseIterable {
  case eligible
  /// No frozen bind to classify. A defensive invariant canary, not an ordinary
  /// input: `startEnginePhase()` adopts the non-optional result of a successful
  /// `prepare()` and no teardown path clears it, so this should never appear in
  /// production — if it does, the invariant broke and that is itself the finding.
  case boundDeviceUnavailable = "bound_device_unavailable"
  /// The bind's UID is unknown, unreadable now, or no longer matches the live
  /// UID for that `AudioDeviceID`. All three are one outcome because all three
  /// mean the same thing operationally: we cannot prove this handle still names
  /// the microphone we bound, so nothing CoreAudio says about it can be trusted.
  case identityMismatch = "identity_mismatch"
  /// Liveness answered anything other than `.alive` — including `.unverified`,
  /// which fails closed per the #1317 binding decision.
  case notAlive = "not_alive"
  /// The input-scope mute read succeeded and reported muted. Trustworthy in this
  /// direction only: `.unmuted` is NOT trustworthy, because a device can mute in
  /// its own firmware and still report unmuted here (the Plantronics Blackwire
  /// 5220 does exactly that), and a virtual driver can accept a mute write and
  /// keep reading 0 (#1809).
  case deviceMuted = "device_muted"
  /// The mute property is absent, or the read returned non-`noErr`. "Cannot
  /// tell" is a distinct answer from "not muted"; collapsing them was part of
  /// the defect.
  case muteUnverified = "mute_unverified"
}

/// #1317 §3.0, widened at #1578: the single authority for deciding whether
/// the frozen capture device is eligible for harness-glitch recovery and, when
/// it is not, why. Both the in-process reactive detector (`AudioCaptureManager`)
/// and the kernel's STOP-time classification use this type, so identity,
/// liveness, and input-scope mute precedence cannot drift between callers.
public enum ZeroSignalDeviceDiscriminator {
  /// Production entry point. Public, with no default arguments or injected seams
  /// — a `public` function's default argument cannot reference the internal
  /// `AudioDeviceEnumerator.inputDeviceUID(for:)`, so the injected form is a
  /// separate `package` overload below rather than defaults on this one.
  ///
  /// Fails closed: an unverifiable identity, any non-`.alive` liveness, or any
  /// non-`.unmuted` mute state returns false. `classify` below preserves the
  /// categorical reason. #1317 adds no hardware-mute UX; ambiguity must never
  /// be read as "safe to run harness recovery."
  ///
  /// Callers must pass the FROZEN bind (`prepare()`'s return value, #1844), never
  /// a freshly resolved device.
  public static func isEligible(bound: BoundInputDevice) -> Bool {
    classify(bound: bound) == .eligible
  }

  /// #1578: the reason-bearing production entry point, and the sole owner of all
  /// SIX outcomes — including the missing-bind case, which both call sites used
  /// to manufacture independently (the very scatter this type's doc comment
  /// forbids). Takes the OPTIONAL bind for exactly that reason.
  public static func classify(bound: BoundInputDevice?) -> ZeroSignalEligibility {
    classify(
      bound: bound,
      inputDeviceUID: AudioDeviceEnumerator.inputDeviceUID(for:),
      liveness: CoreAudioDeviceLiveness.classify(deviceID:),
      muteState: CoreAudioDeviceMute.classify(deviceID:))
  }

  /// Same-package, fully injected — the deterministic seam the identity matrix
  /// drives, so no case depends on the test machine's microphones. `package`
  /// rather than `internal` because the test target is a separate module in this
  /// package and would otherwise need `@testable`.
  package static func isEligible(
    bound: BoundInputDevice,
    inputDeviceUID: (AudioDeviceID) -> String?,
    liveness: (AudioDeviceID) -> DeviceLiveness,
    muteState: (AudioDeviceID) -> DeviceMuteState
  ) -> Bool {
    classify(
      bound: bound, inputDeviceUID: inputDeviceUID, liveness: liveness, muteState: muteState)
      == .eligible
  }

  /// #1578: the injected reason-bearing seam. Same evaluation order as the
  /// Boolean form it now backs — identity, then liveness, then hardware mute
  /// (#1844: a recycled `AudioDeviceID` makes every later answer describe the
  /// wrong microphone, so identity must come first, and each refusal
  /// short-circuits before the reads below it).
  package static func classify(
    bound: BoundInputDevice?,
    inputDeviceUID: (AudioDeviceID) -> String?,
    liveness: (AudioDeviceID) -> DeviceLiveness,
    muteState: (AudioDeviceID) -> DeviceMuteState
  ) -> ZeroSignalEligibility {
    guard let bound else { return .boundDeviceUnavailable }
    // #1844: an AudioDeviceID is a runtime handle CoreAudio MAY reuse, so a
    // numeric match is not physical identity — liveness on a recycled id would
    // answer ALIVE about the WRONG microphone. Confirm the id still resolves to
    // the UID captured at bind before trusting any answer about it.
    // Unknown-at-bind or changed-since ⇒ fail closed, same as `.unverified`.
    // NOTE: ID reuse is HYPOTHETICAL — never observed here. This guard is
    // retained as a fail-closed identity check, not because reuse was measured.
    guard let boundUID = bound.deviceUID, inputDeviceUID(bound.deviceID) == boundUID
    else { return .identityMismatch }
    guard liveness(bound.deviceID) == .alive else { return .notAlive }
    switch muteState(bound.deviceID) {
    case .unmuted: return .eligible
    case .muted: return .deviceMuted
    case .unverified: return .muteUnverified
    }
  }
}
