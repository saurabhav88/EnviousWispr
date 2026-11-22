@preconcurrency import AVFoundation
import EnviousWisprAudio
import EnviousWisprCore
import Foundation
import Testing

// #1578: the stop-time refusal payload and decision snapshot value types.
//
// Deliberately a plain `import`, not `@testable`: both structures are PUBLIC
// surface the Pipeline and AppKit modules consume, so the test exercises them
// exactly as a cross-module caller would. A `@testable` import would hide a
// missing `public`.
@MainActor
@Suite("#1578 zero-signal refusal conduit — value types + conformer defaults")
struct AudioCaptureInterfaceZeroSignalDefaultsTests {

  // MARK: - The two value types

  @Test("refusal context preserves every field, and equality sees a changed one")
  func refusalContextRoundTripsAndComparesByValue() {
    let ctx = ZeroSignalRefusalContext(
      sessionID: 7,
      reason: .deviceMuted,
      transport: "usb",
      failureShape: .becameZeroMidCapture)

    #expect(ctx.sessionID == 7)
    #expect(ctx.reason == .deviceMuted)
    #expect(ctx.transport == "usb")
    #expect(ctx.failureShape == .becameZeroMidCapture)

    // Identical input compares equal — without this, the four inequality
    // assertions below would pass for a type that considered nothing equal.
    #expect(
      ctx
        == ZeroSignalRefusalContext(
          sessionID: 7, reason: .deviceMuted, transport: "usb",
          failureShape: .becameZeroMidCapture))

    // Each field participates: a dashboard that groups by reason × transport ×
    // shape depends on all four being carried, not just the reason.
    #expect(
      ctx
        != ZeroSignalRefusalContext(
          sessionID: 8, reason: .deviceMuted, transport: "usb",
          failureShape: .becameZeroMidCapture))
    #expect(
      ctx
        != ZeroSignalRefusalContext(
          sessionID: 7, reason: .muteUnverified, transport: "usb",
          failureShape: .becameZeroMidCapture))
    #expect(
      ctx
        != ZeroSignalRefusalContext(
          sessionID: 7, reason: .deviceMuted, transport: "bluetooth",
          failureShape: .becameZeroMidCapture))
    #expect(
      ctx
        != ZeroSignalRefusalContext(
          sessionID: 7, reason: .deviceMuted, transport: "usb",
          failureShape: .allZeroFromStart))
  }

  @Test("decision snapshot preserves eligibility, and equality sees a changed one")
  func decisionSnapshotRoundTripsAndComparesByValue() {
    let snapshot = ZeroSignalDecisionSnapshot(eligibility: .identityMismatch)

    #expect(snapshot.eligibility == .identityMismatch)
    #expect(snapshot == ZeroSignalDecisionSnapshot(eligibility: .identityMismatch))
    #expect(snapshot != ZeroSignalDecisionSnapshot(eligibility: .notAlive))
  }
}
