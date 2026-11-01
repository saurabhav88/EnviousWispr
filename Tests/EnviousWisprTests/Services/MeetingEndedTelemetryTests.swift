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
      muteFollow: MuteFollowSummary? = nil
    ) -> MeetingEndedTelemetry {
      MeetingEndedTelemetry(
        outcome: outcome, entryPoint: entry, durationSeconds: duration, microphoneTrack: .captured,
        callSoundTrack: .unsupported, engine: engine, speakerCount: speakers,
        processingSeconds: processing,
        audioSeconds: audio, yieldCount: 4, gapCount: 2, echoHiddenCount: echo, diskStopped: disk,
        summaryPlan: .scheduled, hasNotes: true, callSound: callSound,
        speakerNaming: speakerNaming, muteFollow: muteFollow)
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
