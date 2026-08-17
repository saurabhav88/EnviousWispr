import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprServices

/// The ACTUAL emitted payloads (#2087, chunk 11).
///
/// `EscapeRecoveryTelemetryTests` observes injected closures, which proves the
/// coordinator calls its seams with the right values and proves nothing about
/// what `TelemetryService` puts on the wire. Deleting or corrupting `started`,
/// `completed` or `restored` stayed green, because nothing called them.
///
/// These drive the real methods through `testEventHook` and assert the property
/// names a dashboard will query, the closed-set labels, and the `$value`
/// convention. DEBUG-only, because the hook is.
#if DEBUG

  @MainActor
  @Suite("Escape Recovery event payloads (#2087)")
  struct EscapeRecoveryEventPayloadTests {

    /// Captures one event, then removes the hook so suites cannot leak into
    /// each other.
    /// A reference box, because `testEventHook` is `@Sendable` and cannot
    /// mutate a captured local. It fires synchronously on the emitting actor.
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

    @Test("started carries the backend, provider, duration and take id")
    func startedPayload() throws {
      let events = capture {
        $0.escapeRecoveryStarted(
          asrBackend: "parakeet", polishProvider: "apple", recordingDurationMs: 4200,
          takeID: "take-1")
      }
      let event = try #require(events.first)
      #expect(event.name == "escape_recovery.started")
      #expect(event.stringProps["asr_backend"] == "parakeet")
      #expect(event.stringProps["polish_provider"] == "apple")
      #expect(event.stringProps["take_id"] == "take-1")
      #expect(event.intProps["recording_duration_ms"] == 4200)
    }

    /// `$value` is PostHog's reserved aggregation slot and any duration written
    /// there is in SECONDS (#2060), with the raw integer kept under its own
    /// `*_ms` name. A chart spanning two events reads `$value` without asking
    /// what unit each meant, so a milliseconds value here would be off by 1000
    /// and look plausible.
    func completedEvent(outcome: EscapeRecoveryTerminalOutcome) throws -> CapturedTelemetryEvent {
      let events = capture {
        $0.escapeRecoveryCompleted(
          outcome: outcome, asrDurationMs: 800, polishDurationMs: 1500, durationMs: 2500,
          asrBackend: "parakeet", takeID: "take-2")
      }
      return try #require(events.first)
    }

    @Test("completed carries seconds in the aggregation slot and milliseconds by name")
    func completedValueSlotIsSeconds() throws {
      let event = try completedEvent(outcome: .saved)
      #expect(event.name == "escape_recovery.completed")
      #expect(event.intProps["duration_ms"] == 2500)
      #expect(event.intProps["asr_duration_ms"] == 800)
      #expect(event.intProps["polish_duration_ms"] == 1500)
      #expect(
        event.doubleProps["$value"] == 2.5,
        "seconds in the reserved slot, not milliseconds (#2060)")
    }

    @Test(
      "completed accepts the whole outcome vocabulary and emits its raw label",
      arguments: EscapeRecoveryTerminalOutcome.allCases)
    func completedOutcomeVocabulary(outcome: EscapeRecoveryTerminalOutcome) throws {
      let event = try completedEvent(outcome: outcome)
      #expect(event.stringProps["outcome"] == outcome.rawValue)
    }

    /// The WIRE LABELS, spelled out.
    ///
    /// This test previously asserted `transcriptionFailed` — Swift's default
    /// raw value, derived from the case name — and so PINNED the wrong
    /// vocabulary against an approved schema that says `transcription_failed`.
    /// Second time in this build a test locked in a defect instead of catching
    /// it, both times because I asserted what the code produced rather than what
    /// the spec required.
    ///
    /// Every case is listed rather than spot-checked: a raw value is the wire
    /// format, and a rename silently splits a series that a dashboard reads
    /// months later.
    @Test("the outcome labels are exactly the approved schema")
    func outcomeLabelsMatchTheSchema() {
      #expect(
        Set(EscapeRecoveryTerminalOutcome.allCases.map(\.rawValue)) == [
          "saved", "empty", "transcription_failed", "save_failed", "abandoned",
        ])
    }

    /// The two the abandonment contract creates. An earlier draft of the plan
    /// omitted both, which would have made a deliberate discard indistinguishable
    /// from a failure.
    @Test("abandoned and transcription_failed are in the vocabulary")
    func abandonmentOutcomesExist() {
      let labels = Set(EscapeRecoveryTerminalOutcome.allCases.map(\.rawValue))
      #expect(labels.contains("abandoned"))
      #expect(labels.contains("transcription_failed"))
    }

    /// `restored` MEANS the user got the text back, so a "failed" value is a
    /// contradiction that would inflate the numerator of the ratio this funnel
    /// exists to compute.
    @Test("the paste result vocabulary contains no failure")
    func restoreVocabularyHasNoFailureCase() {
      #expect(
        Set(EscapeRecoveryPasteResult.allCases.map(\.rawValue)) == ["pasted", "clipboard_only"])
    }

    @Test(
      "restored carries a closed source and paste result",
      arguments: EscapeRecoveryRestoreSource.allCases)
    func restoredPayload(source: EscapeRecoveryRestoreSource) throws {
      let events = capture {
        $0.escapeRecoveryRestored(
          source: source, ageMs: 90_000, pasteResult: .pasted, takeID: "take-3")
      }
      let event = try #require(events.first)
      #expect(event.name == "escape_recovery.restored")
      #expect(event.stringProps["source"] == source.rawValue)
      #expect(event.stringProps["paste_result"] == "pasted")
      #expect(event.intProps["age_ms"] == 90_000)
      #expect(event.stringProps["take_id"] == "take-3")
    }

    @Test("kept and expired carry only an age and a join key")
    func keptAndExpiredPayloads() throws {
      let kept = try #require(capture { $0.escapeRecoveryKept(ageMs: 3600_000, takeID: "k") }.first)
      #expect(kept.name == "escape_recovery.kept")
      #expect(kept.intProps["age_ms"] == 3600_000)
      #expect(kept.stringProps["take_id"] == "k")
      #expect(kept.stringProps.count == 1, "no other string property, so no room for content")

      let expired = try #require(
        capture { $0.escapeRecoveryExpired(ageMs: 86_400_000, takeID: "e") }.first)
      #expect(expired.name == "escape_recovery.expired")
      #expect(expired.intProps["age_ms"] == 86_400_000)
      #expect(expired.stringProps["take_id"] == "e")
      #expect(expired.stringProps.count == 1)
    }

    /// The additive dimension. Its whole purpose is that a held recovery is not
    /// counted as a delivered dictation, so the property has to actually appear.
    @Test("the terminal row carries a delivery disposition when one is given")
    func terminalCarriesDisposition() throws {
      let ordinary = try #require(
        capture {
          $0.dictationTerminal(
            takeID: "t", backend: "parakeet", result: "completed", reason: nil)
        }.first)
      #expect(
        ordinary.stringProps["delivery_disposition"] == nil,
        "absent by default, so every existing row and query is unchanged")

      let recovery = try #require(
        capture {
          $0.dictationTerminal(
            takeID: "t", backend: "parakeet", result: "completed", reason: nil,
            deliveryDisposition: "escape_recovery")
        }.first)
      #expect(recovery.stringProps["delivery_disposition"] == "escape_recovery")
      #expect(recovery.stringProps["result"] == "completed", "the result vocabulary is untouched")
    }

    /// The join key has to be registered, or the funnel cannot be assembled at
    /// all. Read from the script rather than restated, so the two cannot drift.
    @Test("all five events are registered as take-keyed in the join script")
    func joinScriptRegistration() throws {
      let script = try String(
        contentsOf: RepoRoot.sourceURL("scripts/telemetry-join.py"), encoding: .utf8)
      // Split on the tuple's CLOSING line, not the first `)`. Comments inside
      // the tuple contain parentheses, so splitting on a bare `)` truncated the
      // block before any event name — which the control below caught.
      let block = try #require(
        script.components(separatedBy: "TAKE_KEYED_EVENTS = (").dropFirst().first?
          .components(separatedBy: "\n)").first,
        "the tuple must still exist under that name")

      for event in [
        "escape_recovery.started", "escape_recovery.completed", "escape_recovery.restored",
        "escape_recovery.kept", "escape_recovery.expired",
      ] {
        #expect(block.contains("\"\(event)\""), "\(event) is not registered as take-keyed")
      }
      #expect(
        block.contains("\"dictation.terminal\""),
        "control: the scan found the real tuple, not an empty string")
    }
  }

#endif
