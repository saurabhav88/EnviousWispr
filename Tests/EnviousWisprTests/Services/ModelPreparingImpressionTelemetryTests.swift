import EnviousWisprServices
import Foundation
import Testing

#if DEBUG

  /// #1635: the shape of the one event that can tell us whether the "getting the model
  /// ready" copy ever reached a real screen.
  ///
  /// This event exists because the previous attempt at #1635 shipped a label that could
  /// never appear, behind four passing tests. `coldstart.warmup_*` measures how long the
  /// engine took, never whether we told anyone. So the payload is pinned here: a wrong
  /// event name or a renamed property would silently restore that blind spot, and the
  /// dashboard would show nothing while looking exactly like "the state never happened".
  @Suite("Model preparing impression telemetry", .serialized)
  struct ModelPreparingImpressionTelemetryTests {

    final class EventBox: @unchecked Sendable {
      private let lock = NSLock()
      private var stored: CapturedTelemetryEvent?

      func set(_ event: CapturedTelemetryEvent) {
        lock.withLock { stored = event }
      }

      var value: CapturedTelemetryEvent? {
        lock.withLock { stored }
      }
    }

    @MainActor
    @Test("the impression event carries exactly engine and reason, and nothing else")
    func impressionPayloadIsExact() throws {
      let box = EventBox()
      TelemetryService.shared.testEventHook = { @Sendable event in
        if event.name == "settings.model_preparing_impression" { box.set(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      TelemetryService.shared.settingsModelPreparingImpression(
        engine: "whisperKit", reason: "engine_swap")

      let event = try #require(
        box.value,
        "Expected settings.model_preparing_impression event")
      #expect(event.name == "settings.model_preparing_impression")
      #expect(event.stringProps["engine"] == "whisperKit")
      #expect(event.stringProps["reason"] == "engine_swap")

      // Exactly two properties. A third would mean someone added a field without deciding
      // whether it crosses the privacy boundary.
      #expect(event.stringProps.count == 2)

      // No duration anywhere. A view that can disappear and reappear during one warm cannot
      // honestly measure the warm; `coldstart.warmup_*` owns that number.
      #expect(event.intProps.isEmpty)
      #expect(event.doubleProps.isEmpty)
      #expect(event.boolProps.isEmpty)
      #expect(event.stringProps["elapsed_ms"] == nil)
    }
  }

#endif
