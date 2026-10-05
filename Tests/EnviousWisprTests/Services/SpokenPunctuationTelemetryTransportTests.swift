import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprServices

#if DEBUG

  /// #2450: the two spoken-punctuation facts ride the EXISTING `dictation.completed` row.
  ///
  /// **Observability Contract.** When this fails a dashboard reads the start-word pass wrongly: the
  /// status is missing or misspelled, the count arrives as a string, or a transcript the pass never
  /// touched claims a status. This is the last of four hops (`RunOutcome`, the finalization outcome,
  /// `ExecutionMetrics`, `TelemetryService`); the earlier three are pinned in
  /// `KernelFinalizationWiringTests`. The vendor receipt is Live UAT's, not a unit test's.
  ///
  /// `testEventHook` and `CapturedTelemetryEvent` are DEBUG-only, so the suite is DEBUG-gated.
  @MainActor
  @Suite("Spoken punctuation telemetry transport (#2450)", .tags(.observabilityContract))
  struct SpokenPunctuationTelemetryTransportTests {

    private final class EventLog: @unchecked Sendable {
      var events: [CapturedTelemetryEvent] = []
    }

    private func capture(_ transcript: Transcript) throws -> CapturedTelemetryEvent {
      let log = EventLog()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { log.events.append(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }
      TelemetryService.shared.reportDictationCompleted(transcript: transcript, inputMode: "ptt")
      let completed = log.events.filter { $0.name == "dictation.completed" }
      #expect(completed.count == 1, "exactly one dictation.completed, got \(completed.count)")
      return try #require(completed.first)
    }

    @Test("A rewrite reports its status as a string and its count as an Int")
    func rewriteReachesThePayload() throws {
      var metrics = ExecutionMetrics()
      metrics.punctuationStatus = "rewrote"
      metrics.punctuationRulesFired = 3
      var transcript = Transcript(text: "hello")
      transcript.metrics = metrics

      let event = try capture(transcript)
      #expect(event.stringProps["punctuation_status"] == "rewrote")
      #expect(event.intProps["punctuation_rules_fired"] == 3)
      #expect(
        event.stringProps["punctuation_rules_fired"] == nil, "the count must not travel as a string"
      )
    }

    @Test("Each status in the closed vocabulary arrives spelled exactly as it is queried")
    func everyStatusSpelling() throws {
      for status in [
        "disabled", "unresolved", "unsupported", "ran_no_match", "rewrote", "timed_out",
      ] {
        var metrics = ExecutionMetrics()
        metrics.punctuationStatus = status
        var transcript = Transcript(text: "hello")
        transcript.metrics = metrics
        let event = try capture(transcript)
        #expect(event.stringProps["punctuation_status"] == status)
        #expect(
          event.intProps["punctuation_rules_fired"] == nil, "no count was supplied for \(status)")
      }
    }

    @Test("A transcript the pass never touched omits both keys in every bucket")
    func absentFieldsAreOmitted() throws {
      let event = try capture(Transcript(text: "hello"))
      let allKeys =
        Set(event.stringProps.keys).union(event.intProps.keys).union(event.doubleProps.keys)
        .union(event.boolProps.keys)
      #expect(allKeys.contains("punctuation_status") == false)
      #expect(allKeys.contains("punctuation_rules_fired") == false)
    }

    @Test("The language and its source stay on the existing cleanup fields, not repeated here")
    func languageAndSourceAreNotDuplicated() throws {
      var metrics = ExecutionMetrics()
      metrics.cleanupLanguage = "de"
      metrics.cleanupLanguageSource = "dictation"
      metrics.punctuationStatus = "rewrote"
      metrics.punctuationRulesFired = 1
      var transcript = Transcript(text: "hello")
      transcript.metrics = metrics

      let event = try capture(transcript)
      #expect(event.stringProps["cleanup_language"] == "de")
      #expect(event.stringProps["cleanup_language_source"] == "dictation")
      let allKeys =
        Set(event.stringProps.keys).union(event.intProps.keys).union(event.doubleProps.keys)
        .union(event.boolProps.keys)
      #expect(allKeys.contains("punctuation_language") == false)
      #expect(allKeys.contains("punctuation_resolution_source") == false)
    }

    @Test("The two new fields survive a Codable round trip and an old blob decodes without them")
    func codableIsAdditive() throws {
      var metrics = ExecutionMetrics()
      metrics.punctuationStatus = "ran_no_match"
      metrics.punctuationRulesFired = 0
      let data = try JSONEncoder().encode(metrics)
      let decoded = try JSONDecoder().decode(ExecutionMetrics.self, from: data)
      #expect(decoded.punctuationStatus == "ran_no_match")
      #expect(decoded.punctuationRulesFired == 0)

      var fields = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
      fields.removeValue(forKey: "punctuationStatus")
      fields.removeValue(forKey: "punctuationRulesFired")
      let legacy = try JSONSerialization.data(withJSONObject: fields)
      let old = try JSONDecoder().decode(ExecutionMetrics.self, from: legacy)
      #expect(old.punctuationStatus == nil)
      #expect(old.punctuationRulesFired == nil)
    }
  }

#endif
