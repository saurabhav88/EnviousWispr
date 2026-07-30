import EnviousWisprServices
import Foundation
import Testing

#if DEBUG

  /// #1846 chunk 10: the WIRE contract for `recording.cap_warning_shown`. The
  /// routing tests stop at the callback boundary, so deleting the production
  /// `props["take_id"]` line leaves them green.
  ///
  /// This emitter had no DEBUG hook at all before chunk 10. It was added as ONE
  /// payload with the hook derived from it — never a second literal, which is the
  /// shape that lets a wire test assert a key the real capture never sent.
  @Suite("recording.cap_warning_shown take_id (#1846)", .serialized)
  struct CapWarningTakeIDTelemetryTests {
    private static let takeID = "3c7e5a11-92d4-4f60-b8a7-51e0c6d3f284"
    private static let eventName = "recording.cap_warning_shown"

    final class EventBox: @unchecked Sendable {
      private let lock = NSLock()
      private var stored: [CapturedTelemetryEvent] = []
      func append(_ event: CapturedTelemetryEvent) { lock.withLock { stored.append(event) } }
      func removeAll() { lock.withLock { stored.removeAll() } }
      var values: [CapturedTelemetryEvent] { lock.withLock { stored } }
    }

    @MainActor
    @Test("the cap warning emits take_id when present and omits it when nil")
    func capWarningTakeIDContract() throws {
      // `try #require` on each captured event, not optional chaining: with an
      // empty box, `absent.first?.stringProps["take_id"] == nil` is nil == nil
      // and PASSES vacuously — the exact hazard
      // `swift-testing-require-preconditions` exists to close.
      let box = EventBox()
      TelemetryService.shared.testEventHook = { @Sendable event in
        if event.name == Self.eventName { box.append(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      TelemetryService.shared.recordingCapWarningShown(
        backend: "parakeet", capSeconds: 3600, takeID: Self.takeID)

      let present = box.values
      #expect(present.count == 1, "the emitter must fire exactly once")
      let presentEvent = try #require(present.first)
      #expect(presentEvent.stringProps["take_id"] == Self.takeID)
      // The pre-existing properties must survive the payload rewrite.
      #expect(presentEvent.stringProps["asr_backend"] == "parakeet")
      #expect(presentEvent.doubleProps["cap_seconds"] == 3600)

      box.removeAll()
      TelemetryService.shared.recordingCapWarningShown(
        backend: "whisperKit", capSeconds: 3600, takeID: nil)

      let absent = box.values
      #expect(absent.count == 1, "the nil case must still fire")
      let absentEvent = try #require(absent.first)
      #expect(
        absentEvent.stringProps["take_id"] == nil,
        "an absent take key must be OMITTED, not sent as an empty string")
      #expect(absentEvent.stringProps["asr_backend"] == "whisperKit")
    }
  }

#endif
