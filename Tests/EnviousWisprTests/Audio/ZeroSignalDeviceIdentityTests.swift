import CoreAudio
import Testing

@testable import EnviousWisprAudio

// #1844: the shared zero-signal discriminator must confirm the bound device is
// STILL the device it was at bind time before trusting anything CoreAudio says
// about it. An `AudioDeviceID` is a runtime handle CoreAudio may reuse after a
// replug, so a numeric match is not physical identity — asking a recycled id
// whether it is alive would answer about the WRONG microphone.
//
// Every hardware read is injected, so no case depends on which microphones this
// machine happens to have. That is deliberate: this repo has been bitten twice
// by unseamed `AudioDeviceEnumerator` calls in tests (#1444, #1531).
//
// The positive control is mandatory and comes first. Without it, a guard that
// refused EVERYTHING would satisfy all seven negative cases while silently
// disabling the feature (`a-guard-nothing-arms-is-not-a-guard`).
@Suite("ZeroSignalDeviceDiscriminator identity matrix — #1844")
struct ZeroSignalDeviceIdentityTests {

  /// The bind as committed by a successful `prepare()`. Transport is carried even
  /// though it plays no part in eligibility, so the fixture is the same SHAPE
  /// production hands to the discriminator rather than a trimmed-down stand-in.
  private static let bound = BoundInputDevice(
    deviceID: 121,
    deviceUID: "BC-87-FA-9C-7E-71:input",
    transportLabel: "bluetooth"
  )

  /// Counts hardware classifications so a test can prove a guard short-circuited
  /// BEFORE consulting them, rather than merely returning the right boolean.
  private final class ReadCounter {
    var uidCalls = 0
    var livenessCalls = 0
    var muteCalls = 0
  }

  /// Every input eligible unless a case overrides exactly one of them.
  private static func evaluate(
    bound: BoundInputDevice = Self.bound,
    uidNow: String?? = nil,  // outer nil = "unchanged"; inner nil = lookup failed
    liveness: DeviceLiveness = .alive,
    muteState: DeviceMuteState = .unmuted,
    counter: ReadCounter = ReadCounter()
  ) -> Bool {
    ZeroSignalDeviceDiscriminator.isEligible(
      bound: bound,
      inputDeviceUID: Self.uidReader(bound: bound, uidNow: uidNow, counter: counter),
      liveness: Self.livenessReader(liveness, counter),
      muteState: Self.muteReader(muteState, counter))
  }

  /// #1578: the reason-bearing form of `evaluate`, driving the SAME injected
  /// implementation the Boolean wrapper now delegates to — no second classifier
  /// is reconstructed here.
  private static func classify(
    bound: BoundInputDevice? = Self.bound,
    uidNow: String?? = nil,
    liveness: DeviceLiveness = .alive,
    muteState: DeviceMuteState = .unmuted,
    counter: ReadCounter = ReadCounter()
  ) -> ZeroSignalEligibility {
    ZeroSignalDeviceDiscriminator.classify(
      bound: bound,
      inputDeviceUID: Self.uidReader(bound: bound, uidNow: uidNow, counter: counter),
      liveness: Self.livenessReader(liveness, counter),
      muteState: Self.muteReader(muteState, counter))
  }

  // Default the "UID now" from the bind UNDER TEST, not the shared fixture, so a
  // case supplying its own non-nil bind cannot silently be compared against the
  // wrong identity.
  private static func uidReader(
    bound: BoundInputDevice?, uidNow: String??, counter: ReadCounter
  ) -> (AudioDeviceID) -> String? {
    let resolvedUID: String? = uidNow ?? bound?.deviceUID
    return { _ in
      counter.uidCalls += 1
      return resolvedUID
    }
  }

  private static func livenessReader(
    _ liveness: DeviceLiveness, _ counter: ReadCounter
  ) -> (AudioDeviceID) -> DeviceLiveness {
    { _ in
      counter.livenessCalls += 1
      return liveness
    }
  }

  private static func muteReader(
    _ muteState: DeviceMuteState, _ counter: ReadCounter
  ) -> (AudioDeviceID) -> DeviceMuteState {
    { _ in
      counter.muteCalls += 1
      return muteState
    }
  }

  // MARK: - 1. Positive control (mandatory)

  @Test("matching UID + alive + unmuted → eligible")
  func matchingUIDAliveUnmutedIsEligible() {
    #expect(Self.evaluate() == true)
    #expect(Self.classify() == .eligible)
  }

  // MARK: - 2-4. Identity failures

  @Test("changed UID for the same numeric id → refused (the recycled-handle case)")
  func changedUIDRefuses() {
    let counter = ReadCounter()

    // Same deviceID 121, but it now resolves to a DIFFERENT physical device.
    let eligible = Self.evaluate(uidNow: .some("00-11-22-33-44-55:input"), counter: counter)

    #expect(eligible == false)
    // Refusal must precede the hardware questions: asking a recycled id about
    // liveness is asking about the wrong microphone.
    #expect(counter.livenessCalls == 0, "liveness consulted despite a UID mismatch")
    #expect(counter.muteCalls == 0, "mute consulted despite a UID mismatch")
    #expect(Self.classify(uidNow: .some("00-11-22-33-44-55:input")) == .identityMismatch)
  }

  @Test("UID unknown at bind time → refused, fails closed")
  func nilUIDAtBindRefuses() {
    let counter = ReadCounter()
    let bindWithoutUID = BoundInputDevice(
      deviceID: 121, deviceUID: nil, transportLabel: "bluetooth")

    let eligible = Self.evaluate(bound: bindWithoutUID, counter: counter)

    #expect(eligible == false)
    #expect(counter.livenessCalls == 0, "liveness consulted despite no bind-time UID")
    #expect(counter.muteCalls == 0, "mute consulted despite no bind-time UID")
    // An unknown bind UID is an IDENTITY answer, not a missing bind: the bind
    // itself exists, we simply cannot prove it still names the same microphone.
    #expect(Self.classify(bound: bindWithoutUID) == .identityMismatch)
  }

  @Test("UID lookup fails now → refused, fails closed")
  func failedUIDLookupRefuses() {
    let counter = ReadCounter()

    // The device's UID can no longer be read at all — unknown, not "unchanged".
    let eligible = Self.evaluate(uidNow: .some(nil), counter: counter)

    #expect(eligible == false)
    #expect(counter.livenessCalls == 0, "liveness consulted despite an unreadable UID")
    #expect(counter.muteCalls == 0, "mute consulted despite an unreadable UID")
    #expect(Self.classify(uidNow: .some(nil)) == .identityMismatch)
  }

  // MARK: - 5-6. Liveness failures

  @Test("device removed → refused")
  func removedDeviceRefuses() {
    #expect(Self.evaluate(liveness: .removed) == false)
    #expect(Self.classify(liveness: .removed) == .notAlive)
  }

  @Test("liveness unverified → refused, never read as alive")
  func unverifiedLivenessRefuses() {
    #expect(Self.evaluate(liveness: .unverified) == false)
    #expect(Self.classify(liveness: .unverified) == .notAlive)
  }

  // MARK: - 7-8. Mute failures

  @Test("device muted → refused (a muted mic zero-fills by design)")
  func mutedDeviceRefuses() {
    #expect(Self.evaluate(muteState: .muted) == false)
    #expect(Self.classify(muteState: .muted) == .deviceMuted)
  }

  @Test("mute unverified → refused, never read as unmuted")
  func unverifiedMuteRefuses() {
    #expect(Self.evaluate(muteState: .unverified) == false)
    #expect(Self.classify(muteState: .unverified) == .muteUnverified)
  }

  // MARK: - 9. #1578 — the reason set itself

  /// The closed set is the contract §3a's metric definition reads. A silently
  /// added or renamed case would change what every dashboard row means, so the
  /// exact membership AND the exact wire values are frozen here.
  @Test("#1578: the eligibility reason set is exactly these six cases and raw values")
  func eligibilityCaseSetIsFrozen() {
    #expect(
      ZeroSignalEligibility.allCases == [
        .eligible, .boundDeviceUnavailable, .identityMismatch,
        .notAlive, .deviceMuted, .muteUnverified,
      ])
    #expect(
      ZeroSignalEligibility.allCases.map(\.rawValue) == [
        "eligible", "bound_device_unavailable", "identity_mismatch",
        "not_alive", "device_muted", "mute_unverified",
      ])
  }

  @Test("#1578: a missing frozen bind classifies as boundDeviceUnavailable, reading nothing")
  func missingBindClassifiesWithoutReadingHardware() {
    let counter = ReadCounter()

    let reason = Self.classify(bound: nil, counter: counter)

    #expect(reason == .boundDeviceUnavailable)
    // It must not lie as identity mismatch, mute-unverified, or eligible — and
    // it must not consult CoreAudio about a device it does not have.
    #expect(counter.uidCalls == 0, "UID consulted despite no frozen bind")
    #expect(counter.livenessCalls == 0, "liveness consulted despite no frozen bind")
    #expect(counter.muteCalls == 0, "mute consulted despite no frozen bind")
  }

  // MARK: - 10. #1578 — precedence and wrapper equivalence

  /// Identity beats liveness beats mute. Asserted with read counters rather than
  /// return values alone: a classifier that returned the right reason while
  /// still questioning a recycled handle would pass a value-only test.
  @Test("#1578: precedence is identity → liveness → mute, each short-circuiting")
  func precedenceShortCircuitsInOrder() {
    // All three unhealthy at once: identity must win and nothing below runs.
    let identityFirst = ReadCounter()
    #expect(
      Self.classify(
        uidNow: .some("00-11-22-33-44-55:input"), liveness: .removed, muteState: .muted,
        counter: identityFirst) == .identityMismatch)
    #expect(identityFirst.livenessCalls == 0)
    #expect(identityFirst.muteCalls == 0)

    // Identity healthy, liveness and mute both unhealthy: liveness wins and the
    // mute read never happens.
    let livenessSecond = ReadCounter()
    #expect(
      Self.classify(liveness: .removed, muteState: .muted, counter: livenessSecond) == .notAlive)
    #expect(livenessSecond.livenessCalls == 1)
    #expect(livenessSecond.muteCalls == 0, "mute consulted despite a non-alive device")

    // Only mute unhealthy: the mute read is reached and decides.
    let muteLast = ReadCounter()
    #expect(Self.classify(muteState: .muted, counter: muteLast) == .deviceMuted)
    #expect(muteLast.livenessCalls == 1)
    #expect(muteLast.muteCalls == 1)
  }

  /// The Boolean wrapper is retained for direct callers, so it must stay exactly
  /// `classify(...) == .eligible` for every reachable non-nil outcome — including
  /// the healthy one, or an always-false wrapper would satisfy the refusals alone.
  @Test("#1578: isEligible equals classify == .eligible for every non-nil outcome")
  func booleanWrapperMatchesClassificationForEveryOutcome() {
    let bindWithoutUID = BoundInputDevice(
      deviceID: 121, deviceUID: nil, transportLabel: "bluetooth")

    // (bind, uidNow, liveness, mute) → the outcome each row is here to cover.
    let rows: [(BoundInputDevice, String??, DeviceLiveness, DeviceMuteState)] = [
      (Self.bound, nil, .alive, .unmuted),  // eligible
      (Self.bound, .some("00-11-22-33-44-55:input"), .alive, .unmuted),  // identityMismatch
      (bindWithoutUID, nil, .alive, .unmuted),  // identityMismatch
      (Self.bound, .some(nil), .alive, .unmuted),  // identityMismatch
      (Self.bound, nil, .removed, .unmuted),  // notAlive
      (Self.bound, nil, .unverified, .unmuted),  // notAlive
      (Self.bound, nil, .alive, .muted),  // deviceMuted
      (Self.bound, nil, .alive, .unverified),  // muteUnverified
    ]

    var observed: Set<ZeroSignalEligibility> = []
    for (bind, uidNow, liveness, muteState) in rows {
      let reason = Self.classify(
        bound: bind, uidNow: uidNow, liveness: liveness, muteState: muteState)
      let boolean = Self.evaluate(
        bound: bind, uidNow: uidNow, liveness: liveness, muteState: muteState)
      #expect(boolean == (reason == .eligible), "wrapper disagreed with \(reason)")
      observed.insert(reason)
    }

    // Every case except the nil-bind one — which `isEligible` structurally cannot
    // reach, since it takes a non-optional bind — is exercised above.
    #expect(observed == Set(ZeroSignalEligibility.allCases).subtracting([.boundDeviceUnavailable]))
  }
}
