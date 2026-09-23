import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// `dictation.last_reused` carries shape, never content (#3106).
///
/// When this fails, the "Last dictation reuse" insight reads a field that is not there, or a
/// dictated word, a row id or an app name reaches the vendor.
#if DEBUG

  @MainActor
  @Suite("Last dictation reuse telemetry contract (#3106)", .tags(.observabilityContract))
  struct LastDictationTelemetryContractTests {

    private final class EventBox: @unchecked Sendable {
      var events: [CapturedTelemetryEvent] = []
    }

    @Test("Exactly three string fields, from closed vocabularies, and nothing else")
    func payloadShape() {
      let box = EventBox()
      TelemetryService.shared.testEventHook = { box.events.append($0) }
      defer { TelemetryService.shared.testEventHook = nil }

      TelemetryService.shared.lastDictationReused(
        action: "paste", source: "chord", outcome: "dispatched")

      let event = box.events.first
      #expect(box.events.count == 1)
      #expect(event?.name == "dictation.last_reused")
      #expect(Set(event.map { Array($0.stringProps.keys) } ?? []) == ["action", "source", "outcome"])
      #expect(event?.intProps.isEmpty == true)
      #expect(event?.doubleProps.isEmpty == true)
      #expect(event?.boolProps.isEmpty == true)
    }

    @Test("The vocabularies are the approved ones")
    func vocabularies() {
      #expect(Set(LastDictationAction.Action.allCases.map(\.rawValue)) == ["paste", "copy"])
      #expect(Set(LastDictationAction.Source.allCases.map(\.rawValue)) == ["menu", "chord"])
      #expect(
        Set(LastDictationAction.Outcome.allCases.map(\.rawValue)) == [
          "dispatched", "copied", "dispatch_failed", "clipboard_busy", "no_dictation",
          "own_window", "target_gone", "recording", "ax_denied", "keys_held", "focus_lost",
          "cancelled", "write_failed",
        ])
    }
  }

#endif
