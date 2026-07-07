import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprServices

// #1376 — locks that the App layer's effective-device fields thread through
// `reportDictationCompleted` into the `dictation.completed` props with the
// emitted keys' presence-only semantics (populated when supplied, omitted when
// nil). The end-to-end PostHog emission is verified separately at Live UAT.
//
// `testEventHook` + `CapturedTelemetryEvent` are DEBUG-only (stripped from
// release builds), so this suite is DEBUG-gated to compile under both flavors.
@Suite("dictation.completed route fields — #1376")
@MainActor
struct DictationCompletedRouteFieldsTests {
  #if DEBUG

    private final class Box: @unchecked Sendable {
      var event: CapturedTelemetryEvent?
    }

    @Test("route fields thread into dictation.completed props when populated")
    func routeFieldsThreaded() {
      let box = Box()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { box.event = event }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      TelemetryService.shared.reportDictationCompleted(
        transcript: Transcript(text: "hello"), inputMode: "ptt",
        selectedTransport: "bluetooth", effectiveTransport: "built_in",
        routeReason: "btOutputUserSelectedBTMic",
        inputSelectionMode: "explicit", outputTransport: "bluetooth",
        routeResolutionSource: "app_derived")

      let props = box.event?.stringProps
      #expect(props?["selected_transport"] == "bluetooth")
      #expect(props?["effective_transport"] == "built_in")
      #expect(props?["route_reason"] == "btOutputUserSelectedBTMic")
      #expect(props?["input_selection_mode"] == "explicit")
      #expect(props?["output_transport"] == "bluetooth")
      #expect(props?["route_resolution_source"] == "app_derived")
      // Absent fallback reason → key omitted.
      #expect(props?["route_fallback_reason"] == nil)
    }

    @Test("Auto dictation omits route fields when nil")
    func autoOmitsFields() {
      let box = Box()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { box.event = event }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      TelemetryService.shared.reportDictationCompleted(
        transcript: Transcript(text: "hello"), inputMode: "ptt")

      let props = box.event?.stringProps
      #expect(props?["selected_transport"] == nil)
      #expect(props?["effective_transport"] == nil)
      #expect(props?["route_reason"] == nil)
      // The pre-existing input_mode key is still emitted.
      #expect(props?["input_mode"] == "ptt")
    }
  #endif
}
