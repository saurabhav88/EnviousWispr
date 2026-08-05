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

    /// #1914: `ollama_remote` is scoped to ONE of the four completion events.
    /// The take-key tests above prove all four fire, so asserting the other
    /// three are empty here is a real exclusion rather than a vacuous pass.
    ///
    /// The founder tabled failed and skipped remoteness on 2026-08-03. That
    /// tabling has no compiler behind it: adding the key to another emitter is
    /// a two-line change that nothing else would notice, which is what this
    /// freezes.
    @Test("only llm.polish_completed carries ollama_remote in the completion fan-out")
    func onlyCompletedPolishCarriesRemoteness() throws {
      let seen = EventsBox()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { seen.events.append(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      TelemetryService.shared.reportDictationCompleted(
        transcript: Self.transcriptOpeningAllFourGatesRemotely(),
        inputMode: "ptt",
        takeID: Self.takeID)

      #expect(seen.events.count == 4, "all four gates must open for the exclusion to mean anything")
      for event in seen.events {
        if event.name == "llm.polish_completed" {
          #expect(event.boolProps["ollama_remote"] == true)
        } else {
          #expect(
            event.boolProps["ollama_remote"] == nil,
            "\(event.name) must not carry remoteness")
        }
      }
    }

    /// The nil arm through the REAL report path, not a direct emitter call. A
    /// cloud dictation reaches `llm.polish_completed` with no remoteness on its
    /// metrics, and the key must be absent rather than `false`.
    ///
    /// Added after a mutation control found the gap: replacing the omission with
    /// `ollamaRemote ?? false` left this whole suite green, because the only
    /// transcript it fed through the fan-out already carried `true`. A suite that
    /// asserts an exclusion needs the negative INPUT as well as the negative
    /// assertion.
    @Test("a cloud dictation reaches the completed polish event with no remoteness key")
    func cloudDictationOmitsRemotenessThroughTheReportPath() throws {
      let seen = EventsBox()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { seen.events.append(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      TelemetryService.shared.reportDictationCompleted(
        transcript: Self.transcriptOpeningAllFourGates(),
        inputMode: "ptt",
        takeID: Self.takeID)

      let polish = try #require(seen.events.first { $0.name == "llm.polish_completed" })
      #expect(polish.boolProps["ollama_remote"] == nil)
      #expect(polish.stringProps["provider"] == "openai", "the cloud arm really did run")
    }

    /// The two emitters the tabling is ABOUT. Neither takes a remoteness
    /// argument, so this asserts the emitted payloads rather than the call
    /// sites: adding the key to either builder fails here.
    @Test("neither the failed nor the skipped polish event carries ollama_remote")
    func failedAndSkippedPolishCarryNoRemoteness() throws {
      let seen = EventsBox()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { seen.events.append(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      TelemetryService.shared.polishFailed(
        provider: "ollama", model: "gpt-oss:20b-cloud",
        reason: "empty_response", isTimeout: false)
      TelemetryService.shared.polishSkipped(
        provider: "ollama", reason: "local_polish_ollama_server_down")

      let names = Set(seen.events.map(\.name))
      #expect(
        names == ["llm.polish_failed", "llm.polish_skipped"],
        "both emitters must have fired — saw \(names.sorted())")
      for event in seen.events {
        #expect(
          event.boolProps["ollama_remote"] == nil,
          "\(event.name) must not carry remoteness (founder tabling 2026-08-03)")
        #expect(event.stringProps["ollama_remote"] == nil)
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

    /// The same four-gate transcript with a completed REMOTE Ollama polish on it.
    /// Provider is `ollama` so the shape is one production can actually produce.
    private static func transcriptOpeningAllFourGatesRemotely() -> Transcript {
      Transcript(
        text: "hello",
        polishedText: "Hello.",
        llmProvider: "ollama",
        llmModel: "gpt-oss:20b-cloud",
        metrics: ExecutionMetrics(
          asrLatencySeconds: 0.4,
          llmLatencySeconds: 0.3,
          pasteTier: "cgevent",
          pasteLatencyMs: 12,
          e2eSeconds: 1.0,
          polishRanRemote: true))
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

    // MARK: - #1714 input resolution source

    @Test("input and ROUTE resolution sources ride the SAME event with distinct values")
    func inputAndRouteResolutionSourcesCoexist() {
      // These two keys are one word apart and answer different questions. If a
      // future edit ever collapses them, this is the test that fails.
      let box = Box()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { box.event = event }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      TelemetryService.shared.reportDictationCompleted(
        transcript: Transcript(text: "hello"), inputMode: "ptt",
        routeResolutionSource: "app_derived",
        inputResolutionSource: "list_fallback")

      let props = box.event?.stringProps
      #expect(props?["route_resolution_source"] == "app_derived")
      #expect(props?["input_resolution_source"] == "list_fallback")
      #expect(props?.keys.contains("resolution_source") == false)
    }

    @Test("dictation.completed omits the input resolution source when nil")
    func inputResolutionSourceOmittedWhenNil() {
      let box = Box()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { box.event = event }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      TelemetryService.shared.reportDictationCompleted(
        transcript: Transcript(text: "hello"), inputMode: "ptt")

      #expect(box.event?.stringProps.keys.contains("input_resolution_source") == false)
    }

    // MARK: - #1921 language-resolution telemetry, end to end

    /// Collects EVERY event, not just the last. `paste.completed` and
    /// `dictation.completed` both fire from one `reportDictationCompleted`, so a
    /// last-write-wins box would assert against whichever happened to land
    /// second — a test that reads a different event than it names.
    private final class EventLog: @unchecked Sendable {
      var events: [CapturedTelemetryEvent] = []
    }

    @Test("#1921 language resolution reaches the real paste.completed payload")
    func languageResolutionReachesPasteCompleted() throws {
      let log = EventLog()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { log.events.append(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      // `pasteTier` and `pasteLatencyMs` are what open the real
      // `paste.completed` gate; the two #1921 values ride the same metrics.
      // Distinctive on purpose — `document` and `f70to90` are neither the
      // default nor the value any other hop would produce by accident, so a
      // dropped field cannot pass by coincidence.
      var metrics = ExecutionMetrics(pasteTier: "cgevent", pasteLatencyMs: 12)
      metrics.languageResolutionSource = "document"
      metrics.languageConfidenceBucket = "f70to90"
      var transcript = Transcript(text: "hello")
      transcript.metrics = metrics

      TelemetryService.shared.reportDictationCompleted(
        transcript: transcript, inputMode: "ptt")

      let pasteEvents = log.events.filter { $0.name == "paste.completed" }
      #expect(pasteEvents.count == 1, "exactly one paste.completed, got \(pasteEvents.count)")
      let props = try #require(pasteEvents.first).stringProps

      #expect(props["language_resolution_source"] == "document")
      #expect(props["language_confidence_bucket"] == "f70to90")
      // Exact spelling. An alias would be silently unqueryable in PostHog.
      #expect(props.keys.contains("language_source") == false)
      #expect(props.keys.contains("confidence_bucket") == false)
      #expect(props.keys.contains("resolution_source") == false)
    }

    @Test("#1921 a transcript without the fields omits both keys entirely")
    func absentLanguageResolutionOmitsBothKeys() throws {
      let log = EventLog()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { log.events.append(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      // A transcript written before #1921 has neither field. It must not report
      // `"none"`, which is a real category meaning the app looked and found
      // nothing — otherwise the whole back catalogue reads as timed-out.
      var transcript = Transcript(text: "hello")
      transcript.metrics = ExecutionMetrics(pasteTier: "cgevent", pasteLatencyMs: 12)

      TelemetryService.shared.reportDictationCompleted(
        transcript: transcript, inputMode: "ptt")

      let pasteEvents = log.events.filter { $0.name == "paste.completed" }
      #expect(pasteEvents.count == 1)
      let props = try #require(pasteEvents.first).stringProps
      #expect(props.keys.contains("language_resolution_source") == false)
      #expect(props.keys.contains("language_confidence_bucket") == false)
    }

  #endif
}
