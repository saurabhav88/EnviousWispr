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

  init(
    defaultInputDeviceID: @escaping () -> AudioDeviceID? = AudioDeviceEnumerator
      .defaultInputDeviceID,
    inputDeviceSnapshot: @escaping () -> InputDeviceSnapshot = AudioDeviceEnumerator
      .inputDeviceSnapshot
  ) {
    self.defaultInputDeviceID = defaultInputDeviceID
    self.inputDeviceSnapshot = inputDeviceSnapshot
  }

  /// Resolve the device to open. `preferredUID` is the user's pinned device;
  /// nil or empty means Auto.
  func resolve(preferredUID: String?) -> InputDeviceResolution {
    let defaultID = defaultInputDeviceID()
    let hasPreferred = !(preferredUID ?? "").isEmpty

    // Rung 1 — the ordinary Auto path. A present default is taken WITHOUT
    // touching the device list, so the overwhelmingly common case does no
    // extra hardware work and reports `not_attempted` honestly.
    if !hasPreferred, let defaultID {
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

    guard case .success(let candidates) = snapshot else {
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
        enumerationOutcome: .succeeded,
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
    if let defaultID {
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
    let provesAbsence = candidates.allSatisfy {
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
    guard case .success(let candidates) = inputDeviceSnapshot() else {
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
