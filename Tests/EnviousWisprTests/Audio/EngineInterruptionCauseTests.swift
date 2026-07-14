import Foundation
import Testing

@testable import EnviousWisprAudio

// #1543 — with audio capture in-process, the XPC host-cause relay and the
// XPC-connection cause were deleted with the boundary. Two surviving causes
// remain (`.deviceRemoved`, `.engineLost`); this locks their classification
// contract.
@Suite("EngineInterruptionCause classification")
struct EngineInterruptionCauseTests {

  @Test("both surviving causes keep recoverable audio in-process")
  func bothCausesRecoverable() {
    // In-process the capture manager stays alive through every interruption, so
    // both causes leave `capturedSamples` salvageable.
    #expect(EngineInterruptionCause.deviceRemoved.hasRecoverableAudio)
    #expect(EngineInterruptionCause.engineLost.hasRecoverableAudio)
  }

  @Test("only a verified device removal is a device loss")
  func onlyDeviceRemovedIsDeviceLoss() {
    // Drives the "Microphone disconnected" pill + History "Interrupted" badge —
    // an unverified engine loss must not claim the mic went away.
    #expect(EngineInterruptionCause.deviceRemoved.isDeviceLoss)
    #expect(!EngineInterruptionCause.engineLost.isDeviceLoss)
  }

  @Test("every raw value round-trips through its rawValue")
  func rawValuesRoundTrip() {
    for cause in EngineInterruptionCause.allCases {
      #expect(EngineInterruptionCause(rawValue: cause.rawValue) == cause)
    }
  }
}
