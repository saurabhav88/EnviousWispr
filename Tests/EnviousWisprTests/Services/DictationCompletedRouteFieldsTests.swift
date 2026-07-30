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
        routeReason: "btOutputUserSelectedDevice",
        inputSelectionMode: "explicit", outputTransport: "bluetooth",
        routeResolutionSource: "app_derived")

      let props = box.event?.stringProps
      #expect(props?["selected_transport"] == "bluetooth")
      #expect(props?["effective_transport"] == "built_in")
      #expect(props?["route_reason"] == "btOutputUserSelectedDevice")
      #expect(props?["input_selection_mode"] == "explicit")
      #expect(props?["output_transport"] == "bluetooth")
      #expect(props?["route_resolution_source"] == "app_derived")
      // Absent fallback reason → key omitted.
      #expect(props?["route_fallback_reason"] == nil)
    }

    // MARK: - #1846 take key on all four completion events

    /// ONE argument to `reportDictationCompleted` has to reach all FOUR events it
    /// fans out to. `asr.completed`, `llm.polish_completed` and `paste.completed` are
    /// each gated on their own metric being present, so this supplies metrics that
    /// open all three gates and asserts every event carries the same key.
    ///
    /// Observed through the DEBUG hook, which as of #1846 derives from the payload
    /// PostHog actually receives. Before that, `reportDictationCompleted` emitted a
    /// parallel dictionary under the `dictation.completed` name while the real payload
    /// was built with no hook at all — a test here could have passed with the
    /// production line deleted.
    @Test("the take key reaches all four completion events from one argument")
    func takeKeyReachesAllFourCompletionEvents() throws {
      let seen = EventsBox()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { seen.events.append(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      TelemetryService.shared.reportDictationCompleted(
        transcript: Self.transcriptOpeningAllFourGates(),
        inputMode: "ptt",
        takeID: Self.takeID)

      let names = Set(seen.events.map(\.name))
      #expect(
        names == [
          "dictation.completed", "asr.completed", "llm.polish_completed", "paste.completed",
        ],
        "all four gates must open, or the assertions below cover fewer events than claimed — saw \(names.sorted())"
      )
      for event in seen.events {
        #expect(
          event.stringProps["take_id"] == Self.takeID,
          "\(event.name) must carry the take key")
      }
    }

    /// Absent on every one of the four, never an empty string.
    @Test("all four completion events omit the take key entirely when there is no take")
    func allFourOmitTheTakeKeyWhenNil() throws {
      let seen = EventsBox()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { seen.events.append(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      TelemetryService.shared.reportDictationCompleted(
        transcript: Self.transcriptOpeningAllFourGates(),
        inputMode: "ptt",
        takeID: nil)

      #expect(seen.events.count == 4, "same four events, so the nil suppressed nothing")
      for event in seen.events {
        #expect(
          event.stringProps["take_id"] == nil,
          "\(event.name) must OMIT take_id, not send an empty string")
      }
    }

    private final class EventsBox: @unchecked Sendable {
      var events: [CapturedTelemetryEvent] = []
    }

    private static let takeID = "9f2c1d84-6b3a-4e07-9c51-0a7d2e6f1b33"

    /// A transcript whose metrics open the `asr.completed`, `llm.polish_completed`
    /// and `paste.completed` gates inside `reportDictationCompleted`: a non-nil ASR
    /// latency, a positive LLM latency with a provider, and a paste tier plus
    /// latency. Without all three, a test claiming four-event coverage would
    /// silently assert over one event.
    private static func transcriptOpeningAllFourGates() -> Transcript {
      Transcript(
        text: "hello",
        polishedText: "Hello.",
        llmProvider: "openai",
        llmModel: "gpt-4o-mini",
        metrics: ExecutionMetrics(
          asrLatencySeconds: 0.4,
          llmLatencySeconds: 0.3,
          pasteTier: "cgevent",
          pasteLatencyMs: 12,
          e2eSeconds: 1.0))
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

    @Test("#1523: channel count threads into dictation.completed as an int prop")
    func channelCountThreadedAsIntProp() {
      let box = Box()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { box.event = event }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      TelemetryService.shared.reportDictationCompleted(
        transcript: Transcript(text: "hello"), inputMode: "ptt",
        captureNativeChannelCount: 2)

      #expect(box.event?.intProps["capture_native_channel_count"] == 2)
    }

    @Test("#1523: a nil channel count omits the int key")
    func channelCountOmittedWhenNil() {
      let box = Box()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { box.event = event }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      TelemetryService.shared.reportDictationCompleted(
        transcript: Transcript(text: "hello"), inputMode: "ptt")

      #expect(box.event?.intProps["capture_native_channel_count"] == nil)
    }

    @Test("#1707: asrSalvageOutcome threads into dictation.completed when a salvage was attempted")
    func asrSalvageOutcomeThreaded() {
      let box = Box()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { box.event = event }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      TelemetryService.shared.reportDictationCompleted(
        transcript: Transcript(text: "hello"), inputMode: "ptt",
        asrSalvageOutcome: "rewarm_succeeded")

      #expect(box.event?.stringProps["asr_salvage_outcome"] == "rewarm_succeeded")
    }

    @Test("#1707: an uninterrupted completion omits the asr_salvage_outcome key")
    func asrSalvageOutcomeOmittedWhenNil() {
      let box = Box()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { box.event = event }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      TelemetryService.shared.reportDictationCompleted(
        transcript: Transcript(text: "hello"), inputMode: "ptt")

      #expect(box.event?.stringProps["asr_salvage_outcome"] == nil)
    }

    @Test(
      "#1707 Phase 2: asrRetryOutcome threads into dictation.completed when a retry rescued the take"
    )
    func asrRetryOutcomeThreaded() {
      let box = Box()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { box.event = event }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      TelemetryService.shared.reportDictationCompleted(
        transcript: Transcript(text: "hello"), inputMode: "ptt",
        asrRetryOutcome: "retry_succeeded")

      #expect(box.event?.stringProps["asr_retry_outcome"] == "retry_succeeded")
    }

    @Test(
      "#1707 Phase 2: a first-attempt success (no Phase-2 retry) omits the asr_retry_outcome key")
    func asrRetryOutcomeOmittedWhenNil() {
      let box = Box()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { box.event = event }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      TelemetryService.shared.reportDictationCompleted(
        transcript: Transcript(text: "hello"), inputMode: "ptt")

      #expect(box.event?.stringProps["asr_retry_outcome"] == nil)
    }
  #endif
}
