import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

#if DEBUG

  /// #3801: `dictation.completed` carries how many trailing segments the Whisper silent-tail
  /// filter removed, as a number only, never text. When this fails, the field rate of removed
  /// "Thank you" endings is invisible, or a zero (filter ran, removed nothing) is confused with
  /// "not measured".
  @Suite(
    "Whisper silent-tail count on dictation.completed", .serialized, .tags(.observabilityContract))
  struct WhisperSilentTailTelemetryTests {
    final class EventBox: @unchecked Sendable {
      private let lock = NSLock()
      private var stored: [CapturedTelemetryEvent] = []
      func append(_ event: CapturedTelemetryEvent) { lock.withLock { stored.append(event) } }
      var values: [CapturedTelemetryEvent] { lock.withLock { stored } }
    }

    /// The hop the app uses: a saved transcript's metrics through `reportDictationCompleted`.
    @MainActor
    private static func report(_ metrics: ExecutionMetrics) -> [CapturedTelemetryEvent] {
      let box = EventBox()
      TelemetryService.shared.testEventHook = { @Sendable event in
        if event.name == "dictation.completed" { box.append(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }
      var transcript = Transcript(text: "hola mundo")
      transcript.metrics = metrics
      TelemetryService.shared.reportDictationCompleted(
        transcript: transcript, inputMode: "ptt", model: nil)
      return box.values
    }

    @MainActor
    @Test("a positive count reaches dictation.completed as a number")
    func positiveCount() throws {
      let event = try #require(
        Self.report(ExecutionMetrics(asrLatencySeconds: 0.3, whisperSilentTailDropped: 2)).first)
      #expect(event.intProps["whisper_silent_tail_dropped"] == 2)
    }

    @MainActor
    @Test("zero stays present: the filter ran and removed nothing")
    func zeroCountPresent() throws {
      let event = try #require(
        Self.report(ExecutionMetrics(asrLatencySeconds: 0.3, whisperSilentTailDropped: 0)).first)
      #expect(event.intProps["whisper_silent_tail_dropped"] == 0)
    }

    @MainActor
    @Test("no count (Parakeet, or no Whisper decode released text) omits the key")
    func nilCountOmitted() throws {
      let event = try #require(Self.report(ExecutionMetrics(asrLatencySeconds: 0.3)).first)
      #expect(event.intProps["whisper_silent_tail_dropped"] == nil)
      #expect(event.stringProps["whisper_silent_tail_dropped"] == nil)
    }

    @Test("a transcript saved before #3801 still decodes, with no count")
    func legacyMetricsDecode() throws {
      // A pre-#3801 record: the same JSON with no `whisperSilentTailDropped` key at all.
      var object = try #require(
        try JSONSerialization.jsonObject(
          with: JSONEncoder().encode(ExecutionMetrics(asrLatencySeconds: 0.3))) as? [String: Any])
      object.removeValue(forKey: "whisperSilentTailDropped")
      let legacy = try JSONSerialization.data(withJSONObject: object)
      let metrics = try JSONDecoder().decode(ExecutionMetrics.self, from: legacy)
      #expect(metrics.whisperSilentTailDropped == nil)
      let roundTrip = try JSONDecoder().decode(
        ExecutionMetrics.self,
        from: JSONEncoder().encode(ExecutionMetrics(whisperSilentTailDropped: 1)))
      #expect(roundTrip.whisperSilentTailDropped == 1)
    }
  }

#endif
