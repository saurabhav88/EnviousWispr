import EnviousWisprServices
import Foundation
import Testing

#if DEBUG

  /// #2951: the `custom_words_imported` payload contract. The key set is frozen
  /// so a renamed or added property is a deliberate change with a knowledge
  /// row behind it, and the reader's query (`analytics-operations.md` FACT:
  /// app-posthog-events) never silently reads an absent key as zero.
  @Suite("custom_words_imported payload (#2951)", .serialized, .tags(.observabilityContract))
  struct CustomWordsImportedTelemetryTests {
    final class EventBox: @unchecked Sendable {
      private let lock = NSLock()
      private var stored: [CapturedTelemetryEvent] = []
      func append(_ event: CapturedTelemetryEvent) { lock.withLock { stored.append(event) } }
      var values: [CapturedTelemetryEvent] { lock.withLock { stored } }
    }

    static let frozenKeys: Set<String> = [
      "source", "count_found", "count_imported", "count_skipped", "$value",
    ]

    @MainActor
    private static func capture(_ emit: () -> Void) -> [CapturedTelemetryEvent] {
      let box = EventBox()
      TelemetryService.shared.testEventHook = { @Sendable event in
        if event.name == "custom_words_imported" { box.append(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }
      emit()
      return box.values
    }

    @MainActor
    @Test("the key set is exactly the five contract keys, and $value is the landed count")
    func keySetIsFrozenAndValueIsImported() throws {
      let events = Self.capture {
        TelemetryService.shared.customWordsImported(
          source: "wispr-flow", found: 12, imported: 9, skipped: 3)
      }

      #expect(events.count == 1, "the emitter must fire exactly once")
      let event = try #require(events.first)
      let keys = Set(event.stringProps.keys).union(event.intProps.keys)
      #expect(keys == Self.frozenKeys, "keys drifted: \(keys.sorted())")
      #expect(event.stringProps["source"] == "wispr-flow")
      #expect(event.intProps["count_found"] == 12)
      #expect(event.intProps["count_imported"] == 9)
      #expect(event.intProps["count_skipped"] == 3)
      #expect(
        event.intProps["$value"] == 9, "$value mirrors count_imported, as contacts_imported does")
      #expect(event.doubleProps.isEmpty && event.boolProps.isEmpty, "counts travel as Int")
    }
  }

#endif
