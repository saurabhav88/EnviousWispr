import Foundation
import Testing

@testable import EnviousWisprAudio

// #1174 A3 — locks the XPC-boundary host-cause remap (Codex PR-5b r1 finding 2).
// In XPC mode the audio service relays interruptions through one no-cause-typed
// channel; the host preserves `.deviceRemoved` (#1408 — the helper ran the
// liveness check, the host cannot re-run it) and collapses every other loss
// cause to `.engineLost` (none has another owner across the boundary). Unknown /
// legacy raw values fail toward visibility (`.engineLost`) — including two
// RETIRED wire values: `max_duration_reached` (#1408 A3: the cap is a normal
// auto-stop and left the interruption channel entirely) and
// `capture_session_lost` (#1524: the capture-session backend was deleted).
// The wire is a string and outlives the symbols that produced it, so both
// retired values are still asserted here.
@Suite("EngineInterruptionCause XPC host remap")
struct EngineInterruptionCauseTests {

  @Test("device removal is the only relayed cause the host preserves")
  func deviceRemovalPreserved() {
    #expect(
      EngineInterruptionCause.hostCause(forRelayedRawValue: "device_removed")
        == .deviceRemoved)
  }

  /// #1408 A3 adversarial row: the RETIRED raw value must not resurrect the
  /// cap as an interruption — a stale helper relaying it reads as an unknown
  /// and fails toward visibility like any other legacy value.
  @Test("the retired max_duration_reached raw value maps to .engineLost")
  func retiredMaxDurationRawValueIsLegacy() {
    #expect(
      EngineInterruptionCause.hostCause(forRelayedRawValue: "max_duration_reached")
        == .engineLost)
  }

  @Test("every loss cause collapses to .engineLost across XPC (capture)")
  func lossesCollapseToEngineLost() {
    #expect(
      EngineInterruptionCause.hostCause(forRelayedRawValue: "engine_lost") == .engineLost)
    // RETIRED wire value (#1524). The case is gone from the enum, so this string
    // no longer resolves and lands on the same `?? .engineLost` fallback it used
    // to reach through the switch — behaviour is unchanged. THIS ASSERTION IS THE
    // PROOF that deleting the case was behaviour-preserving; it passed before the
    // deletion and passes after it. Do not remove it, and do not "clean up" the
    // nil-coalescing in `hostCause`: retiring the case INCREASED its load.
    #expect(
      EngineInterruptionCause.hostCause(forRelayedRawValue: "capture_session_lost") == .engineLost)
    #expect(
      EngineInterruptionCause.hostCause(forRelayedRawValue: "xpc_connection_lost") == .engineLost)
  }

  @Test("unknown / legacy raw values default to .engineLost (fail toward visibility)")
  func unknownDefaultsToEngineLost() {
    #expect(EngineInterruptionCause.hostCause(forRelayedRawValue: "") == .engineLost)
    #expect(EngineInterruptionCause.hostCause(forRelayedRawValue: "garbage") == .engineLost)
  }

  @Test("every raw value round-trips through its rawValue (relay contract)")
  func rawValuesRoundTrip() {
    for cause in EngineInterruptionCause.allCases {
      #expect(EngineInterruptionCause(rawValue: cause.rawValue) == cause)
    }
  }
}
