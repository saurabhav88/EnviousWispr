import Foundation
import Testing

@testable import EnviousWisprAudio

// #1174 A3 — locks the XPC-boundary host-cause remap (Codex PR-5b r1 finding 2).
// In XPC mode the audio service relays interruptions through one no-cause-typed
// channel; the host collapses every LOSS cause to `.engineLost` (none has another
// owner across the boundary) and preserves ONLY the non-loss max-duration cap so
// it stays suppressed exactly as direct mode does. Unknown / legacy raw values
// fail toward visibility (`.engineLost`).
@Suite("EngineInterruptionCause XPC host remap")
struct EngineInterruptionCauseTests {

  @Test("max-duration is the only relayed cause the host preserves (suppress)")
  func maxDurationPreserved() {
    #expect(
      EngineInterruptionCause.hostCause(forRelayedRawValue: "max_duration_reached")
        == .maxDurationReached)
  }

  @Test("every loss cause collapses to .engineLost across XPC (capture)")
  func lossesCollapseToEngineLost() {
    #expect(
      EngineInterruptionCause.hostCause(forRelayedRawValue: "engine_lost") == .engineLost)
    // An XPC-mode AVCaptureSession interruption has no capture-session relay, so
    // it must be captured here — not suppressed as it would be in direct mode.
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
