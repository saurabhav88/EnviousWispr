import EnviousWisprServices
import Foundation
import Testing

#if DEBUG

  /// #2060: PostHog's reserved `$value` is the slot charts aggregate on by
  /// default, so a duration emitted there in the wrong unit is silently wrong by
  /// 1000x on any chart that spans two events. Eleven emitters carried seconds
  /// and two carried milliseconds; these tests pin the unit on the two that were
  /// converted. (#2958 phase 2 retired `paste.completed`; its seconds value now
  /// travels as `paste_seconds` on `dictation.completed`, whose `$value` is e2e,
  /// so the paste case pins that key instead of the slot.)
  ///
  /// Both cases FAIL against pre-fix `main`, where the value was the raw
  /// millisecond count — they are regression tests, not descriptions of current
  /// behaviour. Each asserts the unit two ways: the exact converted value, and
  /// the inequality with the millisecond input, so a future edit that reverts the
  /// division cannot leave the suite green.
  @Suite("$value duration unit (#2060)", .serialized)
  struct TelemetryValueUnitTests {
    final class EventBox: @unchecked Sendable {
      private let lock = NSLock()
      private var stored: [CapturedTelemetryEvent] = []
      func append(_ event: CapturedTelemetryEvent) { lock.withLock { stored.append(event) } }
      var values: [CapturedTelemetryEvent] { lock.withLock { stored } }
    }

    @MainActor
    private static func capture(
      _ name: String, _ emit: () -> Void
    ) -> [CapturedTelemetryEvent] {
      let box = EventBox()
      TelemetryService.shared.testEventHook = { @Sendable event in
        if event.name == name { box.append(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }
      emit()
      return box.values
    }

    @MainActor
    @Test("limb.failure_observed reports $value in seconds and keeps duration_ms raw")
    func limbFailureValueIsSeconds() throws {
      let durationMs = 1500
      let events = Self.capture("limb.failure_observed") {
        TelemetryService.shared.limbFailureObserved(
          limb: "ollama", operation: "evict", result: "failed",
          errorCategory: "-1004", durationMs: durationMs)
      }

      #expect(events.count == 1, "the emitter must fire exactly once")
      let event = try #require(events.first)
      let value = try #require(
        event.doubleProps["$value"],
        "$value must be projected into the DEBUG seam, or the unit is untestable")

      #expect(value == 1.5, "1500 ms must be reported as 1.5 s")
      #expect(
        value != Double(durationMs),
        "pre-fix behaviour: $value carried the raw millisecond count")
      #expect(
        event.intProps["duration_ms"] == durationMs,
        "the raw millisecond value must survive untouched under its own name")
    }

    @MainActor
    @Test("dictation.completed reports paste_seconds in seconds and keeps paste_latency_ms raw")
    func pasteSecondsIsSeconds() throws {
      // The real production p95 (302 ms), which is what made paste read as ~60x
      // SLOWER than AI polish on a shared chart when it is ~16x faster.
      let latencyMs = 302
      let events = Self.capture("dictation.completed") {
        TelemetryService.shared.dictationCompleted(
          result: "success", inputMode: "ptt", asrBackend: "parakeet", llmProvider: nil,
          fillerRemoval: false, targetApp: nil, pasteResult: "accessibility",
          e2eSeconds: 1.5, asrSeconds: nil, llmSeconds: nil, pasteLatencyMs: latencyMs)
      }

      #expect(events.count == 1, "the emitter must fire exactly once")
      let event = try #require(events.first)
      let value = try #require(event.doubleProps["paste_seconds"])

      // 302/1000 is not exactly representable in binary, so compare against the
      // same computation rather than a decimal literal, then bound it
      // independently so the assertion cannot pass by restating the production
      // expression back to itself.
      #expect(abs(value - Double(latencyMs) / 1000.0) < 1e-12)
      #expect(value < 1.0, "a sub-second paste must not read as a three-digit magnitude")
      #expect(
        value != Double(latencyMs),
        "pre-fix behaviour: the value carried the raw millisecond count")
      #expect(
        event.intProps["paste_latency_ms"] == latencyMs,
        "the raw millisecond value must survive untouched under its own name")
      #expect(event.doubleProps["$value"] == 1.5, "the terminal row's slot stays e2e")
    }

    /// The convention this issue established, asserted rather than described:
    /// both converted duration keys agree with each other on the same input.
    @MainActor
    @Test("the two converted duration keys agree on the unit for an identical input")
    func convertedEmittersAgree() throws {
      let ms = 750
      let limb = Self.capture("limb.failure_observed") {
        TelemetryService.shared.limbFailureObserved(
          limb: "llm_prewarm", operation: "prewarm", result: "failed",
          errorCategory: "x", durationMs: ms)
      }
      let paste = Self.capture("dictation.completed") {
        TelemetryService.shared.dictationCompleted(
          result: "success", inputMode: "ptt", asrBackend: "parakeet", llmProvider: nil,
          fillerRemoval: false, targetApp: nil, pasteResult: "clipboard",
          e2eSeconds: 1.5, asrSeconds: nil, llmSeconds: nil, pasteLatencyMs: ms)
      }

      // Unnested: `try #require(try #require(...))` is a recursive macro
      // expansion and does not compile.
      let limbEvent = try #require(limb.first)
      let pasteEvent = try #require(paste.first)
      let limbValue = try #require(limbEvent.doubleProps["$value"])
      let pasteValue = try #require(pasteEvent.doubleProps["paste_seconds"])
      #expect(limbValue == pasteValue, "same duration, same slot, same unit")
    }
  }

#endif
