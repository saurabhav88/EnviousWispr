import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

#if DEBUG

  /// #996 §4: the nine learn-from-edits payload contracts. Key sets are frozen
  /// so a renamed or added property is a deliberate change with a knowledge row
  /// behind it; every value is a closed enum or a count, never text.
  @Suite("learn-from-edits telemetry payloads (#996)", .serialized, .tags(.observabilityContract))
  struct LearnFromEditsTelemetryTests {
    typealias T = TelemetryService.LearnFromEditsTelemetry

    final class EventBox: @unchecked Sendable {
      private let lock = NSLock()
      private var stored: [CapturedTelemetryEvent] = []
      private var raw: [(String, [String: Any])] = []
      func append(_ event: CapturedTelemetryEvent) { lock.withLock { stored.append(event) } }
      func appendRaw(_ name: String, _ props: [String: Any]) {
        lock.withLock { raw.append((name, props)) }
      }
      var values: [CapturedTelemetryEvent] { lock.withLock { stored } }
      var rawValues: [(String, [String: Any])] { lock.withLock { raw } }
    }

    @MainActor
    private static func capture(_ emit: () -> Void) -> EventBox {
      let box = EventBox()
      TelemetryService.shared.testEventHook = { @Sendable event in
        if event.name.hasPrefix("custom_words.learn_") { box.append(event) }
      }
      TelemetryService.shared.testRawPropertiesHook = { @Sendable name, props in
        if name.hasPrefix("custom_words.learn_") { box.appendRaw(name, props) }
      }
      defer {
        TelemetryService.shared.testEventHook = nil
        TelemetryService.shared.testRawPropertiesHook = nil
      }
      emit()
      return box
    }

    private static func keys(_ event: CapturedTelemetryEvent) -> Set<String> {
      Set(event.stringProps.keys).union(event.intProps.keys).union(event.doubleProps.keys)
        .union(event.boolProps.keys)
    }

    /// Independent oracle: the plan §4 event list and property names spelled out.
    static let contract: [String: Set<String>] = [
      "custom_words.learn_skipped": ["reason"],
      "custom_words.learn_observation_ended": [
        "reason", "settled_bursts", "app_class", "duration_ms",
      ],
      "custom_words.learn_judged": [
        "arm", "outcome", "candidates", "accepted", "latency_ms", "queue_wait_ms",
      ],
      "custom_words.learn_proposed": ["state"],
      "custom_words.learn_card_shown": [],
      "custom_words.learn_card_expired": [],
      "custom_words.learn_resolved": ["decision", "surface", "state", "outcome"],
      "custom_words.learn_save_failed": ["reason"],
      "custom_words.learn_ledger_untrusted": ["kind"],
    ]

    @MainActor
    @Test("all nine events fire once with exactly the contract keys and no untyped property")
    func nineEventsFrozenKeys() throws {
      let box = Self.capture {
        let t = TelemetryService.shared
        t.learnSkipped(reason: .appBlocklisted)
        t.learnObservationEnded(
          reason: .settled, settledBursts: 1, appClass: .native, durationMs: 4200)
        t.learnJudged(
          arm: .rules, outcome: .verdict, candidates: 3, accepted: 1, latencyMs: 812,
          queueWaitMs: 0)
        t.learnProposed(state: .existingWord)
        t.learnCardShown()
        t.learnCardExpired()
        t.learnResolved(decision: .accepted, surface: .card, state: .newWord, outcome: .added)
        t.learnSaveFailed(reason: .aliasOwnedElsewhere)
        t.learnLedgerUntrusted(kind: .corrupt)
      }
      let events = box.values
      #expect(events.count == 9)
      #expect(Set(events.map(\.name)) == Set(Self.contract.keys))
      for event in events {
        let expected = try #require(Self.contract[event.name])
        #expect(Self.keys(event) == expected, "\(event.name): \(Self.keys(event).sorted())")
      }
      // The raw dictionary the SDK receives has the same keys: nothing rides
      // outside the typed buckets (an array or nested dictionary would).
      for (name, props) in box.rawValues {
        let expected = try #require(Self.contract[name])
        #expect(Set(props.keys) == expected, "\(name) raw keys")
        for (key, value) in props {
          #expect(value is String || value is Int, "\(name).\(key) is \(type(of: value))")
        }
      }
    }

    @MainActor
    @Test("values are the enum raw values and the counts travel as Int")
    func valuesAreClosedVocabulary() throws {
      let box = Self.capture {
        TelemetryService.shared.learnObservationEnded(
          reason: .editDistanceExceeded, settledBursts: 2, appClass: .manualAccessibility,
          durationMs: 61_000)
        TelemetryService.shared.learnJudged(
          arm: .afm, outcome: .deadline, candidates: 4, accepted: 0, latencyMs: 5001,
          queueWaitMs: 120)
        TelemetryService.shared.learnResolved(
          decision: .rejected, surface: .pending, state: .existingWord, outcome: .tombstoned)
      }
      let ended = try #require(
        box.values.first { $0.name == "custom_words.learn_observation_ended" })
      #expect(ended.stringProps["reason"] == "edit_distance_exceeded")
      #expect(ended.stringProps["app_class"] == "manual_accessibility")
      #expect(ended.intProps["settled_bursts"] == 2 && ended.intProps["duration_ms"] == 61_000)
      let judged = try #require(box.values.first { $0.name == "custom_words.learn_judged" })
      #expect(judged.stringProps["arm"] == "afm" && judged.stringProps["outcome"] == "deadline")
      #expect(judged.intProps["candidates"] == 4 && judged.intProps["accepted"] == 0)
      #expect(judged.intProps["latency_ms"] == 5001 && judged.intProps["queue_wait_ms"] == 120)
      let resolved = try #require(box.values.first { $0.name == "custom_words.learn_resolved" })
      #expect(
        resolved.stringProps["decision"] == "rejected"
          && resolved.stringProps["surface"] == "pending")
      #expect(
        resolved.stringProps["state"] == "existing_word"
          && resolved.stringProps["outcome"] == "tombstoned")
    }
  }

#endif

/// The closed vocabularies, testable without the DEBUG hooks so the Release
/// lane executes this contract too.
@Suite("learn-from-edits telemetry vocabularies (#996)", .tags(.observabilityContract))
struct LearnFromEditsTelemetryVocabularyTests {
  typealias T = TelemetryService.LearnFromEditsTelemetry

  @Test(
    "the vocabularies are the plan's tokens, and a judge bypass maps to its own outcome, never to a verdict"
  )
  func vocabularies() {
    #expect(
      T.SkipReason.allCases.map(\.rawValue) == [
        "toggle_off", "watch_active", "model_unavailable", "language_unsupported",
        "app_blocklisted", "destination_mismatch", "secure_field", "no_focused_element",
      ])
    #expect(
      T.AppClass.allCases.map(\.rawValue) == [
        "native", "manual_accessibility", "browser", "other",
      ])
    #expect(T.Arm.allCases.map(\.rawValue) == ["rules", "afm", "classifier"])
    #expect(
      T.JudgeOutcome.allCases.map(\.rawValue) == [
        "verdict", "unavailable", "not_granted", "deadline", "cancelled", "malformed",
      ])
    #expect(T.TargetState.allCases.map(\.rawValue) == ["existing_word", "new_word"])
    #expect(T.Decision.allCases.map(\.rawValue) == ["accepted", "rejected"])
    #expect(T.Surface.allCases.map(\.rawValue) == ["card", "pending"])
    #expect(
      T.ResolutionOutcome.allCases.map(\.rawValue) == [
        "added", "alias_added", "pack_override", "already_landed", "tombstoned",
      ])
    #expect(
      T.SaveFailure.allCases.map(\.rawValue) == [
        "alias_owned_elsewhere", "target_gone", "vocabulary_write_failed",
        "ledger_write_failed", "ledger_untrusted",
      ])
    #expect(
      T.LedgerUntrustedKind.allCases.map(\.rawValue) == [
        "unreadable", "corrupt", "unsupported_version", "unknown_status",
        "durability_unconfirmed",
      ])
    // Every bypass kind has its own outcome; the mapping is total.
    for bypass in CorrectionJudgeBypass.allCases {
      let mapped = T.JudgeOutcome(.bypass(bypass))
      #expect(mapped != .verdict, "\(bypass)")
      #expect(
        mapped.rawValue
          == bypass.rawValue.replacingOccurrences(of: "notGranted", with: "not_granted"),
        "\(bypass)")
    }
    #expect(T.JudgeOutcome(.verdict([])) == .verdict)
  }
}
