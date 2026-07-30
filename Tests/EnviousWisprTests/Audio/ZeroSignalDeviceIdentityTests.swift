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
    // Default the "UID now" from the bind UNDER TEST, not the shared fixture, so a
    // case supplying its own non-nil bind cannot silently be compared against the
    // wrong identity.
    let resolvedUID: String? = uidNow ?? bound.deviceUID
    return ZeroSignalDeviceDiscriminator.isEligible(
      bound: bound,
      inputDeviceUID: { _ in resolvedUID },
      liveness: { _ in
        counter.livenessCalls += 1
        return liveness
      },
      muteState: { _ in
        counter.muteCalls += 1
        return muteState
      })
  }

  // MARK: - 1. Positive control (mandatory)

  @Test("matching UID + alive + unmuted → eligible")
  func matchingUIDAliveUnmutedIsEligible() {
    #expect(Self.evaluate() == true)
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
  }

  @Test("UID lookup fails now → refused, fails closed")
  func failedUIDLookupRefuses() {
    let counter = ReadCounter()

    // The device's UID can no longer be read at all — unknown, not "unchanged".
    let eligible = Self.evaluate(uidNow: .some(nil), counter: counter)

    #expect(eligible == false)
    #expect(counter.livenessCalls == 0, "liveness consulted despite an unreadable UID")
    #expect(counter.muteCalls == 0, "mute consulted despite an unreadable UID")
  }

  // MARK: - 5-6. Liveness failures

  @Test("device removed → refused")
  func removedDeviceRefuses() {
    #expect(Self.evaluate(liveness: .removed) == false)
  }

  @Test("liveness unverified → refused, never read as alive")
  func unverifiedLivenessRefuses() {
    #expect(Self.evaluate(liveness: .unverified) == false)
  }

  // MARK: - 7-8. Mute failures

  @Test("device muted → refused (a muted mic zero-fills by design)")
  func mutedDeviceRefuses() {
    #expect(Self.evaluate(muteState: .muted) == false)
  }

  @Test("mute unverified → refused, never read as unmuted")
  func unverifiedMuteRefuses() {
    #expect(Self.evaluate(muteState: .unverified) == false)
  }
}
