import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprPipeline
@testable import EnviousWisprServices

/// #4013 r2 item 5, r3 F4: when these fail, a naming result reaches `meeting.ended` as an outcome
/// the evidence cannot support, or a name, speaker id or room key leaks into the row.
///
/// The results and rows are synthetic and written by hand. They prove the mapping and the
/// projection, not the processing pass, the durable write or delivery to PostHog.
@Suite("Speaker naming result to meeting.ended", .tags(.observabilityContract))
struct MeetingNamingTelemetryTests {

  private static func log(surface: CallSpeakerSurface?) -> CallSpeakerLog {
    CallSpeakerLog(
      surface: surface, source: .app, status: .observed, lag: CallSpeakerLag(milliseconds: 0),
      rules: nil,
      roster: CallSpeakerRoster(
        names: ["Alex Rivera", "Saurabh Vaish"], selfNames: ["Saurabh Vaish"]),
      rosterFromParticipantList: true, observations: [])
  }

  @Test("each namer outcome maps to its telemetry outcome, or to none when the inputs cannot say")
  func outcomeMapping() {
    let expected: [(MeetingNamingResult.Outcome, SpeakerNamingSummary.Outcome?)] = [
      (.noLog, nil), (.noPermission, .noPermission), (.unreadable, nil),
      (.unsupported, .unsupported), (.rulesUnusable, nil), (.statusUnknown, nil),
      (.lagUnmeasured, nil), (.noEligibleSpeakers, nil),
      (.noSignal, .noSignal), (.ambiguous, .ambiguous),
    ]
    for (outcome, mapped) in expected {
      let pass = MeetingNamingResult(proposals: [:], outcome: outcome)
        .pass(log: Self.log(surface: .meet))
      #expect(pass == .abstained(surface: .meet, outcome: mapped), "\(outcome)")
    }
  }

  @Test("a decoded log with no status, or a status this build does not know, gives no outcome")
  func unknownStatusStaysAbsent() throws {
    for status in [nil, "paused_by_newer_build"] {
      let field = status.map { "\"status\":\"\($0)\"," } ?? ""
      let json =
        "{\"formatVersion\":1,\"surface\":\"zoom_app\",\"source\":\"app\"," + field
        + "\"lag\":{\"milliseconds\":0},"
        + "\"roster\":{\"names\":[\"Alex Rivera\"],\"selfNames\":[\"Saurabh Vaish\"]},"
        + "\"observations\":[{\"observationMs\":100,\"speaking\":[\"Alex Rivera\"]}]}"
      let log = try JSONDecoder().decode(CallSpeakerLog.self, from: Data(json.utf8))
      #expect(log.status == nil)
      let result = MeetingSpeakerNamer.propose(
        composition: MeetingComposition(
          text: "x", turns: [], speakerNames: [:], echoTurnIDs: [], speakerCount: 0),
        eligibility: nil, log: log)
      #expect(result.outcome == .statusUnknown)
      #expect(result.pass(log: log) == .abstained(surface: .zoomApp, outcome: nil))
    }
  }

  @Test(
    "named carries the proposal count and surface; a named result with no proposals says nothing")
  func namedMapping() {
    let named = MeetingNamingResult(
      proposals: ["sys:S1": "Alex Rivera", "sys:S2": "Priya Shah"], outcome: .named)
    #expect(
      named.pass(log: Self.log(surface: .webex)) == .proposed(surface: .unsupported, count: 2))
    #expect(
      MeetingNamingResult(proposals: [:], outcome: .named).pass(log: nil)
        == .abstained(surface: nil, outcome: nil))
  }

  @Test("the committed row's payload holds no name, speaker id or room key")
  @MainActor func payloadHasNoContent() {
    let turns = ["mic:you", "sys:S1"].enumerated().map { index, speaker in
      Turn(
        id: speaker, speakerId: speaker, startMs: index * 1_000, endMs: index * 1_000 + 900,
        originalTextRange: 0..<1, wasPolished: true, granularity: .word)
    }
    let row = Transcript(
      id: UUID(), text: "x", backendType: .parakeet, speakerAnalysis: .labeled(count: 2),
      speakerNames: ["mic:you": "You", "sys:S1": "Alex Rivera"], turns: turns,
      speakerNameSources: ["sys:S1": .auto], meetingID: UUID())
    let pass = MeetingNamingResult(proposals: ["sys:S1": "Alex Rivera"], outcome: .named)
      .pass(log: Self.log(surface: .zoomApp))
    let summary = PendingSpeakerNamingSummary(proposed: row, reconciled: row, pass: pass)
      .committed(.written)
    #expect(summary == .init(surface: .zoomApp, outcome: .named, autoNamedCount: 1))
    let event = MeetingEndedTelemetry(
      outcome: .ready, entryPoint: .detected, durationSeconds: 60, microphoneTrack: .captured,
      callSoundTrack: .captured, engine: .parakeet, speakerCount: 2, processingSeconds: 3,
      audioSeconds: 60,
      yieldCount: 0, gapCount: 0, echoHiddenCount: 0, diskStopped: false,
      summaryPlan: .scheduled, hasNotes: false, speakerNaming: summary)
    let values = TelemetryService.meetingEndedProperties(event).values.map { "\($0)" }
    for content in ["Alex Rivera", "Saurabh Vaish", "sys:S1", "mic:you", "S1"] {
      #expect(!values.contains { $0.contains(content) }, "\(content)")
    }
  }
}
