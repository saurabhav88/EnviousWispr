import CoreAudio

/// Why a particular input device was chosen (#1714). Low-cardinality, safe to
/// put on a telemetry event.
enum InputResolutionSource: String, Sendable, Equatable {
  /// The user pinned this device and it was present in the frozen snapshot.
  case pinnedUID = "pinned_uid"
  /// CoreAudio reported a default input device and we took it.
  case systemDefault = "system_default"
  /// No default was reported, so an allow-listed physical device was chosen
  /// from the frozen list. This is the rung #1714 exists to add.
  case listFallback = "list_fallback"
}

/// Whether the device list was read, and how it went (#1714).
///
/// `notAttempted` is a first-class outcome, not a gap: on the ordinary Auto path
/// with a present system default the list is never enumerated at all, and that
/// has to be distinguishable from "enumerated and found nothing".
enum InputEnumerationOutcome: String, Sendable, Equatable {
  case notAttempted = "not_attempted"
  case succeeded
  /// The list read, but at least one device in it did not (#1714 cloud review
  /// r2). Its own case rather than a flag because it is the one field that makes
  /// this path visible in the field, and the race that produces it — a device
  /// unplugged between two CoreAudio calls — cannot be constructed in a test.
  case succeededPartial = "succeeded_partial"
  case readFailed = "read_failed"
}

/// One immutable resolution result (#1714).
///
/// Carries the facts that were true AT RESOLUTION TIME, including on the failure
/// paths, so telemetry never has to re-read hardware to describe the decision —
/// a second read would describe a different hardware state than the one that was
/// actually resolved against.
struct InputDeviceResolution: Sendable {
  enum Outcome: Sendable {
    case selected(AudioDeviceID, source: InputResolutionSource)
    case failed(AudioError)
  }

  let outcome: Outcome
  /// Whether CoreAudio reported a default input device on this attempt.
  let defaultPresent: Bool
  let enumerationOutcome: InputEnumerationOutcome
  /// Input devices in the frozen snapshot. Nil when enumeration was not
  /// attempted or the read failed — nil means "not known", never zero.
  let inputDeviceCount: Int?
  /// Snapshot candidates passing the physical allow-list. Same nil convention.
  let eligibleDeviceCount: Int?
  /// Low-cardinality transport label of the SELECTED device, when it came from
  /// the frozen snapshot. Nil on the not-attempted default path, where the
  /// transport is genuinely unknown without a second hardware read.
  let selectedTransport: String?

  var selectedDeviceID: AudioDeviceID? {
    if case .selected(let id, _) = outcome { return id }
    return nil
  }

  var resolutionSource: InputResolutionSource? {
    if case .selected(_, let source) = outcome { return source }
    return nil
  }

  var thrownError: AudioError? {
    if case .failed(let error) = outcome { return error }
    return nil
  }
}

/// Chooses which input device capture should open (#1714).
///
/// Exists because the shipped path asked CoreAudio exactly one question — "what
/// is the default input device?" — and aborted the recording when the answer was
/// nil, without ever looking at the device list. 226 events across 19 installs,
/// half of which never completed a single dictation.
///
/// Stateless and hardware-free by construction: every fact arrives through the
/// two injected providers, so the whole ladder is unit-testable and cannot
/// smuggle in a live CoreAudio read. It holds no remembered device — the
/// session-log 2026-07-14 defect class was three shipped sites deriving the Auto
/// device from a stored selection, and this type cannot join it.
///
/// Ownership: this is the SOLE capture device-selection authority.
/// `AudioDeviceEnumerator.inputDeviceSnapshot()` is the sole list read;
/// `HALDeviceInputSource` owns opening and committing the chosen device;
/// `AudioDeviceMonitor` observes device changes and never selects.
struct InputDeviceResolver {
  /// The live system default input. Injected so a test — and the DEBUG UAT seam
  /// — can force its absence, which is the whole failing condition.
  let defaultInputDeviceID: () -> AudioDeviceID?
  /// ONE frozen enumeration. Invoked AT MOST ONCE per `resolve` call: every
  /// count and transport reported below has to describe the same list the
  /// selected device came from.
  let inputDeviceSnapshot: () -> InputDeviceSnapshot
  /// The transport of ONE known device. A targeted property read, not a list
  /// read, so rung 1 can ask what the system default IS without paying for the
  /// enumeration it exists to avoid (#2022).
  let transportForDevice: (AudioDeviceID) -> UInt32?

  init(
    defaultInputDeviceID: @escaping () -> AudioDeviceID? = AudioDeviceEnumerator
      .defaultInputDeviceID,
    inputDeviceSnapshot: @escaping () -> InputDeviceSnapshot = AudioDeviceEnumerator
      .inputDeviceSnapshot,
    transportForDevice: @escaping (AudioDeviceID) -> UInt32? = AudioDeviceEnumerator
      .transportTypeRaw(for:)
  ) {
    self.defaultInputDeviceID = defaultInputDeviceID
    self.inputDeviceSnapshot = inputDeviceSnapshot
    self.transportForDevice = transportForDevice
  }

  /// Resolve the device to open. `preferredUID` is the user's pinned device;
  /// nil or empty means Auto.
  func resolve(preferredUID: String?) -> InputDeviceResolution {
    let defaultID = defaultInputDeviceID()
    let hasPreferred = !(preferredUID ?? "").isEmpty

    // #2022. ONE targeted transport read, computed once and consulted by rung 1
    // and rung 3, so the two rungs can never disagree about what the default IS.
    // Eager rather than lazy: rung 2 makes it unused when a pinned device is
    // found, and one property read on a per-dictation path is not worth a second
    // code path to avoid.
    //
    // PROOF ONLY. `isKnownNonMicrophoneTransport` is deliberately narrower than
    // "fails the allow-list" - nil, unknown and future transports are all
    // uncertainty and return false here - so an unreadable transport keeps
    // today's behaviour exactly. We divert on proof, never on doubt.
    let defaultProvenNonMicrophone =
      defaultID.map { AudioDeviceEnumerator.isKnownNonMicrophoneTransport(transportForDevice($0)) }
      ?? false

    // Rung 1 — the ordinary Auto path. A present default is taken WITHOUT
    // touching the device list, so the overwhelmingly common case does no
    // extra hardware work and reports `not_attempted` honestly.
    //
    // Unless the default is PROVEN not to be a microphone. A virtual or
    // aggregate default records bit-exact digital silence, and on the fleet
    // those two transports carry 21 stall events and ZERO successful dictations
    // across 2.4.0-2.4.4. Binding one is a guaranteed lost dictation, so this
    // pays for the enumeration it normally avoids and looks for a real
    // microphone instead. The cost lands only on the affected cohort.
    if !hasPreferred, let defaultID, !defaultProvenNonMicrophone {
      return InputDeviceResolution(
        outcome: .selected(defaultID, source: .systemDefault),
        defaultPresent: true,
        enumerationOutcome: .notAttempted,
        inputDeviceCount: nil,
        eligibleDeviceCount: nil,
        selectedTransport: nil
      )
    }

    // The only enumeration in this function.
    let snapshot = inputDeviceSnapshot()

    guard case .success(let candidates, let listComplete) = snapshot else {
      // Founder decision 2026-07-30, overriding plan §3 rung 7: a pinned device
      // we cannot find — dead AirPods, out of range, unplugged, or a list we
      // could not even read — swaps to auto, and that behaviour must not be
      // disrupted. An error belongs where the device is PRESENT and capture
      // actually fails, not where selection is merely uncertain while a working
      // default sits right there. So take the default rather than abort a take
      // that succeeds today; the read failure still reaches telemetry through
      // `enumerationOutcome`.
      if let defaultID {
        return InputDeviceResolution(
          outcome: .selected(defaultID, source: .systemDefault),
          defaultPresent: true,
          enumerationOutcome: .readFailed,
          inputDeviceCount: nil,
          eligibleDeviceCount: nil,
          selectedTransport: nil
        )
      }

      // No default either. A failed READ proves nothing about whether a
      // microphone exists, so it must not reach the "connect a microphone"
      // sentence — the user is told the capture failed, not that their
      // hardware is missing.
      return InputDeviceResolution(
        outcome: .failed(
          .formatCreationFailed(source: "InputDeviceResolver.enumerate_input_devices")),
        defaultPresent: false,
        enumerationOutcome: .readFailed,
        inputDeviceCount: nil,
        eligibleDeviceCount: nil,
        selectedTransport: nil
      )
    }

    let eligible = candidates.filter {
      AudioDeviceEnumerator.isAllowedPhysicalInputTransport($0.rawTransport)
    }

    // `transport` is nil both when nothing was selected and when the selected
    // device's transport was unreadable; `transportLabel` maps nil to nil, and
    // the two cases are already told apart by `outcome`.
    func resolution(
      _ outcome: InputDeviceResolution.Outcome, transport: UInt32? = nil
    ) -> InputDeviceResolution {
      InputDeviceResolution(
        outcome: outcome,
        defaultPresent: defaultID != nil,
        enumerationOutcome: listComplete ? .succeeded : .succeededPartial,
        inputDeviceCount: candidates.count,
        eligibleDeviceCount: eligible.count,
        selectedTransport: AudioDeviceEnumerator.transportLabel(forTransportType: transport)
      )
    }

    // Rung 2 — a pinned device, resolved ONLY inside the frozen snapshot. The
    // allow-list is not consulted: an explicit choice is the user's to make,
    // including an aggregate device.
    if hasPreferred, let pinned = candidates.first(where: { $0.uid == preferredUID }) {
      return resolution(.selected(pinned.id, source: .pinnedUID), transport: pinned.rawTransport)
    }

    // Rung 3 — the pinned device is gone. Fall through to the system default,
    // exactly as the shipped code already does. We already hold the frozen
    // snapshot here, so report the default's transport from it rather than
    // discarding a fact we have; nil only when the default is not itself an
    // input candidate.
    //
    // KNOWN LIMIT, accepted deliberately (#1714 cloud review r3). `defaultID` was
    // read before the snapshot, so a default unplugged in between is selected
    // stale even when the snapshot holds a live alternative. Not fixed by
    // rechecking `candidates` for three reasons:
    //   1. Absence from `candidates` does not PROVE the default is gone. On an
    //      incomplete list it proves nothing at all, and even on a complete one a
    //      device is excluded for having no readable input channels, which is not
    //      the same fact. Overriding the user's system default on inconclusive
    //      evidence, in the heart path, is the worse trade.
    //   2. Rung 1 above carries the identical staleness and deliberately does
    //      NOT enumerate, so this check would make the pinned path stricter than
    //      the Auto path about the same physical event, for no reason the user
    //      could perceive. Making them consistent means enumerating on every
    //      dictation, which §3 rung 1 exists to avoid.
    //   3. It needs a double coincidence — pinned device missing AND default
    //      changing inside the gap between two adjacent reads. Founder priority 3
    //      is explicit that rare genuine failures get simple handling rather than
    //      machinery.
    // The outcome is a failed bind, which `bind_outcome = failed` records; if it
    // instead binds and captures silence, that is the silent-capture family
    // (#1845 / #1578 / #1809), which owns detection and is out of scope here.
    //
    // #2022 adds ONE condition: divert away from a proven non-microphone default
    // ONLY when there is a real microphone to divert TO. With no alternative we
    // bind the default exactly as before, so this change never turns a working
    // take into an error.
    //
    // WHAT THAT DELIBERATELY DOES NOT FIX. Binding a proven non-microphone with
    // no alternative still loses the dictation, which is the very failure this
    // issue targets. Refusing instead would be honest, but the outcome it lands
    // on (`noBuiltInMicrophoneFound`) both asserts "No microphone found. Please
    // connect one." — questionable when a user DELIBERATELY built an aggregate
    // device, which can contain a real microphone and record perfectly well —
    // and files an ALERTING Sentry error, which is the opposite of the reason
    // this work was prioritised. Doing it properly needs a non-alerting
    // environment outcome that does not exist yet.
    //
    // So this is a KNOWN, MEASURED LIMIT, not an oversight: aggregate defaults
    // are one install across four releases. Founder call, not a code call.
    //
    // With `!eligible.isEmpty` required, this change introduces NO new path to
    // that message: every input that reaches it today still does, and nothing
    // new does. The failure directions are asymmetric and decide it - diverting
    // wrongly withdraws a working microphone, declining to divert merely leaves
    // today's behaviour in place.
    //
    // This one condition serves both entries to this rung: a pinned device that
    // vanished, and rung 1 falling through on a proven non-microphone default.
    if let defaultID, !(defaultProvenNonMicrophone && !eligible.isEmpty) {
      return resolution(
        .selected(defaultID, source: .systemDefault),
        transport: candidates.first(where: { $0.id == defaultID })?.rawTransport
      )
    }

    // Rung 4 — nobody chose anything and CoreAudio has no default. Prefer the
    // built-in microphone over whatever happens to be listed first, then take
    // the first allow-listed physical device in snapshot order.
    let builtIn = eligible.first { $0.rawTransport == kAudioDeviceTransportTypeBuiltIn }
    if let chosen = builtIn ?? eligible.first {
      return resolution(
        .selected(chosen.id, source: .listFallback), transport: chosen.rawTransport)
    }

    // Nothing eligible. Which error depends on whether the list PROVES there is
    // no microphone, or merely fails to prove there is one.
    //
    // `listComplete` is the first term for two reasons. An INCOMPLETE list can
    // never prove absence — the device we failed to read is exactly the one that
    // might have been a microphone. And `allSatisfy` is vacuously TRUE on an
    // empty array, so without this gate an enumeration where every single device
    // failed its read would sail into "connect a microphone", which is the
    // strongest possible false claim from the weakest possible evidence.
    let provesAbsence =
      listComplete
      && candidates.allSatisfy {
        AudioDeviceEnumerator.isKnownNonMicrophoneTransport($0.rawTransport)
      }
    return resolution(
      .failed(
        provesAbsence
          ? .noBuiltInMicrophoneFound
          : .formatCreationFailed(
            source: "InputDeviceResolver.unclassifiable_input_transport")))
  }

  // MARK: - Warm-bind compatibility

  /// Is an ALREADY-OPEN bind still the device the user is asking for?
  ///
  /// A deliberately separate projection from `resolve(preferredUID:)`, not a
  /// call into it. The cold ladder RANKS candidates and may pick a fallback
  /// device; this one only ANSWERS whether the live bind still matches intent.
  /// Running the ladder here would let automatic fallback ranking decide a warm
  /// take, which the plan confines to cold opens (§12).
  ///
  /// **Founder decision 2026-07-30: a reconnected pinned device reclaims the
  /// take immediately.** So when the pinned UID reappears in the snapshot and is
  /// not what we are bound to, this returns false, the manager tears the warm
  /// source down (`AudioCaptureManager.swift:899`) and the next open is cold —
  /// which is exactly how the user's chosen microphone wins back the take. This
  /// is the mirror of rung 3: a chosen device that vanishes swaps to auto, and a
  /// chosen device that returns takes the take back.
  ///
  /// Cost note: on the pinned path this reads the device list, as the shipped
  /// code it replaces already did (`resolveDeviceID()` → `deviceID(forUID:)` →
  /// `allInputDevices()`). On Auto it reads only the default and never
  /// enumerates, also as before. No new work on either path.
  func isWarmBindCompatible(_ bound: BoundInputDevice, preferredUID: String?) -> Bool {
    let defaultID = defaultInputDeviceID()
    let hasPreferred = !(preferredUID ?? "").isEmpty

    // Auto: the live default is the whole question. Never enumerate.
    guard hasPreferred else {
      return matchesDefaultOrKeepsFallback(bound, defaultID: defaultID)
    }

    // Pinned: one snapshot, purely to ask "is the chosen device back?".
    //
    // Completeness is deliberately ignored here, unlike the cold ladder. This
    // asks only whether the pinned device was SEEN, and a partial list either
    // contains it or does not. Not finding it already falls through to the
    // conservative answer below, which is the same answer an unreadable device
    // deserves — so there is nothing for a completeness check to change.
    guard case .success(let candidates, _) = inputDeviceSnapshot() else {
      // The read failed, so it has NOT shown the pinned device returned. Fall
      // back to the same question Auto asks rather than guessing.
      return matchesDefaultOrKeepsFallback(bound, defaultID: defaultID)
    }

    if let pinned = candidates.first(where: { $0.uid == preferredUID }) {
      return bound.deviceID == pinned.id
    }

    return matchesDefaultOrKeepsFallback(bound, defaultID: defaultID)
  }

  /// The shared tail of both compatibility paths: track the live default when
  /// there is one, and otherwise keep ONLY a bind that the fallback rung chose.
  ///
  /// The `list_fallback` restriction is load-bearing. A bind that came from a
  /// pinned device or a since-vanished default is not made correct by both of
  /// those disappearing — only a bind we selected precisely BECAUSE no default
  /// existed is still the right answer in that state.
  private func matchesDefaultOrKeepsFallback(
    _ bound: BoundInputDevice, defaultID: AudioDeviceID?
  ) -> Bool {
    if let defaultID { return bound.deviceID == defaultID }
    return bound.resolutionSource == InputResolutionSource.listFallback.rawValue
  }
}

/// Did the AudioUnit actually get pointed at the chosen device? (#1714)
///
/// Separate from `InputPrepareOutcome` because binding is ONE step
/// (`AudioUnitSetProperty(kAudioOutputUnitProperty_CurrentDevice)`) and several
/// fallible setup steps follow it. Collapsing the two would make "we could not
/// open the microphone" indistinguishable from "we opened it and the converter
/// failed", which are different bugs with different owners.
enum InputBindOutcome: String, Sendable, Equatable {
  /// Resolution failed, or the attempt exited before the bind was tried.
  case notAttempted = "not_attempted"
  case failed
  case succeeded
}

/// Did the whole cold `prepare()` succeed? (#1714)
enum InputPrepareOutcome: String, Sendable, Equatable {
  case failed
  case succeeded
}

/// Accumulates one cold attempt's outcomes as `prepare()` walks its steps
/// (#1714). Extracted so the OUTCOME TRANSITIONS THEMSELVES are the thing tests
/// exercise: an earlier version had `prepare()` mutate two local variables and
/// the suite assert a table it wrote itself, which proved only that the copy
/// agreed with the copy. Deleting the success transition left it green.
///
/// **`prepareOutcome` is DERIVED, never stored.** A prepare cannot have
/// succeeded on a device that was never bound, so that combination is not
/// representable rather than merely tested. The reviewer proposed a
/// `precondition` in `recordPrepareSucceeded`; declined and replaced with this,
/// because a `precondition` on the cold-open path is a crash primitive on the
/// heart path guarding a state the control flow already rules out — and the
/// project's rule is to make the window impossible, not to handle it with the
/// most destructive response available.
struct InputResolutionAttemptState: Sendable {
  private(set) var bindOutcome: InputBindOutcome = .notAttempted
  private var prepareReachedTheEnd = false

  /// `failed` until every fallible step has run AND the device was bound.
  var prepareOutcome: InputPrepareOutcome {
    bindOutcome == .succeeded && prepareReachedTheEnd ? .succeeded : .failed
  }

  /// Record the authoritative current-device property result.
  mutating func recordBind(succeeded: Bool) {
    bindOutcome = succeeded ? .succeeded : .failed
  }

  /// Called once, after the four-field bind is committed.
  mutating func recordPrepareSucceeded() {
    prepareReachedTheEnd = true
  }

  func finalized(resolution: InputDeviceResolution) -> FinalizedInputResolutionAttempt {
    FinalizedInputResolutionAttempt(
      resolution: resolution, bindOutcome: bindOutcome, prepareOutcome: prepareOutcome)
  }
}

/// One COLD attempt, finalised (#1714).
///
/// Emitted exactly once per cold `prepare()` exit — success, resolution failure,
/// bind failure, or a later setup failure — and never on warm reuse. Carries the
/// resolution facts frozen at decision time so no consumer re-reads hardware to
/// describe an attempt that has already finished.
struct FinalizedInputResolutionAttempt: Sendable {
  let resolution: InputDeviceResolution
  let bindOutcome: InputBindOutcome
  let prepareOutcome: InputPrepareOutcome
}

/// One finalised cold attempt, projected for telemetry (#1714).
///
/// A flat value of primitives so the composition root can hand it to
/// `TelemetryService` without `EnviousWisprAudio` importing Services, and
/// without resolver or hardware types escaping this module. `package`, not
/// `public`: only the app shell needs it.
package struct InputResolutionAttemptTelemetry: Sendable, Equatable {
  package let defaultPresent: Bool
  package let enumerationOutcome: String
  /// Nil means NOT KNOWN — enumeration was not attempted or its read failed.
  /// Never flatten to zero: zero is a real, different answer meaning the machine
  /// genuinely listed no input devices.
  package let inputDeviceCount: Int?
  /// Same nil convention as `inputDeviceCount`.
  package let eligibleDeviceCount: Int?
  package let inputResolutionSource: String?
  package let selectedTransport: String?
  package let bindOutcome: String
  package let prepareOutcome: String

  /// Internal: only this module constructs one.
  init(_ attempt: FinalizedInputResolutionAttempt) {
    self.defaultPresent = attempt.resolution.defaultPresent
    self.enumerationOutcome = attempt.resolution.enumerationOutcome.rawValue
    self.inputDeviceCount = attempt.resolution.inputDeviceCount
    self.eligibleDeviceCount = attempt.resolution.eligibleDeviceCount
    self.inputResolutionSource = attempt.resolution.resolutionSource?.rawValue
    self.selectedTransport = attempt.resolution.selectedTransport
    self.bindOutcome = attempt.bindOutcome.rawValue
    self.prepareOutcome = attempt.prepareOutcome.rawValue
  }
}
