import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprServices

#if DEBUG
  /// The `meeting.ended` row's shape (#3972 R11). When this fails, the founder's adoption and
  /// quality query reads a property that is missing, renamed or typed wrong, or the row carries
  /// something beyond the approved shape-only fields.
  @MainActor
  @Suite("meeting.ended: approved typed fields, nothing else (#3972)", .serialized,
    .tags(.observabilityContract))
  struct MeetingEndedTelemetryTests {
    final class Box: @unchecked Sendable {
      // Test-only capture box; the hook is called synchronously inside the emit on this actor.
      var events: [CapturedTelemetryEvent] = []
    }

    static let approvedKeys: Set<String> = [
      "outcome", "duration_bucket", "mic_track", "system_track", "engine", "speaker_count_bucket",
      "processing_seconds", "rtf", "yield_count", "gap_count", "echo_hidden_count_bucket",
      "entry_point", "disk_stopped", "summary_plan", "has_notes",
    ]

    private func capture(_ event: MeetingEndedTelemetry) -> CapturedTelemetryEvent? {
      let box = Box()
      let service = TelemetryService.shared
      let previous = service.testEventHook
      service.testEventHook = { captured in
        if captured.name == "meeting.ended" { box.events.append(captured) }
      }
      defer { service.testEventHook = previous }
      service.trackMeetingEnded(event)
      #expect(box.events.count == 1)
      return box.events.first
    }

    private func event(
      outcome: MeetingEndedTelemetry.Outcome = .ready, entry: MeetingEntryPoint? = .menu,
      duration: Double = 1_800, speakers: Int = 3, processing: Double = 90, audio: Double = 1_800,
      echo: Int = 7, disk: Bool? = false, callSound: CallSoundSummary? = nil,
      engine: MeetingEngineChoice? = .parakeet, speakerNaming: SpeakerNamingSummary? = nil,
      muteFollow: MuteFollowSummary? = nil, provenance: MeetingEndedTelemetry.Provenance? = nil,
      echoSummary: MeetingEchoSummary? = nil, liveSpeakers: MeetingLiveSpeakerSummary? = nil
    ) -> MeetingEndedTelemetry {
      MeetingEndedTelemetry(
        outcome: outcome, entryPoint: entry, durationSeconds: duration, microphoneTrack: .captured,
        callSoundTrack: .unsupported, engine: engine, speakerCount: speakers,
        processingSeconds: processing,
        audioSeconds: audio, yieldCount: 4, gapCount: 2, echoHiddenCount: echo, diskStopped: disk,
        summaryPlan: .scheduled, hasNotes: true, callSound: callSound,
        speakerNaming: speakerNaming, muteFollow: muteFollow, provenance: provenance,
        echo: echoSummary, liveSpeakers: liveSpeakers)
    }

    private static let echoKeys: Set<String> = [
      "aec_eligible_ms", "aec_passthrough_ms", "aec_init_outcome", "aec_reset_count",
      "aec_reset_reason",
    ]

    @Test(
      "#4355: an echo summary adds whole-millisecond integers, a reset count and two closed strings"
    )
    func echoFields() throws {
      // 16,000 samples = 1 s; 24,008 samples = 1,500.5 ms -> 1,500 (whole ms, rounded down once).
      let summary = MeetingEchoSummary(
        eligibleSamples: 960_008, passthroughSamples: 24_008, initOutcome: .ok, resetCount: 3,
        resetCauses: [.callRebuild: 2, .micRun: 1])
      let row = try #require(capture(event(echoSummary: summary)))
      #expect(row.intProps["aec_eligible_ms"] == 60_000)
      #expect(row.intProps["aec_passthrough_ms"] == 1_500)
      #expect(row.intProps["aec_reset_count"] == 3)
      #expect(row.stringProps["aec_init_outcome"] == "ok")
      #expect(row.stringProps["aec_reset_reason"] == "multiple")
      let keys = Set(row.stringProps.keys).union(row.intProps.keys).union(row.doubleProps.keys)
        .union(row.boolProps.keys)
      #expect(keys == Self.approvedKeys.union(Self.echoKeys))
    }

    @Test("#4355 PR C: live speaker labels add a state, a share bucket and whole counts")
    func liveSpeakerFields() throws {
      let summary = MeetingLiveSpeakerSummary(
        modelRevision: "25a90f97", state: .ready, remoteWords: 200, attributedWords: 160,
        namedSpeakers: 2, backlogSkippedMs: 1_250, updateDrops: 3, unpositionedMs: 40,
        liveWordsUnpositionedMs: 900)
      let row = try #require(capture(event(liveSpeakers: summary)))
      #expect(row.stringProps["live_speaker_state"] == "ready")
      #expect(row.stringProps["live_speaker_model_revision"] == "25a90f97")
      #expect(row.stringProps["live_attributed_share"] == "75%+")
      #expect(row.intProps["live_named_speaker_count"] == 2)
      #expect(row.intProps["live_backlog_skipped_ms"] == 1_250)
      #expect(row.intProps["live_update_drops"] == 3)
      #expect(row.intProps["live_unpositioned_ms"] == 40)
      #expect(row.intProps["live_words_unpositioned_ms"] == 900)
      // The same keys, and only those, ride the content-free Sentry breadcrumb.
      let crumb = try #require(
        TelemetryService.meetingLiveSpeakersBreadcrumbData(event(liveSpeakers: summary)))
      #expect(Set(crumb.keys) == Self.liveKeys)
      #expect(crumb["live_speaker_state"] as? String == "ready")
      #expect(TelemetryService.meetingLiveSpeakersBreadcrumbData(event()) == nil)
      let keys = Set(row.stringProps.keys).union(row.intProps.keys).union(row.doubleProps.keys)
        .union(row.boolProps.keys)
      #expect(keys == Self.approvedKeys.union(Self.liveKeys))
      // No live call words: no share (never a 0% bucket); no summary: no live key at all.
      let silent = MeetingLiveSpeakerSummary(
        modelRevision: nil, state: .absent, remoteWords: 0, attributedWords: 0, namedSpeakers: 0,
        backlogSkippedMs: 0, updateDrops: 0, unpositionedMs: 0, liveWordsUnpositionedMs: 0)
      let quiet = try #require(capture(event(liveSpeakers: silent)))
      #expect(quiet.stringProps["live_attributed_share"] == nil)
      #expect(quiet.stringProps["live_speaker_model_revision"] == nil)
      #expect(quiet.stringProps["live_speaker_state"] == "absent")
      let none = try #require(capture(event()))
      #expect(Set(none.stringProps.keys).union(none.intProps.keys).isDisjoint(with: Self.liveKeys))
    }

    private static let liveKeys: Set<String> = [
      "live_speaker_state", "live_speaker_model_revision", "live_attributed_share",
      "live_named_speaker_count", "live_backlog_skipped_ms", "live_update_drops",
      "live_unpositioned_ms", "live_words_unpositioned_ms",
    ]

    @Test("#4355: one cause names itself, none says none; no reference is a known zero")
    func echoReasonAndNoReference() throws {
      let one = MeetingEchoSummary(
        eligibleSamples: 16_000, passthroughSamples: 16_000, initOutcome: .failed, resetCount: 1,
        resetCauses: [.callLost: 1])
      let row = try #require(capture(event(echoSummary: one)))
      #expect(row.stringProps["aec_reset_reason"] == "call_lost")
      #expect(row.stringProps["aec_init_outcome"] == "failed")
      let mic = try #require(capture(event(echoSummary: .noReference)))
      #expect(mic.intProps["aec_eligible_ms"] == 0)
      #expect(mic.intProps["aec_passthrough_ms"] == 0)
      #expect(mic.intProps["aec_reset_count"] == 0)
      #expect(mic.stringProps["aec_reset_reason"] == "none")
      #expect(mic.stringProps["aec_init_outcome"] == "no_reference")
    }

    @Test("#4355: no summary sends no echo key; an unknown start sends the counts without it")
    func echoOmitted() throws {
      let none = try #require(capture(event()))
      let noneKeys = Set(none.stringProps.keys).union(none.intProps.keys)
      #expect(noneKeys.isDisjoint(with: Self.echoKeys))
      let unknownStart = MeetingEchoSummary(
        eligibleSamples: 0, passthroughSamples: 0, initOutcome: nil, resetCount: 0, resetCauses: [:])
      let row = try #require(capture(event(echoSummary: unknownStart)))
      #expect(row.stringProps["aec_init_outcome"] == nil)
      #expect(row.intProps["aec_eligible_ms"] == 0)
    }

    @Test("#4355: passthrough never exceeds eligible; every closed value is its spelling")
    func echoBoundsAndVocabulary() {
      let clamped = MeetingEchoSummary(
        eligibleSamples: 100, passthroughSamples: 500, initOutcome: .ok, resetCount: -1,
        resetCauses: [.wake: 0])
      #expect(clamped.passthroughSamples == 100)
      #expect(clamped.resetCount == 0)
      #expect(clamped.resetCauses.isEmpty && clamped.resetReason == "none")
      #expect(MeetingEchoSummary.milliseconds(samples: 15) == 0)
      #expect(MeetingEchoSummary.milliseconds(samples: 16) == 1)
      #expect(
        MeetingEchoSummary.InitOutcome.allCases.map(\.rawValue) == ["ok", "failed", "no_reference"])
      #expect(
        MeetingEchoSummary.ResetCause.allCases.map(\.rawValue) == [
          "mic_run", "mic_gap", "call_run", "call_rebuild", "call_lost", "rate_change", "wake",
          "divergence", "reference_overflow", "passthrough", "native_failure",
        ])
    }

    @Test("#4355: the Sentry breadcrumb carries exactly the aec keys, none without a summary")
    func echoBreadcrumb() throws {
      let summary = MeetingEchoSummary(
        eligibleSamples: 32_000, passthroughSamples: 0, initOutcome: .ok, resetCount: 0,
        resetCauses: [:])
      let data = try #require(TelemetryService.meetingEchoBreadcrumbData(event(echoSummary: summary)))
      #expect(Set(data.keys) == Self.echoKeys)
      #expect(data["aec_eligible_ms"] as? Int == 2_000)
      #expect(TelemetryService.meetingEchoBreadcrumbData(event()) == nil)
    }

    @Test("#4249: stop provenance adds four closed strings; Keep presses travel as a bucket",
      arguments: [(0, "0"), (1, "1"), (2, "2"), (3, "3+"), (9, "3+")])
    func provenanceFields(keeps: Int, bucket: String) throws {
      let row = try #require(
        capture(
          event(
            provenance: .init(
              stopReason: .callCountdown, callLink: .prompt, endTrigger: .micRelease,
              keepCount: keeps))))
      #expect(row.stringProps["stop_reason"] == "call_countdown")
      #expect(row.stringProps["call_link"] == "prompt")
      #expect(row.stringProps["end_trigger"] == "mic_release")
      #expect(row.stringProps["keep_count_bucket"] == bucket)
      let keys = Set(row.stringProps.keys).union(row.intProps.keys).union(row.doubleProps.keys)
        .union(row.boolProps.keys)
      #expect(keys == Self.approvedKeys.union(["stop_reason", "call_link", "end_trigger", "keep_count_bucket"]))
    }

    @Test("#4249: unknown provenance sends none of the four keys; a known part sends only itself")
    func provenanceOmitted() throws {
      let none = try #require(capture(event()))
      #expect(Set(none.stringProps.keys).isDisjoint(with: ["stop_reason", "call_link", "end_trigger", "keep_count_bucket"]))
      let partial = try #require(capture(event(provenance: .init(stopReason: .user))))
      #expect(partial.stringProps["stop_reason"] == "user")
      #expect(partial.stringProps["call_link"] == nil && partial.stringProps["keep_count_bucket"] == nil)
    }

    private static let speakerNameKeys: Set<String> = [
      "speaker_names_surface", "speaker_names_outcome", "auto_named_count",
    ]

    @Test("#4013: a naming summary adds two closed strings and an integer count; a known zero stays 0")
    func speakerNameFields() throws {
      let row = try #require(
        capture(
          event(
            speakerNaming: SpeakerNamingSummary(
              surface: .zoomApp, outcome: .manualOnly, autoNamedCount: 0))))
      #expect(row.stringProps["speaker_names_surface"] == "zoom_app")
      #expect(row.stringProps["speaker_names_outcome"] == "manual_only")
      #expect(row.intProps["auto_named_count"] == 0)
      #expect(row.doubleProps["auto_named_count"] == nil)
      let keys = Set(row.stringProps.keys).union(row.intProps.keys).union(row.doubleProps.keys)
        .union(row.boolProps.keys)
      #expect(keys == Self.approvedKeys.union(Self.speakerNameKeys))
    }

    @Test("#4013: no summary sends none of the three keys; an unknown fact is omitted on its own")
    func speakerNameFieldsOmitted() throws {
      let none = try #require(capture(event()))
      let all = Set(none.stringProps.keys).union(none.intProps.keys)
      #expect(all.isDisjoint(with: Self.speakerNameKeys))
      let partial = try #require(
        capture(
          event(
            speakerNaming: SpeakerNamingSummary(surface: nil, outcome: nil, autoNamedCount: 2))))
      #expect(partial.stringProps["speaker_names_surface"] == nil)
      #expect(partial.stringProps["speaker_names_outcome"] == nil)
      #expect(partial.intProps["auto_named_count"] == 2)
    }

    private static let readHealthKeys: Set<String> = [
      "speaker_reads_unusable_share_bucket", "speaker_reads_unusable_reason",
      "speaker_reads_tolerated_bucket",
    ]

    private func reads(
      attempts: Int = 100, unreadable: Int = 0, truncated: Int = 0, unresolved: Int = 0,
      tolerated: Int? = 0, walks: Int = 0, skippedPages: Int? = nil
    ) -> SpeakerNamingSummary {
      SpeakerNamingSummary(
        surface: .zoomApp, outcome: .named, autoNamedCount: 1,
        readHealth: SpeakerReadHealth(
          captureAttempts: attempts, unreadableCaptures: unreadable, truncatedCaptures: truncated,
          unresolvedScopeCaptures: unresolved, toleratedFailures: tolerated,
          walkDurationCount: walks, skippedPageCaptures: skippedPages))
    }

    @Test("#4436: the skipped-page share is walks with a refused page over walks, or omitted")
    func skippedPageShare() throws {
      let row = try #require(
        capture(event(speakerNaming: reads(walks: 40, skippedPages: 30))))
      #expect(row.stringProps["speaker_reads_skipped_page_share_bucket"] == "75%+")
      let keys = Set(row.stringProps.keys).union(row.intProps.keys).union(row.doubleProps.keys)
        .union(row.boolProps.keys)
      #expect(
        keys
          == Self.approvedKeys.union(Self.speakerNameKeys).union(Self.readHealthKeys)
          .union(["speaker_reads_skipped_page_share_bucket"]))
      func bucket(_ walks: Int, _ skipped: Int?) -> String? {
        TelemetryService.meetingEndedProperties(
          event(speakerNaming: reads(walks: walks, skippedPages: skipped)))[
            "speaker_reads_skipped_page_share_bucket"] as? String
      }
      #expect(bucket(10, 0) == "0")
      #expect(bucket(100, 4) == "<5%")
      #expect(bucket(0, 0) == nil, "nothing walked")
      #expect(bucket(10, nil) == nil, "an old segment made it unknown")
    }

    @Test("#4013 reading resilience: read health adds three closed strings and nothing else")
    func readHealthFields() throws {
      let row = try #require(capture(event(speakerNaming: reads(unreadable: 3, tolerated: 250))))
      #expect(row.stringProps["speaker_reads_unusable_share_bucket"] == "<5%")
      #expect(row.stringProps["speaker_reads_unusable_reason"] == "unreadable")
      #expect(row.stringProps["speaker_reads_tolerated_bucket"] == "100-999")
      let keys = Set(row.stringProps.keys).union(row.intProps.keys).union(row.doubleProps.keys)
        .union(row.boolProps.keys)
      #expect(keys == Self.approvedKeys.union(Self.speakerNameKeys).union(Self.readHealthKeys))
    }

    @Test(
      "#4013 reading resilience: the unusable share uses the #4248 share scale at every edge",
      arguments: [
        (0, "0"), (1, "<5%"), (4, "<5%"), (5, "5-25%"), (24, "5-25%"), (25, "25-50%"),
        (49, "25-50%"), (50, "50-75%"), (74, "50-75%"), (75, "75%+"), (100, "75%+"),
      ])
    func readHealthShareEdges(unusable: Int, bucket: String) {
      let props = TelemetryService.meetingEndedProperties(
        event(speakerNaming: reads(truncated: unusable)))
      #expect(props["speaker_reads_unusable_share_bucket"] as? String == bucket)
    }

    @Test(
      "#4013 reading resilience: tolerated failures travel as a bucket at every edge",
      arguments: [
        (0, "0"), (1, "1-99"), (99, "1-99"), (100, "100-999"), (999, "100-999"), (1000, "1000+"),
      ])
    func readHealthToleratedEdges(count: Int, bucket: String) {
      let props = TelemetryService.meetingEndedProperties(
        event(speakerNaming: reads(tolerated: count)))
      #expect(props["speaker_reads_tolerated_bucket"] as? String == bucket)
    }

    @Test("#4013 reading resilience: the reason is the largest kind; ties go in the fixed order")
    func readHealthReason() {
      func reason(_ u: Int, _ t: Int, _ s: Int) -> String? {
        TelemetryService.meetingEndedProperties(
          event(speakerNaming: reads(unreadable: u, truncated: t, unresolved: s)))[
            "speaker_reads_unusable_reason"] as? String
      }
      #expect(reason(0, 0, 0) == "none")
      #expect(reason(1, 0, 0) == "unreadable")
      #expect(reason(0, 2, 1) == "truncated")
      #expect(reason(0, 0, 3) == "unresolved_scope")
      #expect(reason(2, 2, 2) == "unreadable")
      #expect(reason(0, 2, 2) == "truncated")
      #expect(reason(1, 2, 2) == "truncated")
      #expect(SpeakerReadHealth.Reason.allCases.map(\.rawValue) == [
        "unreadable", "truncated", "unresolved_scope", "none",
      ])
    }

    @Test("#4013 reading resilience: no summary, no attempts or an old counter omits the keys")
    func readHealthOmitted() throws {
      let none = try #require(capture(event()))
      #expect(Set(none.stringProps.keys).isDisjoint(with: Self.readHealthKeys))
      let noHealth = try #require(
        capture(
          event(speakerNaming: SpeakerNamingSummary(surface: .zoomApp, outcome: nil, autoNamedCount: 0))))
      #expect(Set(noHealth.stringProps.keys).isDisjoint(with: Self.readHealthKeys))
      #expect(
        SpeakerReadHealth(
          captureAttempts: 0, unreadableCaptures: 0, truncatedCaptures: 0,
          unresolvedScopeCaptures: 0, toleratedFailures: 0) == nil)
      let old = try #require(capture(event(speakerNaming: reads(tolerated: nil))))
      #expect(old.stringProps["speaker_reads_tolerated_bucket"] == nil)
      #expect(old.stringProps["speaker_reads_unusable_reason"] == "none")
      #expect(old.stringProps["speaker_reads_unusable_share_bucket"] == "0")
    }

    @Test("#4013: every surface and outcome travels as its closed spelling and nothing else")
    func speakerNameVocabulary() throws {
      for surface in SpeakerNamingSummary.Surface.allCases {
        for outcome in SpeakerNamingSummary.Outcome.allCases {
          let props = TelemetryService.meetingEndedProperties(
            event(
              speakerNaming: SpeakerNamingSummary(
                surface: surface, outcome: outcome, autoNamedCount: 1)))
          #expect(props["speaker_names_surface"] as? String == surface.rawValue)
          #expect(props["speaker_names_outcome"] as? String == outcome.rawValue)
          #expect(props["auto_named_count"] as? Int == 1)
        }
      }
    }

    private static let muteKeys: Set<String> = [
      "mute_follow_enabled", "mute_eligible_seconds_bucket", "mute_reads_bucket",
      "mute_silenced_share_bucket", "mute_unknown_share_bucket",
    ]

    @Test("#4248: a mute summary adds a bool and four bucket strings, shares of eligible time")
    func muteFields() throws {
      let row = try #require(
        capture(
          event(
            muteFollow: MuteFollowSummary(
              enabledAtStop: true, eligibleSeconds: 1_200, unknownSeconds: 30,
              silencedSeconds: 400, reads: 2_400))))
      #expect(row.boolProps["mute_follow_enabled"] == true)
      #expect(row.stringProps["mute_eligible_seconds_bucket"] == "15-30min")
      #expect(row.stringProps["mute_reads_bucket"] == "1000-4999")
      #expect(row.stringProps["mute_silenced_share_bucket"] == "25-50%")
      #expect(row.stringProps["mute_unknown_share_bucket"] == "<5%")
      let keys = Set(row.stringProps.keys).union(row.intProps.keys).union(row.doubleProps.keys)
        .union(row.boolProps.keys)
      #expect(keys == Self.approvedKeys.union(Self.muteKeys))
    }

    @Test("#4248: nothing eligible omits both shares; no summary omits every mute key")
    func muteFieldsOmitted() throws {
      let off = try #require(
        capture(
          event(
            muteFollow: MuteFollowSummary(
              enabledAtStop: false, eligibleSeconds: 0, unknownSeconds: 0, silencedSeconds: 0,
              reads: 0))))
      #expect(off.boolProps["mute_follow_enabled"] == false)
      #expect(off.stringProps["mute_eligible_seconds_bucket"] == "0")
      #expect(off.stringProps["mute_reads_bucket"] == "0")
      #expect(off.stringProps["mute_silenced_share_bucket"] == nil)
      #expect(off.stringProps["mute_unknown_share_bucket"] == nil)
      let none = try #require(capture(event()))
      let keys = Set(none.stringProps.keys).union(none.boolProps.keys)
      #expect(keys.isDisjoint(with: Self.muteKeys))
    }

    @Test("#4121: a call-sound summary adds exactly four keys, a string and three integers; a known zero stays 0")
    func callSoundFields() throws {
      let row = try #require(
        capture(
          event(
            callSound: CallSoundSummary(
              outputTransport: "bluetooth", configuredRateHz: 24_000, rebuilds: 0,
              omittedReports: 0))))
      #expect(row.stringProps["call_output_transport"] == "bluetooth")
      #expect(row.intProps["call_capture_rate_hz"] == 24_000)
      #expect(row.intProps["call_rebuilds"] == 0)
      #expect(row.intProps["call_reports_omitted"] == 0)
      let keys = Set(row.stringProps.keys).union(row.intProps.keys).union(row.doubleProps.keys)
        .union(row.boolProps.keys)
      #expect(
        keys
          == Self.approvedKeys.union([
            "call_output_transport", "call_capture_rate_hz", "call_rebuilds", "call_reports_omitted",
          ]))
    }

    @Test("#4121: no summary sends none of the four keys; a summary without start facts sends only the counts")
    func callSoundFieldsOmitted() throws {
      let none = try #require(capture(event()))
      let all = Set(none.stringProps.keys).union(none.intProps.keys)
      #expect(all.isDisjoint(with: ["call_output_transport", "call_capture_rate_hz", "call_rebuilds", "call_reports_omitted"]))
      let counts = try #require(
        capture(event(callSound: CallSoundSummary(rebuilds: 3, omittedReports: 1))))
      #expect(counts.stringProps["call_output_transport"] == nil)
      #expect(counts.intProps["call_capture_rate_hz"] == nil)
      #expect(counts.intProps["call_rebuilds"] == 3)
      #expect(counts.intProps["call_reports_omitted"] == 1)
    }

    @Test("every approved field, with its type; nothing else")
    func payload() throws {
      let row = try #require(capture(event()))
      #expect(
        row.stringProps == [
          "outcome": "ready", "duration_bucket": "30-60min", "mic_track": "captured",
          "system_track": "unsupported", "engine": "parakeet", "speaker_count_bucket": "3-4",
          "echo_hidden_count_bucket": "6-20", "entry_point": "menu", "summary_plan": "scheduled",
        ])
      #expect(row.intProps == ["yield_count": 4, "gap_count": 2])
      #expect(row.doubleProps == ["processing_seconds": 90, "rtf": 0.05])
      #expect(row.boolProps == ["disk_stopped": false, "has_notes": true])
      let keys = Set(row.stringProps.keys).union(row.intProps.keys).union(row.doubleProps.keys)
        .union(row.boolProps.keys)
      #expect(keys == Self.approvedKeys)
    }

    @Test("unknown start facts are omitted, never guessed; no audio means an RTF of 0")
    func unknownsAndZero() throws {
      let row = try #require(
        capture(
          event(
            outcome: .startFailed, entry: nil, processing: 0, audio: 0, disk: nil, engine: nil)))
      #expect(row.stringProps["entry_point"] == nil)
      #expect(row.stringProps["engine"] == nil, "#3973 C3: an unresolved attempt names no engine")
      #expect(row.boolProps["disk_stopped"] == nil)
      #expect(row.doubleProps["rtf"] == 0)
      let infinite = MeetingEndedTelemetry(
        outcome: .failed, entryPoint: .history, durationSeconds: 0, microphoneTrack: .failed,
        callSoundTrack: .off, engine: nil, speakerCount: 0, processingSeconds: .infinity,
        audioSeconds: 1,
        yieldCount: 0, gapCount: 0, echoHiddenCount: 0, diskStopped: false,
        summaryPlan: .notApplicable, hasNotes: false)
      #expect(infinite.realTimeFactor == 0)
    }

    @Test("#3973 C3: the engine is the one the attempt resolved to, Whisper included")
    func resolvedEngine() throws {
      let whisper = try #require(capture(event(engine: .whisper)))
      #expect(whisper.stringProps["engine"] == "whisper")
      let fallback = try #require(capture(event(engine: .parakeet)))
      #expect(fallback.stringProps["engine"] == "parakeet")
    }

    @Test("every outcome is its own closed value")
    func outcomes() {
      #expect(
        MeetingEndedTelemetry.Outcome.allCases.map(\.rawValue) == [
          "ready", "ready_with_gaps", "failed", "start_failed", "interrupted_ready",
          "deleted_before_ready",
        ])
    }

    @Test("summary plans and finished outcomes are closed values (R48, R54, R57)")
    func summaryValues() {
      #expect(
        MeetingEndedTelemetry.SummaryPlan.allCases.map(\.rawValue) == [
          "scheduled", "off", "no_provider", "unsupported", "not_applicable",
        ])
      #expect(
        MeetingSummaryFinishedTelemetry.Outcome.allCases.map(\.rawValue) == [
          "written", "unsupported", "no_provider", "failed", "cancelled", "stale",
          "nothing_to_summarize",
        ])
      #expect(
        MeetingSummaryFinishedTelemetry.ProviderKind.allCases.map(\.rawValue) == [
          "local", "hosted", "none",
        ])
      let start = MeetingEndedTelemetry.startFailed(
        entryPoint: .menu, microphone: .failed, callSound: .off)
      #expect(start.summaryPlan == .notApplicable)
      #expect(start.hasNotes == false)
    }

    @Test("meeting.summary_finished carries the outcome and provider kind, nothing else")
    func summaryFinishedPayload() {
      let box = Box()
      let service = TelemetryService.shared
      let previous = service.testEventHook
      service.testEventHook = { captured in
        if captured.name == "meeting.summary_finished" { box.events.append(captured) }
      }
      defer { service.testEventHook = previous }
      service.trackMeetingSummaryFinished(
        MeetingSummaryFinishedTelemetry(outcome: .noProvider, providerKind: .none))
      #expect(box.events.count == 1)
      #expect(box.events.first?.stringProps == ["outcome": "no_provider", "provider_kind": "none"])
      #expect(
        TelemetryService.meetingSummaryFinishedProperties(
          MeetingSummaryFinishedTelemetry(outcome: .written, providerKind: .local)).count == 2)
    }

    @Test("bucket boundaries")
    func buckets() {
      #expect(
        [0, 1, 2, 3, 4, 5, 9].map(TelemetryService.meetingSpeakerCountBucket) == [
          "0", "1", "2", "3-4", "3-4", "5+", "5+",
        ])
      #expect(
        [0, 1, 5, 6, 20, 21].map(TelemetryService.meetingEchoHiddenBucket) == [
          "0", "1-5", "1-5", "6-20", "6-20", "21+",
        ])
      #expect(
        [59.0, 60, 299, 300, 899, 900, 1_799, 1_800, 3_599, 3_600, 18_000].map(
          TelemetryService.fileImportDurationBucket) == [
            "<1min", "1-5min", "1-5min", "5-15min", "5-15min", "15-30min", "15-30min",
            "30-60min", "30-60min", "60min+", "60min+",
          ])
      #expect(
        [0, 0.01, 0.05, 0.249, 0.25, 0.5, 0.75, 1].map(TelemetryService.meetingShareBucket) == [
          "0", "<5%", "5-25%", "5-25%", "25-50%", "50-75%", "75%+", "75%+",
        ])
      #expect(
        [0, 1, 99, 100, 999, 1_000, 4_999, 5_000].map(TelemetryService.meetingMuteReadsBucket) == [
          "0", "1-99", "1-99", "100-999", "100-999", "1000-4999", "1000-4999", "5000+",
        ])
      let tooMuch = MuteFollowSummary(
        enabledAtStop: true, eligibleSeconds: 10, unknownSeconds: 0, silencedSeconds: 12, reads: 1)
      #expect(tooMuch.silencedShare == 1, "a share never exceeds all eligible time")
    }
  }
#endif
