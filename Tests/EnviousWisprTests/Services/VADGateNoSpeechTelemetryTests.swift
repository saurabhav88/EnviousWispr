import EnviousWisprServices
import Foundation
import Testing

#if DEBUG

  /// #3834: the WIRE contract for `audio.vad_gate_no_speech.advisory_eligible`.
  /// The sink tests stop at the callback boundary, so deleting the production
  /// `props["advisory_eligible"]` entry would leave them green. The hook reads
  /// the value back out of the emitted payload, so this observes what PostHog
  /// receives.
  @Suite(
    "audio.vad_gate_no_speech advisory_eligible (#3834)", .serialized,
    .tags(.observabilityContract))
  struct VADGateNoSpeechTelemetryTests {
    private static let eventName = "audio.vad_gate_no_speech"

    final class EventBox: @unchecked Sendable {
      private let lock = NSLock()
      private var stored: [CapturedTelemetryEvent] = []
      func append(_ event: CapturedTelemetryEvent) { lock.withLock { stored.append(event) } }
      func removeAll() { lock.withLock { stored.removeAll() } }
      var values: [CapturedTelemetryEvent] { lock.withLock { stored } }
    }

    @MainActor
    private func emit(advisoryEligible: Bool) {
      TelemetryService.shared.vadGateNoSpeech(
        backend: "parakeet", mode: "batch", rawSampleCount: 16_000,
        peakAudioLevel: 0.0007, wholeBufferRMS: 0.0004, maxWindowRMS: 0.0009,
        durationMs: 4_200, effectiveTransport: "built_in", selectedTransport: "unknown",
        inputSelectionMode: "auto", inputDeviceKind: "jack_input",
        captureNativeRateHz: 48_000, captureNativeChannelCount: 1, captureInputChannel: nil,
        takeID: "6f1d2c4a-0b7e-4c1f-9a53-2d8e7f310b44", advisoryEligible: advisoryEligible)
    }

    @MainActor
    @Test("advisory_eligible is serialized as a Bool both ways, beside the existing facts")
    func advisoryEligibleContract() throws {
      let box = EventBox()
      TelemetryService.shared.testEventHook = { @Sendable event in
        if event.name == Self.eventName { box.append(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      emit(advisoryEligible: true)
      let eligible = try #require(box.values.first)
      #expect(box.values.count == 1, "the emitter must fire exactly once")
      #expect(eligible.boolProps["advisory_eligible"] == true)
      // The pre-existing properties must survive the payload change.
      #expect(eligible.stringProps["mode"] == "batch")
      #expect(eligible.intProps["raw_sample_count"] == 16_000)
      #expect(eligible.intProps["duration_ms"] == 4_200)

      box.removeAll()
      emit(advisoryEligible: false)
      let silent = try #require(box.values.first)
      #expect(box.values.count == 1)
      #expect(
        silent.boolProps["advisory_eligible"] == false,
        "a silent dead-air take must send false, not omit the key")
    }
  }

#endif
