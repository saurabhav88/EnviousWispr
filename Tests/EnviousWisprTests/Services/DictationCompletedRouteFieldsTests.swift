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

    // MARK: - #2970 seconds travel as numbers

    /// The four `*_seconds` properties are Double on the wire, the same type as
    /// `$value`; none of them is a formatted String. Observed through the DEBUG
    /// hook, which derives from the payload PostHog receives.
    @Test("e2e, recording, asr and llm seconds are Double, not formatted Strings")
    func secondsAreDouble() throws {
      let box = Box()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated {
          if event.name == "dictation.completed" { box.event = event }
        }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      TelemetryService.shared.reportDictationCompleted(
        transcript: Self.transcriptOpeningAllFourGates(), inputMode: "ptt",
        recordingSeconds: 2.5)

      let event = try #require(box.event)
      #expect(event.doubleProps["e2e_seconds"] == 1.0)
      #expect(event.doubleProps["$value"] == 1.0)
      #expect(event.doubleProps["recording_seconds"] == 2.5)
      #expect(event.doubleProps["asr_seconds"] == 0.4)
      #expect(event.doubleProps["llm_seconds"] == 0.3)
      for key in ["e2e_seconds", "recording_seconds", "asr_seconds", "llm_seconds"] {
        #expect(event.stringProps[key] == nil, "\(key) must not travel as a String")
      }
    }

    // MARK: - #1846 take key on both completion events

    /// ONE argument to `reportDictationCompleted` has to reach BOTH events it
    /// fans out to. `llm.polish_completed` is gated on its own metric being
    /// present, so this supplies metrics that open that gate and asserts every
    /// event carries the same key. (Until #2958 phase 2 the fan-out was four
    /// events; `asr.completed` and `paste.completed` now ride the terminal row,
    /// see `foldedFieldsRideTheTerminalRow` below.)
    ///
    /// Observed through the DEBUG hook, which as of #1846 derives from the payload
    /// PostHog actually receives. Before that, `reportDictationCompleted` emitted a
    /// parallel dictionary under the `dictation.completed` name while the real payload
    /// was built with no hook at all — a test here could have passed with the
    /// production line deleted.
    @Test("the take key reaches both completion events from one argument")
    func takeKeyReachesBothCompletionEvents() throws {
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
        names == ["dictation.completed", "llm.polish_completed"],
        "exactly the two fan-out events; a retired row reappearing or the polish gate staying shut both fail here — saw \(names.sorted())"
      )
      for event in seen.events {
        #expect(
          event.stringProps["take_id"] == Self.takeID,
          "\(event.name) must carry the take key")
      }
    }

    /// Absent on both, never an empty string.
    @Test("both completion events omit the take key entirely when there is no take")
    func bothOmitTheTakeKeyWhenNil() throws {
      let seen = EventsBox()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { seen.events.append(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      TelemetryService.shared.reportDictationCompleted(
        transcript: Self.transcriptOpeningAllFourGates(),
        inputMode: "ptt",
        takeID: nil)

      #expect(seen.events.count == 2, "same two events, so the nil suppressed nothing")
      for event in seen.events {
        #expect(
          event.stringProps["take_id"] == nil,
          "\(event.name) must OMIT take_id, not send an empty string")
      }
    }

    /// #1914: `ollama_remote` is scoped to ONE of the two completion events.
    /// The take-key tests above prove both fire, so asserting the other one is
    /// empty here is a real exclusion rather than a vacuous pass.
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

      #expect(seen.events.count == 2, "both gates must open for the exclusion to mean anything")
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

    /// A transcript whose metrics open the `llm.polish_completed` gate inside
    /// `reportDictationCompleted` (a positive LLM latency with a provider) AND
    /// the two fold gates on `dictation.completed` (a non-nil ASR latency; a
    /// paste tier plus latency). Without all three, a test claiming full
    /// coverage would silently assert over one event or one half of the row.
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

    /// The same all-gates transcript with a completed REMOTE Ollama polish on it.
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

    @Test("#2664: the applied input channel threads into dictation.completed; 0 travels, nil omits")
    func inputChannelThreadedAsIntProp() {
      let box = Box()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { box.event = event }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      TelemetryService.shared.reportDictationCompleted(
        transcript: Transcript(text: "hello"), inputMode: "ptt",
        captureNativeChannelCount: 2, captureInputChannel: 1)
      #expect(box.event?.intProps["capture_input_channel"] == 1)

      // 0 is the measured default channel and must travel (it is the reading
      // that says "the setting was not applied on this take").
      TelemetryService.shared.reportDictationCompleted(
        transcript: Transcript(text: "hello"), inputMode: "ptt", captureInputChannel: 0)
      #expect(box.event?.intProps["capture_input_channel"] == 0)

      TelemetryService.shared.reportDictationCompleted(
        transcript: Transcript(text: "hello"), inputMode: "ptt")
      #expect(box.event?.intProps["capture_input_channel"] == nil)
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

    /// Collects EVERY event, not just the last. `llm.polish_completed` and
    /// `dictation.completed` both fire from one `reportDictationCompleted`, so a
    /// last-write-wins box would assert against whichever happened to land
    /// second — a test that reads a different event than it names.
    private final class EventLog: @unchecked Sendable {
      var events: [CapturedTelemetryEvent] = []
    }

    @Test("#1921 language resolution reaches the real dictation.completed payload")
    func languageResolutionReachesTheTerminalRow() throws {
      let log = EventLog()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { log.events.append(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      // `pasteTier` and `pasteLatencyMs` are what open the real paste fold
      // gate on `dictation.completed`; the two #1921 values ride the same metrics.
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

      let rows = log.events.filter { $0.name == "dictation.completed" }
      #expect(rows.count == 1, "exactly one dictation.completed, got \(rows.count)")
      let props = try #require(rows.first).stringProps

      #expect(props["language_resolution_source"] == "document")
      #expect(props["language_confidence_bucket"] == "f70to90")
      // Exact spelling. An alias would be silently unqueryable in PostHog.
      #expect(props.keys.contains("language_source") == false)
      #expect(props.keys.contains("confidence_bucket") == false)
      #expect(props.keys.contains("resolution_source") == false)
    }

    // MARK: - #2614 cleanup-language telemetry, end to end

    @Test(
      "#2614 the cleanup language, source and bucket reach the real dictation.completed payload")
    func cleanupLanguageReachesDictationCompleted() throws {
      let log = EventLog()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { log.events.append(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      var metrics = ExecutionMetrics()
      metrics.cleanupLanguage = "nl"
      metrics.cleanupLanguageSource = "dictation"
      metrics.cleanupLanguageBucket = "ge90"
      var transcript = Transcript(text: "hello")
      transcript.metrics = metrics

      TelemetryService.shared.reportDictationCompleted(
        transcript: transcript, inputMode: "ptt")

      let completed = log.events.filter { $0.name == "dictation.completed" }
      #expect(completed.count == 1, "exactly one dictation.completed, got \(completed.count)")
      let props = try #require(completed.first).stringProps
      #expect(props["cleanup_language"] == "nl")
      #expect(props["cleanup_language_source"] == "dictation")
      #expect(props["cleanup_language_bucket"] == "ge90")
    }

    @Test("#2614 a transcript without the cleanup fields omits all three keys")
    func absentCleanupLanguageOmitsKeys() throws {
      let log = EventLog()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { log.events.append(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      TelemetryService.shared.reportDictationCompleted(
        transcript: Transcript(text: "hello"), inputMode: "ptt")

      let props = try #require(log.events.first { $0.name == "dictation.completed" }).stringProps
      #expect(props.keys.contains("cleanup_language") == false)
      #expect(props.keys.contains("cleanup_language_source") == false)
      #expect(props.keys.contains("cleanup_language_bucket") == false)
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

      let rows = log.events.filter { $0.name == "dictation.completed" }
      #expect(rows.count == 1)
      let props = try #require(rows.first).stringProps
      #expect(props.keys.contains("language_resolution_source") == false)
      #expect(props.keys.contains("language_confidence_bucket") == false)
    }

    // MARK: - #2958 phase 2, the ASR and paste rows folded onto the terminal row

    /// The two retired rows' payloads ride `dictation.completed` under the
    /// names the plan fixed: `cold_start` / `char_count` take the `asr_` prefix,
    /// `latency_ms` becomes `paste_latency_ms` with a `paste_seconds` twin, and
    /// every other key keeps its old name. Distinctive values on purpose, so a
    /// field dropped or renamed in the fold cannot pass by coincidence.
    @Test("#2958 phase 2: the ASR and paste facts ride dictation.completed under the fixed names")
    func foldedFieldsRideTheTerminalRow() throws {
      let log = EventLog()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { log.events.append(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      var metrics = ExecutionMetrics(
        asrLatencySeconds: 0.4, pasteTier: "cgevent", pasteLatencyMs: 1234,
        coldStart: true, streamingMode: true, e2eSeconds: 2.5,
        tailDroppedMs: 37, tailClipClassification: "suspected_asr_drop",
        asrLastTokenGapMs: 410, streamingEffective: false)
      metrics.streamingDegradeReason = "flush_empty"
      metrics.caretContextOutcome = "captured"
      metrics.casingDeadlinePhase = "oracle_fetch"
      var transcript = Transcript(text: "hello there")
      transcript.metrics = metrics

      TelemetryService.shared.reportDictationCompleted(
        transcript: transcript, inputMode: "ptt", takeID: Self.takeID)

      let names = Set(log.events.map(\.name))
      #expect(
        names == ["dictation.completed"],
        "no polish gate opened and no retired row fired — saw \(names.sorted())")
      let row = try #require(log.events.first)

      // ASR half.
      #expect(row.boolProps["asr_cold_start"] == true)
      #expect(row.intProps["asr_char_count"] == "hello there".count)
      #expect(row.doubleProps["asr_seconds"] == 0.4)
      #expect(row.intProps["tail_dropped_ms"] == 37)
      #expect(row.stringProps["tail_clip_class"] == "suspected_asr_drop")
      #expect(row.intProps["asr_last_token_gap_ms"] == 410)
      #expect(
        row.boolProps["streaming_requested"] == true,
        "restated from streamingMode when the effective fact is present")
      #expect(row.boolProps["streaming_effective"] == false)
      #expect(row.stringProps["streaming_degrade_reason"] == "flush_empty")

      // Paste half.
      #expect(row.stringProps["paste_result"] == "cgevent")
      #expect(row.intProps["paste_latency_ms"] == 1234)
      #expect(row.doubleProps["paste_seconds"] == 1.234)
      #expect(row.stringProps["caret_context"] == "captured")
      #expect(row.stringProps["casing_deadline_phase"] == "oracle_fetch")

      // The retired rows' own copies of terminal keys do not come along.
      for dropped in [
        "backend", "tier", "latency_seconds", "latency_ms", "cold_start", "char_count",
      ] {
        #expect(
          row.stringProps[dropped] == nil && row.intProps[dropped] == nil
            && row.doubleProps[dropped] == nil && row.boolProps[dropped] == nil,
          "\(dropped) must not ride the terminal row under its retired name")
      }
      #expect(row.doubleProps["$value"] == 2.5, "$value stays e2e, never the ASR or paste latency")
      #expect(row.stringProps["take_id"] == Self.takeID)
    }

    /// The fold gates match the retired rows' gates exactly: no ASR latency
    /// means no `asr_*` fold keys (the `asr.completed` row was skipped), and no
    /// paste latency means no `paste_latency_ms` even when `paste_result` is
    /// set from the tier (the `paste.completed` row was skipped). A reader
    /// filtering on `paste_latency_ms` therefore sees the population the old
    /// row name gave it.
    @Test(
      "#2958 phase 2: a fold half stays off the row when its retired gate would have stayed shut")
    func foldHalvesFollowTheRetiredGates() throws {
      let log = EventLog()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { log.events.append(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      var transcript = Transcript(text: "hello")
      transcript.metrics = ExecutionMetrics(
        pasteTier: "clipboard_only", coldStart: true, tailDroppedMs: 37)

      TelemetryService.shared.reportDictationCompleted(
        transcript: transcript, inputMode: "ptt")

      let row = try #require(log.events.first { $0.name == "dictation.completed" })
      #expect(
        row.stringProps["paste_result"] == "clipboard_only",
        "tier alone still sets paste_result, as before")
      #expect(row.intProps["paste_latency_ms"] == nil)
      #expect(row.doubleProps["paste_seconds"] == nil)
      #expect(row.boolProps["asr_cold_start"] == nil)
      #expect(row.intProps["asr_char_count"] == nil)
      #expect(row.intProps["tail_dropped_ms"] == nil)
    }

  #endif
}
