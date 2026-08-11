import CoreAudio
import Foundation
import Testing

@testable import EnviousWisprAudio

/// Names the completeness axis at every construction site (#1714 cloud review
/// r2). Deliberately NOT a defaulted parameter: `complete` decides whether an
/// unusable list may tell the user to connect a microphone, so a test must say
/// which world it is describing rather than inherit one silently.
extension InputDeviceSnapshot {
  /// Every enumerated device was readable — the ordinary case.
  static func complete(_ candidates: [InputDeviceCandidate]) -> InputDeviceSnapshot {
    .success(candidates: candidates, complete: true)
  }

  /// At least one enumerated device could not be read, so the list can no
  /// longer prove that a microphone is absent.
  static func partial(_ candidates: [InputDeviceCandidate]) -> InputDeviceSnapshot {
    .success(candidates: candidates, complete: false)
  }
}

// #1714 — freezes the capture device-selection ladder.
//
// Entirely hardware-free: every fact arrives through the resolver's two injected
// providers, so this suite runs identically on a laptop and on the CI runner,
// which has no audio input device at all.
//
// The two invariants worth stating outright, because both fail SILENTLY:
//   - the snapshot provider runs AT MOST ONCE per attempt, so every count and
//     transport describes the same list the selected device came from;
//   - the fallback does NOT run when a system default resolves. A guard that
//     fired on every call would pass the positive tests while quietly taking
//     device selection away from the system default on every dictation.
@Suite("InputDeviceResolver ladder — #1714")
struct InputDeviceResolverTests {

  // MARK: - Harness

  /// Counts provider invocations so "at most one enumeration" is asserted, not
  /// assumed. A class because the resolver's closure captures it; the suite is
  /// single-threaded, hence `@unchecked`.
  private final class SnapshotSpy: @unchecked Sendable {
    private(set) var callCount = 0
    private let result: InputDeviceSnapshot

    init(_ result: InputDeviceSnapshot) { self.result = result }

    func provide() -> InputDeviceSnapshot {
      callCount += 1
      return result
    }
  }

  /// Counts targeted transport reads (#2022). Same shape as `SnapshotSpy`: the
  /// point is that a read the resolver performs is COUNTABLE, so "at most one
  /// per resolve" is a tested property rather than a claim in a comment.
  private final class TransportReadCounter: @unchecked Sendable {
    private(set) var count = 0
    func bump() { count += 1 }
  }

  private func candidate(
    _ id: AudioDeviceID, _ uid: String, _ transport: UInt32?
  ) -> InputDeviceCandidate {
    InputDeviceCandidate(id: id, uid: uid, rawTransport: transport)
  }

  /// The spy is the ONLY source of the snapshot, so no test can pass a snapshot
  /// that is silently ignored.
  ///
  /// `defaultTransport` is injected on EVERY call and never defaulted to the
  /// production reader: `InputDeviceResolver`'s own contract is that it "cannot
  /// smuggle in a live CoreAudio read", and leaving the #2022 parameter at its
  /// production default would have every test below performing one against
  /// whatever hardware the machine happens to have. Built-in is the neutral
  /// value — a real microphone, so it changes no pre-#2022 expectation.
  private func resolve(
    preferredUID: String? = nil,
    defaultID: AudioDeviceID?,
    defaultTransport: UInt32? = kAudioDeviceTransportTypeBuiltIn,
    spy: SnapshotSpy
  ) -> InputDeviceResolution {
    InputDeviceResolver(
      defaultInputDeviceID: { defaultID },
      inputDeviceSnapshot: { spy.provide() },
      transportForDevice: { _ in defaultTransport }
    ).resolve(preferredUID: preferredUID)
  }

  private func resolve(
    preferredUID: String? = nil,
    defaultID: AudioDeviceID?,
    defaultTransport: UInt32? = kAudioDeviceTransportTypeBuiltIn,
    snapshot: InputDeviceSnapshot
  ) -> InputDeviceResolution {
    resolve(
      preferredUID: preferredUID, defaultID: defaultID, defaultTransport: defaultTransport,
      spy: SnapshotSpy(snapshot))
  }

  /// One accepted transport. A named type rather than a tuple so the
  /// parameterised test has an unambiguous single argument.
  struct AcceptedTransport: Sendable, CustomStringConvertible {
    let raw: UInt32
    let name: String
    var description: String { name }
  }

  /// Every transport the allow-list accepts. Frozen: adding one is a fleet-
  /// evidence decision, and silently dropping one would strand those users on
  /// the "no microphone" error.
  private static let acceptedTransports: [AcceptedTransport] = [
    AcceptedTransport(raw: kAudioDeviceTransportTypeBuiltIn, name: "built_in"),
    AcceptedTransport(raw: kAudioDeviceTransportTypeUSB, name: "usb"),
    AcceptedTransport(raw: kAudioDeviceTransportTypeBluetooth, name: "bluetooth"),
    AcceptedTransport(raw: kAudioDeviceTransportTypeBluetoothLE, name: "bluetooth_le"),
    AcceptedTransport(
      raw: kAudioDeviceTransportTypeContinuityCaptureWired, name: "continuity_wired"),
    AcceptedTransport(
      raw: kAudioDeviceTransportTypeContinuityCaptureWireless, name: "continuity_wireless"),
    AcceptedTransport(raw: kAudioDeviceTransportTypeThunderbolt, name: "thunderbolt"),
    AcceptedTransport(raw: kAudioDeviceTransportTypeDisplayPort, name: "display_port"),
    AcceptedTransport(raw: kAudioDeviceTransportTypeHDMI, name: "hdmi"),
    AcceptedTransport(raw: kAudioDeviceTransportTypePCI, name: "pci"),
    AcceptedTransport(raw: kAudioDeviceTransportTypeFireWire, name: "fire_wire"),
    AcceptedTransport(raw: kAudioDeviceTransportTypeAVB, name: "avb"),
  ]

  /// A raw value no CoreAudio constant uses, standing in for a transport a
  /// future macOS invents. It must be REFUSED, not accepted by default.
  private static let futureUnknownTransport: UInt32 = 0x5A5A_5A5A

  // MARK: - Rung 1: the ordinary Auto path

  @Test("default present on Auto selects it and never enumerates")
  func defaultPresentSkipsEnumeration() {
    let spy = SnapshotSpy(.complete([candidate(7, "built-in", kAudioDeviceTransportTypeBuiltIn)]))
    let result = resolve(defaultID: 42, spy: spy)

    #expect(result.selectedDeviceID == 42)
    #expect(result.resolutionSource == .systemDefault)
    #expect(result.defaultPresent)
    #expect(result.enumerationOutcome == .notAttempted)
    #expect(result.inputDeviceCount == nil)
    #expect(result.eligibleDeviceCount == nil)
    // The two-way control: the fallback must NOT run when the default resolves.
    #expect(spy.callCount == 0)
  }

  @Test("an empty preferred UID is treated as Auto, not as a device named empty")
  func emptyPreferredUIDIsAuto() {
    let spy = SnapshotSpy(.complete([candidate(110, "", kAudioDeviceTransportTypeVirtual)]))
    let result = resolve(preferredUID: "", defaultID: 42, spy: spy)

    // Auto with a present default: no enumeration, and crucially NOT a match
    // against the empty-UID virtual device.
    #expect(result.selectedDeviceID == 42)
    #expect(result.resolutionSource == .systemDefault)
    #expect(spy.callCount == 0)
  }

  // MARK: - Rung 1b: a system default that is proven not to be a microphone (#2022)

  @Test("a virtual system default loses Auto to a real microphone")
  func virtualDefaultDivertsToPhysical() {
    let spy = SnapshotSpy(
      .complete([
        candidate(60, "BlackHole2ch", kAudioDeviceTransportTypeVirtual),
        candidate(7, "BuiltInMicrophoneDevice", kAudioDeviceTransportTypeBuiltIn),
      ]))
    let result = resolve(
      defaultID: 60, defaultTransport: kAudioDeviceTransportTypeVirtual, spy: spy)

    #expect(result.selectedDeviceID == 7)
    #expect(result.resolutionSource == .listFallback)
    // The enumeration rung 1 normally avoids IS paid for here, and only here.
    #expect(spy.callCount == 1)
  }

  @Test("an aggregate system default loses Auto to a real microphone")
  func aggregateDefaultDivertsToPhysical() {
    let spy = SnapshotSpy(
      .complete([
        candidate(61, "aggregate", kAudioDeviceTransportTypeAggregate),
        candidate(8, "usb-mic", kAudioDeviceTransportTypeUSB),
      ]))
    let result = resolve(
      defaultID: 61, defaultTransport: kAudioDeviceTransportTypeAggregate, spy: spy)

    #expect(result.selectedDeviceID == 8)
    #expect(result.resolutionSource == .listFallback)
  }

  /// THE NO-REGRESSION CASE. With no real microphone to divert to, the default
  /// is bound exactly as before, so #2022 never turns a working take into an
  /// error and adds no new path to "No microphone found".
  ///
  /// This is a known limit rather than a fix: binding a proven non-microphone
  /// still loses that dictation. Refusing would assert "connect a microphone" to
  /// someone who may have deliberately built an aggregate device that records
  /// fine, and would file an alerting error — the opposite of why this was
  /// prioritised. Freezing the conservative behaviour so a later change to it is
  /// a deliberate decision, not an accident.
  ///
  /// #2022 therefore introduces NO new path to "no microphone found".
  @Test("a proven non-microphone default is still used when there is no real microphone")
  func nonMicrophoneDefaultIsKeptWhenNothingElseExists() {
    let spy = SnapshotSpy(
      .complete([
        candidate(60, "BlackHole2ch", kAudioDeviceTransportTypeVirtual),
        candidate(61, "aggregate", kAudioDeviceTransportTypeAggregate),
      ]))
    let result = resolve(
      defaultID: 61, defaultTransport: kAudioDeviceTransportTypeAggregate, spy: spy)

    #expect(result.selectedDeviceID == 61)
    #expect(result.resolutionSource == .systemDefault)
    #expect(result.thrownError == nil, "diverting nowhere must never become an error")
  }

  @Test("an unreadable default transport keeps today's behaviour, never diverting on doubt")
  func unreadableDefaultTransportFailsOpen() {
    let spy = SnapshotSpy(.complete([candidate(7, "built-in", kAudioDeviceTransportTypeBuiltIn)]))
    let result = resolve(defaultID: 42, defaultTransport: nil, spy: spy)

    #expect(result.selectedDeviceID == 42)
    #expect(result.resolutionSource == .systemDefault)
    #expect(result.enumerationOutcome == .notAttempted)
    #expect(spy.callCount == 0, "uncertainty must not buy an enumeration")
  }

  @Test("an unknown default transport keeps today's behaviour too")
  func unknownDefaultTransportFailsOpen() {
    let spy = SnapshotSpy(.complete([candidate(7, "built-in", kAudioDeviceTransportTypeBuiltIn)]))
    let result = resolve(defaultID: 42, defaultTransport: 0, spy: spy)

    #expect(result.selectedDeviceID == 42)
    #expect(result.enumerationOutcome == .notAttempted)
  }

  @Test("a pinned virtual device is still the user's to choose")
  func pinnedVirtualDeviceIsUnaffected() {
    let spy = SnapshotSpy(
      .complete([
        candidate(60, "BlackHole2ch", kAudioDeviceTransportTypeVirtual),
        candidate(7, "built-in", kAudioDeviceTransportTypeBuiltIn),
      ]))
    let result = resolve(
      preferredUID: "BlackHole2ch", defaultID: 60,
      defaultTransport: kAudioDeviceTransportTypeVirtual, spy: spy)

    // Rung 2 is reached before any of this, and an explicit choice stays the
    // user's. This is what makes the divert above safe: the deliberate user
    // pins, so only the accidental default is rescued.
    #expect(result.selectedDeviceID == 60)
    #expect(result.resolutionSource == .pinnedUID)
  }

  @Test("a pinned device that vanished falls through a virtual default to a real microphone")
  func pinnedGoneWithVirtualDefaultDivertsToPhysical() {
    let spy = SnapshotSpy(
      .complete([
        candidate(60, "BlackHole2ch", kAudioDeviceTransportTypeVirtual),
        candidate(7, "built-in", kAudioDeviceTransportTypeBuiltIn),
      ]))
    let result = resolve(
      preferredUID: "unplugged-usb-mic", defaultID: 60,
      defaultTransport: kAudioDeviceTransportTypeVirtual, spy: spy)

    #expect(result.selectedDeviceID == 7)
    #expect(result.resolutionSource == .listFallback)
  }

  @Test("the default's transport is read at most once per resolve")
  func transportIsReadAtMostOnce() {
    // Both rungs that consult it are mutually exclusive, and the value is
    // computed once so they can never disagree about what the default IS.
    let counter = TransportReadCounter()
    let resolver = InputDeviceResolver(
      defaultInputDeviceID: { 60 },
      inputDeviceSnapshot: {
        .success(
          candidates: [
            InputDeviceCandidate(
              id: 60, uid: "virt", rawTransport: kAudioDeviceTransportTypeVirtual),
            InputDeviceCandidate(id: 7, uid: "mic", rawTransport: kAudioDeviceTransportTypeBuiltIn),
          ], complete: true)
      },
      transportForDevice: { _ in
        counter.bump()
        return kAudioDeviceTransportTypeVirtual
      })

    _ = resolver.resolve(preferredUID: nil)
    #expect(counter.count == 1)
  }

  // MARK: - Rung 2: a pinned device

  @Test("pinned UID present in the frozen snapshot wins over the system default")
  func pinnedUIDWins() {
    let spy = SnapshotSpy(
      .complete([
        candidate(10, "other", kAudioDeviceTransportTypeUSB),
        candidate(11, "wanted", kAudioDeviceTransportTypeUSB),
      ]))
    let result = resolve(preferredUID: "wanted", defaultID: 42, spy: spy)

    #expect(result.selectedDeviceID == 11)
    #expect(result.resolutionSource == .pinnedUID)
    #expect(result.selectedTransport == "usb")
    #expect(result.enumerationOutcome == .succeeded)
    #expect(result.inputDeviceCount == 2)
    #expect(spy.callCount == 1)
  }

  @Test("a deliberately pinned aggregate device is still selectable")
  func pinnedAggregateIsAllowed() {
    // The allow-list constrains the AUTOMATIC last resort only. An explicit
    // choice is the user's to make.
    let result = resolve(
      preferredUID: "my-aggregate",
      defaultID: nil,
      snapshot: .complete([
        candidate(20, "my-aggregate", kAudioDeviceTransportTypeAggregate)
      ]))

    #expect(result.selectedDeviceID == 20)
    #expect(result.resolutionSource == .pinnedUID)
    #expect(result.selectedTransport == "aggregate")
    #expect(result.eligibleDeviceCount == 0)
  }

  // MARK: - Rung 3: pinned device gone

  @Test("pinned UID absent falls through to the system default")
  func pinnedUIDAbsentFallsBackToDefault() {
    let spy = SnapshotSpy(
      .complete([
        candidate(10, "something-else", kAudioDeviceTransportTypeUSB),
        candidate(42, "system-default", kAudioDeviceTransportTypeBuiltIn),
      ]))
    let result = resolve(preferredUID: "gone", defaultID: 42, spy: spy)

    #expect(result.selectedDeviceID == 42)
    #expect(result.resolutionSource == .systemDefault)
    #expect(result.enumerationOutcome == .succeeded)
    // The snapshot is already in hand on this rung, so the default's transport
    // is reported rather than discarded.
    #expect(result.selectedTransport == "built_in")
    #expect(spy.callCount == 1)
  }

  @Test("a system default that is not itself an input candidate reports no transport")
  func defaultOutsideSnapshotHasNoTransport() {
    // Guards the lookup added above: nil means "not in the frozen list", and
    // must not be mistaken for a device we failed to classify.
    let result = resolve(
      preferredUID: "gone",
      defaultID: 999,
      snapshot: .complete([candidate(10, "something-else", kAudioDeviceTransportTypeUSB)]))

    #expect(result.selectedDeviceID == 999)
    #expect(result.resolutionSource == .systemDefault)
    #expect(result.selectedTransport == nil)
  }

  // MARK: - Rung 4: the fallback #1714 exists to add

  @Test("default absent selects the built-in microphone from the frozen list")
  func defaultAbsentSelectsBuiltIn() {
    let spy = SnapshotSpy(.complete([candidate(30, "builtin", kAudioDeviceTransportTypeBuiltIn)]))
    let result = resolve(defaultID: nil, spy: spy)

    #expect(result.selectedDeviceID == 30)
    #expect(result.resolutionSource == .listFallback)
    #expect(result.selectedTransport == "built_in")
    #expect(result.defaultPresent == false)
    #expect(result.inputDeviceCount == 1)
    #expect(result.eligibleDeviceCount == 1)
    #expect(spy.callCount == 1)
  }

  @Test("default absent selects a USB microphone when no built-in exists")
  func defaultAbsentSelectsUSB() {
    let result = resolve(
      defaultID: nil,
      snapshot: .complete([candidate(31, "usb-mic", kAudioDeviceTransportTypeUSB)]))

    #expect(result.selectedDeviceID == 31)
    #expect(result.resolutionSource == .listFallback)
    #expect(result.selectedTransport == "usb")
  }

  @Test("built-in wins over an EARLIER-listed eligible USB candidate")
  func builtInPreferredOverEarlierUSB() {
    // Ordering matters: "first eligible" alone would pick the USB device.
    let result = resolve(
      defaultID: nil,
      snapshot: .complete([
        candidate(40, "usb-mic", kAudioDeviceTransportTypeUSB),
        candidate(41, "builtin", kAudioDeviceTransportTypeBuiltIn),
      ]))

    #expect(result.selectedDeviceID == 41)
    #expect(result.selectedTransport == "built_in")
    #expect(result.eligibleDeviceCount == 2)
  }

  @Test("virtual and aggregate devices are skipped in favour of a real microphone")
  func virtualDevicesSkipped() {
    // The founder's own machine: a loopback and a meeting-app device listed
    // alongside the real microphone. Binding either records digital silence.
    let result = resolve(
      defaultID: nil,
      snapshot: .complete([
        candidate(50, "BlackHole2ch", kAudioDeviceTransportTypeVirtual),
        candidate(51, "TeamsAudio", kAudioDeviceTransportTypeVirtual),
        candidate(52, "aggregate", kAudioDeviceTransportTypeAggregate),
        candidate(53, "MacBookProMicrophone", kAudioDeviceTransportTypeBuiltIn),
      ]))

    #expect(result.selectedDeviceID == 53)
    #expect(result.inputDeviceCount == 4)
    #expect(result.eligibleDeviceCount == 1)
  }

  @Test("one unclassifiable device does not stop an eligible one being selected")
  func unclassifiableDoesNotBlockAnEligibleDevice() {
    let result = resolve(
      defaultID: nil,
      snapshot: .complete([
        candidate(80, "mystery", nil),
        candidate(81, "usb-mic", kAudioDeviceTransportTypeUSB),
      ]))

    #expect(result.selectedDeviceID == 81)
    #expect(result.resolutionSource == .listFallback)
    #expect(result.inputDeviceCount == 2)
    #expect(result.eligibleDeviceCount == 1)
  }

  // MARK: - Absence: the list PROVES there is no microphone

  @Test("successful but empty enumeration reports no microphone")
  func emptyEnumerationIsAbsence() {
    let result = resolve(defaultID: nil, snapshot: .complete([]))

    #expect(result.selectedDeviceID == nil)
    #expect(isNoMicrophoneFound(result.thrownError))
    #expect(result.enumerationOutcome == .succeeded)
    #expect(result.inputDeviceCount == 0)
    #expect(result.eligibleDeviceCount == 0)
  }

  @Test("only virtual and aggregate devices reports no microphone")
  func onlyKnownNonMicrophonesIsAbsence() {
    let result = resolve(
      defaultID: nil,
      snapshot: .complete([
        candidate(60, "BlackHole2ch", kAudioDeviceTransportTypeVirtual),
        candidate(61, "aggregate", kAudioDeviceTransportTypeAggregate),
      ]))

    #expect(isNoMicrophoneFound(result.thrownError))
    #expect(result.eligibleDeviceCount == 0)
  }

  // MARK: - Partial enumeration: one device unreadable, the rest still usable

  @Test("an unreadable device never costs the user the microphones that ARE readable")
  func partialEnumerationStillSelectsAReadableDevice() {
    // #1714 cloud review r2. A USB stick pulled mid-enumeration makes its own
    // properties unreadable; the built-in microphone beside it is untouched.
    // Refusing to dictate here would break founder priority 1.
    let result = resolve(
      defaultID: nil,
      snapshot: .partial([candidate(80, "builtin", kAudioDeviceTransportTypeBuiltIn)]))

    #expect(result.selectedDeviceID == 80)
    #expect(result.resolutionSource == .listFallback)
    #expect(result.thrownError == nil)
    #expect(result.enumerationOutcome == .succeededPartial)
  }

  @Test("an incomplete list never claims the microphone is missing")
  func partialEnumerationWithNothingLeftIsUncertaintyNotAbsence() {
    // The vacuous-truth trap: `allSatisfy` on an EMPTY array returns true, so
    // without the completeness gate an enumeration where every device failed
    // its read would produce the strongest possible claim from the weakest
    // possible evidence.
    let result = resolve(defaultID: nil, snapshot: .partial([]))

    #expect(result.selectedDeviceID == nil)
    #expect(isNoMicrophoneFound(result.thrownError) == false)
    #expect(result.enumerationOutcome == .succeededPartial)
  }

  @Test("an incomplete list of only virtual devices is still uncertainty")
  func partialEnumerationOfNonMicrophonesDoesNotProveAbsence() {
    // The same list COMPLETE proves absence (see `onlyKnownNonMicrophonesIsAbsence`).
    // Completeness is the only difference, so this pins the gate itself rather
    // than the transport classification.
    let result = resolve(
      defaultID: nil,
      snapshot: .partial([candidate(81, "BlackHole2ch", kAudioDeviceTransportTypeVirtual)]))

    #expect(isNoMicrophoneFound(result.thrownError) == false)
    #expect(result.enumerationOutcome == .succeededPartial)
  }

  @Test("a complete enumeration still reports plain succeeded")
  func completeEnumerationReportsSucceeded() {
    // Two-way control for the telemetry field: without this, a bug that marked
    // every enumeration partial would pass all three tests above while making
    // the "connect a microphone" message unreachable forever.
    let result = resolve(
      defaultID: nil,
      snapshot: .complete([candidate(82, "builtin", kAudioDeviceTransportTypeBuiltIn)]))

    #expect(result.selectedDeviceID == 82)
    #expect(result.enumerationOutcome == .succeeded)
  }

  // MARK: - Uncertainty: the list fails to prove anything

  @Test("a pinned device we cannot look up swaps to auto rather than aborting the take")
  func readFailureWithDefaultStillRecords() {
    // Founder decision 2026-07-30: dead AirPods, out of range, unplugged, or a
    // device list we could not even read all mean the same thing to the user —
    // the device they picked is not there — and that has always swapped to
    // auto. Aborting here would make a working case worse.
    let result = resolve(preferredUID: "airpods", defaultID: 42, snapshot: .readFailed)

    #expect(result.selectedDeviceID == 42)
    #expect(result.resolutionSource == .systemDefault)
    #expect(result.thrownError == nil)
    // The failure is still reported, it just does not stop the recording.
    #expect(result.enumerationOutcome == .readFailed)
    #expect(result.defaultPresent)
  }

  @Test("device-list read failure with NO default reports a generic capture error")
  func readFailureIsUncertainty() {
    let result = resolve(defaultID: nil, snapshot: .readFailed)

    #expect(result.selectedDeviceID == nil)
    #expect(diagnosticSource(result.thrownError) == "InputDeviceResolver.enumerate_input_devices")
    #expect(isNoMicrophoneFound(result.thrownError) == false)
    #expect(result.enumerationOutcome == .readFailed)
    // Counts are unknown, not zero — reporting 0 would read as an empty machine.
    #expect(result.inputDeviceCount == nil)
    #expect(result.eligibleDeviceCount == nil)
  }

  @Test("an unreadable transport with no eligible device reports a generic capture error")
  func unreadableTransportIsUncertainty() {
    let result = resolve(
      defaultID: nil,
      snapshot: .complete([candidate(70, "mystery", nil)]))

    #expect(
      diagnosticSource(result.thrownError) == "InputDeviceResolver.unclassifiable_input_transport")
    #expect(isNoMicrophoneFound(result.thrownError) == false)
  }

  @Test("transport 0 (unknown) with no eligible device reports a generic capture error")
  func unknownTransportIsUncertainty() {
    let result = resolve(
      defaultID: nil,
      snapshot: .complete([candidate(71, "unknown", kAudioDeviceTransportTypeUnknown)]))

    #expect(
      diagnosticSource(result.thrownError) == "InputDeviceResolver.unclassifiable_input_transport")
  }

  @Test("a future unrecognised transport with no eligible device reports a generic capture error")
  func futureTransportIsUncertainty() {
    let result = resolve(
      defaultID: nil,
      snapshot: .complete([candidate(72, "future", Self.futureUnknownTransport)]))

    #expect(
      diagnosticSource(result.thrownError) == "InputDeviceResolver.unclassifiable_input_transport")
  }

  @Test("AirPlay alone reports uncertainty, not absence")
  func airPlayIsUncertaintyNotAbsence() {
    // AirPlay is refused because it is an output protocol, not a known
    // microphone path — but refusing to trust it is not proof that no
    // microphone exists, so the user must not be told to connect one.
    let result = resolve(
      defaultID: nil,
      snapshot: .complete([candidate(73, "airplay", kAudioDeviceTransportTypeAirPlay)]))

    #expect(
      diagnosticSource(result.thrownError) == "InputDeviceResolver.unclassifiable_input_transport")
    #expect(isNoMicrophoneFound(result.thrownError) == false)
  }

  // MARK: - The allow-list itself

  @Test(
    "every approved physical transport is accepted",
    arguments: InputDeviceResolverTests.acceptedTransports)
  func approvedTransportsAccepted(_ entry: AcceptedTransport) {
    #expect(AudioDeviceEnumerator.isAllowedPhysicalInputTransport(entry.raw))

    // And end to end: a lone device on this transport is selectable.
    let result = resolve(
      defaultID: nil,
      snapshot: .complete([candidate(90, entry.name, entry.raw)]))
    #expect(result.selectedDeviceID == 90)
    #expect(result.resolutionSource == .listFallback)
  }

  @Test("every refused transport is refused, including nil and a future value")
  func refusedTransportsRefused() {
    let refused: [UInt32?] = [
      kAudioDeviceTransportTypeVirtual,
      kAudioDeviceTransportTypeAggregate,
      kAudioDeviceTransportTypeUnknown,
      kAudioDeviceTransportTypeAirPlay,
      Self.futureUnknownTransport,
      nil,
    ]
    for raw in refused {
      #expect(AudioDeviceEnumerator.isAllowedPhysicalInputTransport(raw) == false)
    }
  }

  @Test("only virtual and aggregate count as proof that no microphone exists")
  func absenceProofIsNarrow() {
    #expect(AudioDeviceEnumerator.isKnownNonMicrophoneTransport(kAudioDeviceTransportTypeVirtual))
    #expect(AudioDeviceEnumerator.isKnownNonMicrophoneTransport(kAudioDeviceTransportTypeAggregate))

    // Everything else fails the allow-list without proving absence.
    for raw: UInt32? in [
      kAudioDeviceTransportTypeUnknown,
      kAudioDeviceTransportTypeAirPlay,
      Self.futureUnknownTransport,
      nil,
    ] {
      #expect(AudioDeviceEnumerator.isKnownNonMicrophoneTransport(raw) == false)
    }

    // A transport we DO accept is obviously not proof of absence either.
    #expect(
      AudioDeviceEnumerator.isKnownNonMicrophoneTransport(kAudioDeviceTransportTypeBuiltIn) == false
    )
  }

  // MARK: - The one-enumeration guarantee

  @Test("every path that enumerates does so at most once")
  func enumeratesAtMostOnce() {
    let snapshots: [InputDeviceSnapshot] = [
      .readFailed,
      .complete([]),
      .complete([candidate(100, "builtin", kAudioDeviceTransportTypeBuiltIn)]),
      .complete([candidate(101, "virtual", kAudioDeviceTransportTypeVirtual)]),
      .complete([candidate(102, "mystery", nil)]),
    ]
    var enumeratedAtLeastOnce = false
    for snapshot in snapshots {
      for preferred in [nil, "pinned"] as [String?] {
        for defaultID in [nil, 42] as [AudioDeviceID?] {
          let spy = SnapshotSpy(snapshot)
          _ = resolve(preferredUID: preferred, defaultID: defaultID, spy: spy)
          #expect(spy.callCount <= 1)
          if spy.callCount == 1 { enumeratedAtLeastOnce = true }
        }
      }
    }
    // Guards against a vacuous pass: if nothing ever enumerated, `<= 1` would
    // hold trivially and prove nothing.
    #expect(enumeratedAtLeastOnce)
  }

  // MARK: - Warm-bind compatibility (#1714)
  //
  // Three of these are the behaviours that used to live in
  // `HALDeviceInputSourceDeviceTargetTests` against `resolvedDeviceIDForTesting()`.
  // They are the resolver's behaviours now, so they moved with the authority
  // rather than being deleted with the seam.

  private func bind(_ id: AudioDeviceID, _ source: InputResolutionSource) -> BoundInputDevice {
    BoundInputDevice(
      deviceID: id, deviceUID: "uid-\(id)", transportLabel: "built_in",
      resolutionSource: source.rawValue)
  }

  private func warmCompatible(
    _ bound: BoundInputDevice,
    preferredUID: String? = nil,
    defaultID: AudioDeviceID?,
    spy: SnapshotSpy
  ) -> Bool {
    InputDeviceResolver(
      defaultInputDeviceID: { defaultID },
      inputDeviceSnapshot: { spy.provide() }
    ).isWarmBindCompatible(bound, preferredUID: preferredUID)
  }

  // MIGRATED: "nil target resolves to current system default input".
  @Test("Auto: a bind on the current default stays compatible, and never enumerates")
  func warmAutoMatchesDefault() {
    let spy = SnapshotSpy(.complete([candidate(1, "anything", kAudioDeviceTransportTypeUSB)]))

    #expect(warmCompatible(bind(42, .systemDefault), defaultID: 42, spy: spy))
    #expect(spy.callCount == 0, "Auto must answer from the default alone")
  }

  // MIGRATED: the stale-default half of the old Auto reuse pair.
  @Test("Auto: a bind on a stale default is rejected")
  func warmAutoRejectsStaleDefault() {
    let spy = SnapshotSpy(.complete([]))

    #expect(!warmCompatible(bind(42, .systemDefault), defaultID: 43, spy: spy))
    #expect(spy.callCount == 0)
  }

  // MIGRATED: "resolvable target wins over system default input".
  @Test("Pinned: a bind on the pinned device stays compatible")
  func warmPinnedMatches() {
    let spy = SnapshotSpy(
      .complete([candidate(99, "present", kAudioDeviceTransportTypeUSB)]))

    #expect(
      warmCompatible(bind(99, .pinnedUID), preferredUID: "present", defaultID: 42, spy: spy))
    #expect(spy.callCount == 1, "pinned compatibility reads at most one snapshot")
  }

  @Test("Pinned: a RECONNECTED pinned device rejects a fallback bind (founder decision)")
  func warmPinnedReconnectRejectsFallback() {
    // The founder's rule forwards: the chosen mic is back, so it takes the take
    // back. Rejecting here is what forces the next open to be cold and pinned.
    let spy = SnapshotSpy(
      .complete([candidate(77, "airpods", kAudioDeviceTransportTypeBluetooth)]))

    #expect(
      !warmCompatible(
        bind(30, .listFallback), preferredUID: "airpods", defaultID: nil, spy: spy))
  }

  // MIGRATED: "unresolvable target falls back to current system default input".
  @Test("Pinned but absent: compatibility falls through to the current default")
  func warmPinnedAbsentTracksDefault() {
    let spy = SnapshotSpy(
      .complete([candidate(1, "something-else", kAudioDeviceTransportTypeUSB)]))

    #expect(
      warmCompatible(bind(42, .systemDefault), preferredUID: "gone", defaultID: 42, spy: spy))

    let spy2 = SnapshotSpy(
      .complete([candidate(1, "something-else", kAudioDeviceTransportTypeUSB)]))
    #expect(
      !warmCompatible(bind(42, .systemDefault), preferredUID: "gone", defaultID: 43, spy: spy2))
  }

  @Test("Auto with no default: only a list_fallback bind survives")
  func warmAutoNoDefaultKeepsFallbackOnly() {
    let spy = SnapshotSpy(.complete([]))
    #expect(warmCompatible(bind(30, .listFallback), defaultID: nil, spy: spy))
    #expect(spy.callCount == 0)

    // A bind that came from a since-vanished default is NOT made correct by the
    // default vanishing. Only a bind chosen BECAUSE none existed still holds.
    let spy2 = SnapshotSpy(.complete([]))
    #expect(!warmCompatible(bind(30, .systemDefault), defaultID: nil, spy: spy2))

    let spy3 = SnapshotSpy(.complete([]))
    #expect(!warmCompatible(bind(30, .pinnedUID), defaultID: nil, spy: spy3))
  }

  @Test("Pinned absent with no default: a list_fallback bind survives")
  func warmPinnedAbsentNoDefaultKeepsFallback() {
    let spy = SnapshotSpy(
      .complete([candidate(1, "something-else", kAudioDeviceTransportTypeUSB)]))

    #expect(
      warmCompatible(
        bind(30, .listFallback), preferredUID: "airpods", defaultID: nil, spy: spy))
    #expect(spy.callCount == 1)
  }

  @Test("Pinned with a FAILED snapshot: the pinned device has not been shown to return")
  func warmPinnedSnapshotFailureIsConservative() {
    // A failed read is not evidence the device came back, so it must not evict
    // a working fallback bind — that would rebuild the engine on a read error.
    let spy = SnapshotSpy(.readFailed)
    #expect(
      warmCompatible(
        bind(30, .listFallback), preferredUID: "airpods", defaultID: nil, spy: spy))

    // With a default present, it falls through to the same question Auto asks.
    let spy2 = SnapshotSpy(.readFailed)
    #expect(
      warmCompatible(
        bind(42, .systemDefault), preferredUID: "airpods", defaultID: 42, spy: spy2))
  }

  @Test("warm compatibility never runs the physical fallback ranking")
  func warmCompatibilityNeverRanks() {
    // A snapshot holding an eligible built-in mic must NOT make an incompatible
    // bind compatible. Ranking belongs to cold opens only.
    let spy = SnapshotSpy(
      .complete([
        candidate(55, "builtin", kAudioDeviceTransportTypeBuiltIn),
        candidate(56, "usb", kAudioDeviceTransportTypeUSB),
      ]))

    #expect(
      !warmCompatible(
        bind(30, .systemDefault), preferredUID: "airpods", defaultID: nil, spy: spy))
  }

  // MARK: - The per-device failure-vs-empty distinction (whole-diff review)

  @Test("a snapshot that FAILED per-device reads never reaches the no-microphone sentence")
  func perDeviceReadFailureIsUncertainty() {
    // Found by the independent whole-diff review. `inputChannelCount(for:)`
    // returns 0 for BOTH "this device has no input streams" and "the property
    // read failed", so a device whose read failed used to be dropped silently.
    // If it were the only microphone, the snapshot came back SUCCESSFULLY EMPTY
    // and this resolver would call that proof of absence — the same
    // failure-vs-empty conflation the snapshot type exists to prevent, one level
    // down. The enumerator now returns `.readFailed` instead, which lands here.
    let result = resolve(defaultID: nil, snapshot: .readFailed)

    #expect(
      isNoMicrophoneFound(result.thrownError) == false, "never claim absence on a failed read")
    #expect(diagnosticSource(result.thrownError) == "InputDeviceResolver.enumerate_input_devices")
    #expect(result.enumerationOutcome == .readFailed)
    // Counts stay unknown rather than zero: 0 would read as an empty machine.
    #expect(result.inputDeviceCount == nil)
    #expect(result.eligibleDeviceCount == nil)
  }

  // MARK: - Error identity helpers

  private func isNoMicrophoneFound(_ error: AudioError?) -> Bool {
    if case .noBuiltInMicrophoneFound = error { return true }
    return false
  }

  private func diagnosticSource(_ error: AudioError?) -> String? {
    error?.diagnosticSource
  }
}
