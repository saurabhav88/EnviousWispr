import EnviousWisprServices
import Foundation
import Testing

#if DEBUG

  /// #1846: the WIRE contract for the three record-start VAD markers. The routing
  /// tests in `CaptureVADSignalSourceTests` and `RecordStartTelemetrySinkTests` stop
  /// at injected seams, so deleting a production `props["take_id"]` line leaves them
  /// green.
  ///
  /// These three emitters previously built the DEBUG hook event and the PostHog
  /// properties as two SEPARATE literals — a test could assert a key the real capture
  /// never sent. Chunk 9 collapsed each to one payload with the hook derived from it,
  /// which is what makes this suite trustworthy rather than a second mirror.
  @Suite("VAD marker take_id telemetry (#1846)", .serialized)
  struct VADMarkerTakeIDTelemetryTests {
    private static let takeID = "9f2c1d84-6b3a-4e07-9c51-0a7d2e6f1b33"

    final class EventBox: @unchecked Sendable {
      private let lock = NSLock()
      private var stored: [CapturedTelemetryEvent] = []
      func append(_ event: CapturedTelemetryEvent) { lock.withLock { stored.append(event) } }
      func removeAll() { lock.withLock { stored.removeAll() } }
      var values: [CapturedTelemetryEvent] { lock.withLock { stored } }
    }

    private static let vadEventNames: Set<String> = [
      "dictation.vad_preparation_completed",
      "dictation.first_vad_chunk_started",
      "dictation.first_vad_chunk_completed",
    ]

    @MainActor
    @Test("all three VAD markers emit take_id when present and omit it when nil")
    func vadMarkerTakeIDContract() throws {
      let box = EventBox()
      TelemetryService.shared.testEventHook = { @Sendable event in
        if Self.vadEventNames.contains(event.name) { box.append(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      Self.emitAllThree(takeID: Self.takeID)

      let presentEvents = box.values
      #expect(presentEvents.count == 3, "each of the three markers must fire exactly once")
      #expect(
        Set(presentEvents.map(\.name)) == Self.vadEventNames,
        "all three markers must fire — saw \(presentEvents.map(\.name).sorted())"
      )
      for event in presentEvents {
        #expect(
          event.stringProps["take_id"] == Self.takeID,
          "\(event.name) must carry the take key")
      }

      box.removeAll()
      Self.emitAllThree(takeID: nil)

      let absentEvents = box.values
      #expect(absentEvents.count == 3, "each of the three markers must still fire exactly once")
      #expect(
        Set(absentEvents.map(\.name)) == Self.vadEventNames,
        "the nil case must emit the same three markers — saw \(absentEvents.map(\.name).sorted())"
      )
      for event in absentEvents {
        #expect(
          event.stringProps["take_id"] == nil,
          "\(event.name) must OMIT take_id, not send an empty string")
        #expect(event.stringProps["backend"] == "parakeet")
      }
    }

    @MainActor
    private static func emitAllThree(takeID: String?) {
      TelemetryService.shared.dictationVADPreparationCompleted(
        backend: "parakeet", inputRoute: "built_in_mic", ready: true, modelReused: false,
        takeID: takeID)
      TelemetryService.shared.dictationFirstVADChunkStarted(
        backend: "parakeet", inputRoute: "built_in_mic", monitorToFirstChunkMs: 12.5,
        takeID: takeID)
      TelemetryService.shared.dictationFirstVADChunkCompleted(
        backend: "parakeet", inputRoute: "built_in_mic", chunkProcessingLatencyMs: 3.25,
        shouldStop: false, takeID: takeID)
    }
  }

#endif
