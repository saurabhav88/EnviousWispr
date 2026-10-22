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
      "entry_point", "disk_stopped",
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
      echo: Int = 7, disk: Bool? = false
    ) -> MeetingEndedTelemetry {
      MeetingEndedTelemetry(
        outcome: outcome, entryPoint: entry, durationSeconds: duration, microphoneTrack: .captured,
        callSoundTrack: .unsupported, speakerCount: speakers, processingSeconds: processing,
        audioSeconds: audio, yieldCount: 4, gapCount: 2, echoHiddenCount: echo, diskStopped: disk)
    }

    @Test("every approved field, with its type; nothing else")
    func payload() throws {
      let row = try #require(capture(event()))
      #expect(
        row.stringProps == [
          "outcome": "ready", "duration_bucket": "30-60min", "mic_track": "captured",
          "system_track": "unsupported", "engine": "parakeet", "speaker_count_bucket": "3-4",
          "echo_hidden_count_bucket": "6-20", "entry_point": "menu",
        ])
      #expect(row.intProps == ["yield_count": 4, "gap_count": 2])
      #expect(row.doubleProps == ["processing_seconds": 90, "rtf": 0.05])
      #expect(row.boolProps == ["disk_stopped": false])
      let keys = Set(row.stringProps.keys).union(row.intProps.keys).union(row.doubleProps.keys)
        .union(row.boolProps.keys)
      #expect(keys == Self.approvedKeys)
    }

    @Test("unknown start facts are omitted, never guessed; no audio means an RTF of 0")
    func unknownsAndZero() throws {
      let row = try #require(
        capture(event(outcome: .startFailed, entry: nil, processing: 0, audio: 0, disk: nil)))
      #expect(row.stringProps["entry_point"] == nil)
      #expect(row.boolProps["disk_stopped"] == nil)
      #expect(row.doubleProps["rtf"] == 0)
      let infinite = MeetingEndedTelemetry(
        outcome: .failed, entryPoint: .page, durationSeconds: 0, microphoneTrack: .failed,
        callSoundTrack: .off, speakerCount: 0, processingSeconds: .infinity, audioSeconds: 1,
        yieldCount: 0, gapCount: 0, echoHiddenCount: 0, diskStopped: false)
      #expect(infinite.realTimeFactor == 0)
    }

    @Test("every outcome is its own closed value")
    func outcomes() {
      #expect(
        MeetingEndedTelemetry.Outcome.allCases.map(\.rawValue) == [
          "ready", "ready_with_gaps", "failed", "start_failed", "interrupted_ready",
          "deleted_before_ready",
        ])
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
    }
  }
#endif
