@preconcurrency import AVFoundation
import EnviousWisprAudio
import EnviousWisprCore
import Foundation
import Testing

// #1578: the refusal conduit's value types and its source-compatibility
// contract for conformers that have no reactive detector.
//
// Deliberately a plain `import`, not `@testable`: the whole point of these two
// structures and four protocol members is that they are PUBLIC surface the
// Pipeline and AppKit modules consume, so the test exercises them exactly as a
// cross-module caller would. A `@testable` import would hide a missing `public`.
//
// The fixture is a PRIVATE conformer that overrides nothing, and that is
// load-bearing rather than convenient. This suite originally borrowed the shared
// `RouterTestAudioCapture`, on the reasoning that a real conformer is better
// evidence than a purpose-built stub. One chunk later that conformer legitimately
// gained a stored `onZeroSignalRefused` (the router tests need to invoke what the
// router installs), and this suite silently stopped testing the extension default
// while still claiming to — it went red on the assertion that would otherwise
// have quietly become meaningless.
//
// The lesson generalises: a test whose SUBJECT is "what a type that overrides
// nothing receives" cannot use a shared fixture, because any shared fixture may
// legitimately gain an override later. Its fixture has to be a type that by
// construction never will.
//
// This double is deliberately inert everywhere else, so an assertion here can
// only be describing the protocol extension.
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

  @Test("decision snapshot preserves both fields, and equality sees a changed one")
  func decisionSnapshotRoundTripsAndComparesByValue() {
    let snapshot = ZeroSignalDecisionSnapshot(
      eligibility: .identityMismatch, currentRunWasClassifiedReactively: true)

    #expect(snapshot.eligibility == .identityMismatch)
    #expect(snapshot.currentRunWasClassifiedReactively == true)

    #expect(
      snapshot
        == ZeroSignalDecisionSnapshot(
          eligibility: .identityMismatch, currentRunWasClassifiedReactively: true))
    #expect(
      snapshot
        != ZeroSignalDecisionSnapshot(
          eligibility: .notAlive, currentRunWasClassifiedReactively: true))
    #expect(
      snapshot
        != ZeroSignalDecisionSnapshot(
          eligibility: .identityMismatch, currentRunWasClassifiedReactively: false))
  }

  // MARK: - Conformer defaults, seen through the existential

}

