import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

#if DEBUG

  /// #996 §4: the seven learn-from-edits payload contracts. Key sets are frozen
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
      // The watcher's three carry the paste's `take_id` when it has one (#3105),
      // the join key to that take's `dictation.completed`; absent otherwise.
      "custom_words.learn_skipped": ["reason", "take_id"],
      "custom_words.learn_observation_ended": [
        "reason", "settled_bursts", "app_class", "duration_ms", "unfinished_edits", "take_id",
        // #3105: why the watch lost the text, counts only, when it did.
        "region_side", "region_hits", "value_rows", "needle_distinct_units", "needle_longest_run",
        "edit_budget_ratio",
      ],
      // `queue_wait_ms` rides only when the arm measured it (see the second test).
      "custom_words.learn_judged": [
        "arm", "outcome", "candidates", "accepted", "latency_ms", "queue_wait_ms", "take_id",
      ],
      "custom_words.learn_save_failed": ["reason"],
      // Auto-learn (2026-09-21 plan §3.1 step 11).
      "custom_words.learn_added": ["state"],
      "custom_words.learn_undo_shown": [],
      "custom_words.learn_undone": ["kind", "outcome"],
    ]

    @MainActor
    @Test("every event fires once with exactly the contract keys and no untyped property")
    func everyEventFrozenKeys() throws {
      let box = Self.capture {
        let t = TelemetryService.shared
        t.learnSkipped(reason: .destinationMismatch, takeID: "TAKE-1")
        t.learnObservationEnded(
          reason: .settled, settledBursts: 1, appClass: .native, durationMs: 4200, unfinishedEdits: 0,
          takeID: "TAKE-1",
          regionDetail: PastedRegionEndDetail(
            region: .init(
              side: "after", hits: 0, needleUTF16: 64, valueUTF16: 1844, valueRows: 39,
              distinctUnits: 3, longestRun: 60),
            editBudgetRatio: 1.4))
        t.learnJudged(
          arm: .rules, outcome: .verdict, candidates: 3, accepted: 1, latencyMs: 812,
          queueWaitMs: 0, takeID: "TAKE-1")
        t.learnSaveFailed(reason: .aliasOwnedElsewhere)
        t.learnAdded(state: .packOverride)
        t.learnUndoShown()
        t.learnUndone(kind: .updated, outcome: .alreadyChanged)
      }
      let events = box.values
      #expect(events.count == 7)
      let joined = events.filter { $0.stringProps["take_id"] != nil }
      #expect(Set(joined.map(\.name)) == [
        "custom_words.learn_skipped", "custom_words.learn_observation_ended", "custom_words.learn_judged",
      ])
      #expect(joined.allSatisfy { $0.stringProps["take_id"] == "TAKE-1" })
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
          // `edit_budget_ratio` (#3105) is the one Double: a ratio rounded to 0.1.
          let typed = key == "edit_budget_ratio" ? value is Double : (value is String || value is Int)
          #expect(typed, "\(name).\(key) is \(type(of: value))")
        }
      }
    }

    @MainActor
    @Test("values are the enum raw values and the counts travel as Int")
    func valuesAreClosedVocabulary() throws {
      let box = Self.capture {
        TelemetryService.shared.learnObservationEnded(
          reason: .editDistanceExceeded, settledBursts: 2, appClass: .manualAccessibility,
          durationMs: 61_000, unfinishedEdits: 1)
        TelemetryService.shared.learnJudged(
          arm: .afm, outcome: .deadline, candidates: 4, accepted: 0, latencyMs: 5001,
          queueWaitMs: 120)
        TelemetryService.shared.learnJudged(
          arm: .rules, outcome: .verdict, candidates: 1, accepted: 1, latencyMs: 3,
          queueWaitMs: nil)
        TelemetryService.shared.learnUndone(kind: .updated, outcome: .alreadyChanged)
        TelemetryService.shared.learnSaveFailed(reason: .vocabularyWriteFailed)
      }
      let ended = try #require(
        box.values.first { $0.name == "custom_words.learn_observation_ended" })
      #expect(ended.stringProps["reason"] == "edit_distance_exceeded")
      #expect(ended.stringProps["app_class"] == "manual_accessibility")
      #expect(ended.intProps["settled_bursts"] == 2 && ended.intProps["duration_ms"] == 61_000)
      #expect(ended.intProps["unfinished_edits"] == 1)
      #expect(ended.stringProps["take_id"] == nil, "no take: the key is absent")
      let judged = try #require(box.values.first { $0.name == "custom_words.learn_judged" })
      #expect(judged.stringProps["arm"] == "afm" && judged.stringProps["outcome"] == "deadline")
      #expect(judged.intProps["candidates"] == 4 && judged.intProps["accepted"] == 0)
      #expect(judged.intProps["latency_ms"] == 5001 && judged.intProps["queue_wait_ms"] == 120)
      // Unmeasured queue wait: the key is absent, never zero.
      let unmeasured = try #require(
        box.values.last { $0.name == "custom_words.learn_judged" })
      #expect(unmeasured.intProps["queue_wait_ms"] == nil)
      #expect(unmeasured.intProps.keys.contains("queue_wait_ms") == false)
      let undone = try #require(box.values.first { $0.name == "custom_words.learn_undone" })
      #expect(
        undone.stringProps["kind"] == "updated"
          && undone.stringProps["outcome"] == "already_changed")
      let failed = try #require(box.values.first { $0.name == "custom_words.learn_save_failed" })
      #expect(failed.stringProps["reason"] == "vocabulary_write_failed")
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
        "toggle_off", "watch_active", "model_unavailable",
        "destination_mismatch", "secure_field", "no_focused_element",
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
    #expect(
      T.SaveFailure.allCases.map(\.rawValue) == [
        "alias_owned_elsewhere", "target_gone", "vocabulary_write_failed",
      ])
    #expect(T.AddedState.allCases.map(\.rawValue) == ["existing_word", "new_word", "pack_override"])
    #expect(T.UndoKind.allCases.map(\.rawValue) == ["added", "updated"])
    #expect(T.UndoOutcome.allCases.map(\.rawValue) == ["undone", "already_changed", "failed"])
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
