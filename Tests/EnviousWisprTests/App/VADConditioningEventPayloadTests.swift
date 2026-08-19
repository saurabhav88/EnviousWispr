import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprServices

/// The ACTUAL emitted `dictation.terminal` payload for #2184's conditioning
/// dimensions.
///
/// `VADConditioningTerminalTelemetryTests` proves the kernel decides the values
/// and `DictationTerminalTelemetryTests` proves the sink forwards them — and
/// both stop at the module boundary. Neither says anything about what
/// `TelemetryService` puts on the wire, which is what a query will actually
/// read. Same gap `EscapeRecoveryEventPayloadTests` exists to close, and this
/// follows it deliberately.
///
/// It also stands in for the part of "verify a telemetry change end to end
/// locally" that a running app would otherwise be needed for. **It is a stand-in
/// and not a replacement:** it asserts the property names, types and
/// omit-when-nil behaviour at the boundary, and it cannot see whether a real
/// dictation reaches this call at all. That remains a Live UAT obligation.
///
/// DEBUG-only, because the hook is.
#if DEBUG

  @MainActor
  /// Class: `.observabilityContract` — a query would lie about how much audio the
  /// VAD kept, or would silently drop the dimension. The user sees nothing.
  @Suite("VAD conditioning event payload (#2184)", .tags(.observabilityContract))
  struct VADConditioningEventPayloadTests {

    /// A reference box, because `testEventHook` is `@Sendable` and cannot mutate
    /// a captured local. It fires synchronously on the emitting actor.
    private final class EventBox: @unchecked Sendable {
      var events: [CapturedTelemetryEvent] = []
    }

    private func capture(_ body: (TelemetryService) -> Void) -> [CapturedTelemetryEvent] {
      let service = TelemetryService.shared
      let box = EventBox()
      service.testEventHook = { box.events.append($0) }
      defer { service.testEventHook = nil }
      body(service)
      return box.events
    }

    private func terminal(
      raw: Int? = nil, filtered: Int? = nil, ratio: Double? = nil, reason: String? = nil
    ) throws -> CapturedTelemetryEvent {
      let events = capture {
        $0.dictationTerminal(
          takeID: "TAKE-2184", backend: "parakeet", result: "completed", reason: nil,
          vadRawSampleCount: raw, vadFilteredSampleCount: filtered,
          vadRetainedRatio: ratio, vadConditioningReason: reason)
      }
      return try #require(events.first)
    }

    /// The names a query will be written against, and the buckets they land in.
    /// The ratio must be a Double: it is the only one of the four that is
    /// aggregated rather than filtered, and an integer bucket would round every
    /// value in this dimension to 0 or 1 — which is exactly the shape of a
    /// working chart reporting nothing.
    @Test("the four conditioning properties reach the wire under their query names")
    func conditioningPropertiesAreEmitted() throws {
      let event = try terminal(
        raw: 48_000, filtered: 12_000, ratio: 0.25, reason: "filtered")

      #expect(event.name == "dictation.terminal")
      #expect(event.intProps["vad_raw_sample_count"] == 48_000)
      #expect(event.intProps["vad_filtered_sample_count"] == 12_000)
      #expect(event.doubleProps["vad_retained_ratio"] == 0.25)
      #expect(event.stringProps["vad_conditioning_reason"] == "filtered")
    }

    /// Absence has to survive the boundary too. A take that ended before
    /// conditioning must emit no key at all rather than a zero or a one: an
    /// invented 1.0 reads as "the VAD kept everything" about audio the VAD never
    /// saw, and it would sit in the denominator of every query over this
    /// dimension looking exactly like a healthy take.
    @Test("a take with no conditioning omits all four rather than defaulting")
    func missingConditioningEmitsNothing() throws {
      let event = try terminal()

      #expect(event.intProps["vad_raw_sample_count"] == nil)
      #expect(event.intProps["vad_filtered_sample_count"] == nil)
      #expect(event.doubleProps["vad_retained_ratio"] == nil)
      #expect(event.stringProps["vad_conditioning_reason"] == nil)
    }

    /// The existing population must be untouched. An additive dimension is only
    /// safe if every row a shipped chart already reads keeps its old shape, so
    /// this asserts the pre-#2184 fields on the same call that carries the new
    /// ones.
    @Test("the existing terminal fields are unchanged by the addition")
    func existingFieldsSurviveTheAddition() throws {
      let event = try terminal(
        raw: 48_000, filtered: 47_000, ratio: 0.979, reason: "filtered")

      #expect(event.stringProps["take_id"] == "TAKE-2184")
      #expect(event.stringProps["backend"] == "parakeet")
      #expect(event.stringProps["result"] == "completed")
    }

    /// A whole-number ratio is the case a Double bucket makes look correct and
    /// an Int bucket silently destroys, so it gets its own row rather than being
    /// assumed to follow from the 0.25 case above.
    @Test("a ratio of exactly 1.0 is still carried as a number, not dropped")
    func wholeRatioIsCarried() throws {
      let event = try terminal(raw: 48_000, filtered: 48_000, ratio: 1.0, reason: "filtered")

      #expect(event.doubleProps["vad_retained_ratio"] == 1.0)
    }
  }

#endif
