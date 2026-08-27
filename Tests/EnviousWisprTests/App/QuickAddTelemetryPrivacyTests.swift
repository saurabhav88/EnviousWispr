import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #2381 — the selected word never reaches a vendor.
///
/// When this fails, a word someone dictated leaves their Mac. `CLAUDE.md` puts the privacy boundary
/// at the NETWORK and the test is whether USER CONTENT crosses it — so this asserts on the payload
/// that would actually be sent, not on the code that builds it.
///
/// **The hook is DERIVED from the real property dictionary, not rebuilt beside it.** That is the
/// #1987 lesson and it is load-bearing here: a projection assembled independently lets a test assert
/// a property the shipped event does not carry, and worse, an added non-String value would reach
/// PostHog while a string-only hook silently dropped it — leaving a test named "no raw word" green.
/// Every typed bucket is checked below for that reason.
#if DEBUG

  @MainActor
  @Suite("Quick Add telemetry carries shape, never content — #2381", .tags(.observabilityContract))
  struct QuickAddTelemetryPrivacyTests {

    /// The word a user selected. Distinctive on purpose: a substring search for it must be able to
    /// fail loudly rather than collide with an ordinary token.
    private static let secret = "zzsecretwordzz"

    /// A reference box, because `testEventHook` is `@Sendable` and cannot mutate a captured local.
    /// It fires synchronously on the emitting actor.
    private final class EventBox: @unchecked Sendable {
      var events: [CapturedTelemetryEvent] = []
    }

    private func captureEvents(_ body: () -> Void) -> [CapturedTelemetryEvent] {
      let box = EventBox()
      TelemetryService.shared.testEventHook = { box.events.append($0) }
      defer { TelemetryService.shared.testEventHook = nil }
      body()
      return box.events
    }

    /// Every value in an event, across all four typed buckets, as strings.
    ///
    /// Projecting only `stringProps` is how a leak becomes invisible: a word smuggled in as any other
    /// type would pass a string-only sweep while still reaching the vendor.
    private func allValues(_ event: CapturedTelemetryEvent) -> [String] {
      event.stringProps.values.map { $0 }
        + event.intProps.values.map { "\($0)" }
        + event.doubleProps.values.map { "\($0)" }
        + event.boolProps.values.map { "\($0)" }
    }

    @Test("The opened event carries the word's LENGTH and never the word")
    func openedCarriesLengthNotContent() throws {
      let events = captureEvents {
        TelemetryService.shared.quickAddOpened(
          door: "hotkey", hadSelection: true, refuseReason: nil, candidateCount: 3,
          preselected: true, topScore: 0.8631, sourceBundleID: "com.apple.TextEdit",
          heardLength: Self.secret.unicodeScalars.count,
          acquired: "copy", acquisitionMilliseconds: 41, clipboardRestore: "restored")
      }

      let event = try #require(events.first { $0.name == "quick_add.opened" })
      for value in allValues(event) {
        #expect(!value.contains(Self.secret), "the selected word reached PostHog in: \(value)")
      }
      #expect(event.intProps["heard_length"] == Self.secret.unicodeScalars.count)
    }

    @Test("The resolved event carries no content either")
    func resolvedCarriesNoContent() throws {
      let events = captureEvents {
        TelemetryService.shared.quickAddResolved(
          outcome: "accepted", usedSearch: true, candidateRank: 0, targetKind: "user_word",
          elapsedMilliseconds: 1200)
      }

      let event = try #require(events.first { $0.name == "quick_add.resolved" })
      for value in allValues(event) {
        #expect(!value.contains(Self.secret))
      }
    }

    @Test("The source app's bundle id IS sent, and that is the decision not an oversight")
    func theBundleIDIsSent() throws {
      // Resolved against the rules rather than escalated: the boundary is the network and the test is
      // whether USER CONTENT crosses it. A bundle id names an APP, not anything the user wrote, and the
      // delivery path already sends one. Without it, "which apps is this used in" is unanswerable, and
      // that is the question that decides whether terminals are worth revisiting.
      let events = captureEvents {
        TelemetryService.shared.quickAddOpened(
          door: "service", hadSelection: true, refuseReason: nil, candidateCount: 1,
          preselected: false, topScore: 0.4, sourceBundleID: "com.apple.TextEdit", heardLength: 6,
          acquired: "copy", acquisitionMilliseconds: 41, clipboardRestore: "restored")
      }

      let event = try #require(events.first)
      #expect(event.stringProps["source_bundle_id"] == "com.apple.TextEdit")
    }

    @Test("An unknown app and an absent score are named, not omitted")
    func absentValuesAreNamed() throws {
      // A missing property and a property meaning "none" are different facts, and a consumer cannot
      // tell them apart after the fact. `top_score` is genuinely absent when nothing was ranked.
      let events = captureEvents {
        TelemetryService.shared.quickAddOpened(
          door: "hotkey", hadSelection: false, refuseReason: "selection_unavailable",
          candidateCount: 0, preselected: false, topScore: nil, sourceBundleID: nil, heardLength: 0,
          acquired: "copy", acquisitionMilliseconds: 41, clipboardRestore: "restored")
      }

      let event = try #require(events.first)
      #expect(event.stringProps["source_bundle_id"] == "unknown")
      #expect(event.stringProps["refuse_reason"] == "selection_unavailable")
      #expect(event.doubleProps["top_score"] == nil, "nothing was ranked, so there is no score")
    }

    @Test("A successful read reports no refusal reason rather than omitting the field")
    func aSuccessfulReadNamesNoReason() throws {
      let events = captureEvents {
        TelemetryService.shared.quickAddOpened(
          door: "hotkey", hadSelection: true, refuseReason: nil, candidateCount: 2,
          preselected: true, topScore: 0.9, sourceBundleID: "com.apple.TextEdit", heardLength: 6,
          acquired: "copy", acquisitionMilliseconds: 41, clipboardRestore: "restored")
      }

      #expect(try #require(events.first).stringProps["refuse_reason"] == "none")
    }

    @Test("The score ships as a real number, rounded but not bucketed")
    func theScoreShipsRaw() throws {
      // Bucketing would destroy the only signal that says whether the confidence bar is set right,
      // which is the number this feature will actually be tuned on. Two decimals is the resolution the
      // sweep was reported at.
      let events = captureEvents {
        TelemetryService.shared.quickAddOpened(
          door: "hotkey", hadSelection: true, refuseReason: nil, candidateCount: 3,
          preselected: true, topScore: 0.8631, sourceBundleID: "com.apple.TextEdit", heardLength: 6,
          acquired: "copy", acquisitionMilliseconds: 41, clipboardRestore: "restored")
      }

      #expect(try #require(events.first).doubleProps["top_score"] == 0.86)
    }
  }

#endif
