import EnviousWisprServices
import Foundation
import Testing

#if DEBUG

  /// #1846: the WIRE contract for the two polish outcome events. The routing tests in
  /// `TextProcessingRunnerCaptureTests` and `LLMPolishStepTelemetryTests` stop at the
  /// injected seams, so deleting either production `props["take_id"] = takeID` line in
  /// `TelemetryService` leaves all of them green. Deriving the DEBUG hook from `props`
  /// makes a wire test trustworthy; it does not replace it.
  @Suite("Polish outcome take_id telemetry (#1846)", .serialized)
  struct PolishOutcomeTakeIDTelemetryTests {
    private static let takeID = "9f2c1d84-6b3a-4e07-9c51-0a7d2e6f1b33"

    final class EventBox: @unchecked Sendable {
      private let lock = NSLock()
      private var stored: [CapturedTelemetryEvent] = []

      func append(_ event: CapturedTelemetryEvent) {
        lock.withLock { stored.append(event) }
      }

      func removeAll() {
        lock.withLock { stored.removeAll() }
      }

      var values: [CapturedTelemetryEvent] {
        lock.withLock { stored }
      }
    }

    @MainActor
    @Test("polish skipped and failed emit take_id when present and omit it when nil")
    func polishOutcomeTakeIDContract() throws {
      let box = EventBox()
      TelemetryService.shared.testEventHook = { @Sendable event in
        if event.name == "llm.polish_skipped" || event.name == "llm.polish_failed" {
          box.append(event)
        }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      TelemetryService.shared.polishSkipped(
        provider: "openAI", reason: "too_short", takeID: Self.takeID)
      TelemetryService.shared.polishFailed(
        provider: "openAI", model: "gpt-4o-mini",
        reason: "api_key_rejected", isTimeout: false, takeID: Self.takeID)

      let presentSkipped = try #require(
        box.values.first { $0.name == "llm.polish_skipped" })
      let presentFailed = try #require(
        box.values.first { $0.name == "llm.polish_failed" })

      #expect(presentSkipped.stringProps["take_id"] == Self.takeID)
      #expect(presentSkipped.stringProps["skip_reason"] == "too_short")
      #expect(presentFailed.stringProps["take_id"] == Self.takeID)
      #expect(presentFailed.stringProps["reason"] == "api_key_rejected")

      box.removeAll()

      TelemetryService.shared.polishSkipped(
        provider: "openAI", reason: "too_short", takeID: nil)
      TelemetryService.shared.polishFailed(
        provider: "openAI", model: "gpt-4o-mini",
        reason: "api_key_rejected", isTimeout: false, takeID: nil)

      let absentSkipped = try #require(
        box.values.first { $0.name == "llm.polish_skipped" })
      let absentFailed = try #require(
        box.values.first { $0.name == "llm.polish_failed" })

      // ABSENT, not empty — the sibling assertions prove the omission did not
      // suppress the event itself.
      #expect(absentSkipped.stringProps["take_id"] == nil)
      #expect(absentSkipped.stringProps["skip_reason"] == "too_short")
      #expect(absentFailed.stringProps["take_id"] == nil)
      #expect(absentFailed.stringProps["reason"] == "api_key_rejected")
    }
  }

#endif
