import Foundation
import Testing

@testable import EnviousWisprAudio
@testable import EnviousWisprCore
@testable import EnviousWisprPipeline

enum MeetingNeuralSpeakerTestData {
  static func analysis(_ count: Int, outcome: MeetingSpeakerOutcome? = nil) -> MeetingSpeakerAnalysis {
    .init(outcome: outcome ?? (count == 1 ? .single : .labeled), segments: (0..<count).map {
      SpeakerSegment(speakerId: "N\($0)", startMs: 0, endMs: 30_000, quality: 1)
    })
  }

  static func pairLog() -> CallSpeakerLog {
    .init(rules: nil, segments: [
      CallSpeakerSegment(
        startMs: 0, endMs: 30_000, endReason: .recordingEnded, surface: .zoomApp, source: .app,
        status: .observed, lag: CallSpeakerLag(milliseconds: 0),
        roster: CallSpeakerRoster(names: ["User", "Alex Rivera"], selfNames: ["User"]),
        rosterFromParticipantList: true, observations: [],
        pairs: [CallPairStretch(names: ["User", "Alex Rivera"], selfNames: ["User"],
          accountNames: [], firstMs: 0, lastMs: 30_000)])
    ])
  }
}

/// #4424: disagreement, model failure or finite-slot saturation must retain the old result;
/// decoded evidence alone must not enroll unknown calls or microphone audio into new grouping.
@Suite(.tags(.productOutcome)) struct MeetingSpeakerSelectionTests {
  @Test func frozenCountRoute() {
    let legacy = MeetingNeuralSpeakerTestData.analysis(2)
    let cases: [(Int, Int, MeetingSpeakerSelection.Reason)] = [
      (1, 1, .selected), (7, 7, .selected), (1, 2, .disagreement),
      (8, 8, .saturated), (0, 0, .probeFailed),
    ]
    for (offline, low, reason) in cases {
      let decision = MeetingSpeakerSelection.choose(
        legacy: legacy, offline: MeetingNeuralSpeakerTestData.analysis(offline),
        low: MeetingNeuralSpeakerTestData.analysis(low))
      #expect(decision.reason == reason)
      #expect(MeetingSpeakerSelection.count(decision.analysis) == (reason == .selected ? offline : 2))
    }
  }

  @Test func failedUnavailableAndLegacyCapacity() {
    let legacy = MeetingNeuralSpeakerTestData.analysis(2)
    for failure in [MeetingSpeakerOutcome.failed, .timedOut, .noSpeech] {
      let decision = MeetingSpeakerSelection.choose(
        legacy: legacy, offline: MeetingNeuralSpeakerTestData.analysis(0, outcome: failure),
        low: MeetingNeuralSpeakerTestData.analysis(1))
      #expect(decision.reason == .probeFailed)
      #expect(decision.analysis.segments == legacy.segments)
    }
    #expect(MeetingSpeakerSelection.choose(legacy: legacy, offline: nil, low: nil).reason == .probeFailed)
    #expect(MeetingSpeakerSelection.choose(
      legacy: MeetingNeuralSpeakerTestData.analysis(9), offline: nil, low: nil).reason == .capacity)
    #expect(MeetingSpeakerSelection.choose(
      legacy: MeetingNeuralSpeakerTestData.analysis(0, outcome: .failed),
      offline: MeetingNeuralSpeakerTestData.analysis(1), low: MeetingNeuralSpeakerTestData.analysis(1)
    ).reason == .legacyFailed)
  }

  @Test func eligibilityUsesExistingEvidenceAuthority() {
    let valid = MeetingCallSpeakerEvidence.usable(MeetingNeuralSpeakerTestData.pairLog())
    #expect(MeetingSpeakerSelection.eligible(track: .callSound, evidence: valid))
    #expect(!MeetingSpeakerSelection.eligible(track: .microphone, evidence: valid))
    #expect(!MeetingSpeakerSelection.eligible(track: .callSound, evidence: .absent))
    #expect(!MeetingSpeakerSelection.eligible(track: .callSound, evidence: .unusable(.invalid)))
    #expect(!MeetingSpeakerSelection.eligible(
      track: .callSound, evidence: .usable(CallSpeakerLog(rules: nil, segments: []))))
    let unsupported = CallSpeakerLog(rules: nil, segments: [
      CallSpeakerSegment(
        startMs: 0, endMs: 30_000, endReason: .recordingEnded, surface: .facetime, source: .app,
        status: .observed, lag: CallSpeakerLag(milliseconds: 0),
        roster: .init(names: ["User", "Alex Rivera"], selfNames: ["User"]),
        rosterFromParticipantList: true, observations: [])
    ])
    #expect(!MeetingSpeakerSelection.eligible(track: .callSound, evidence: .usable(unsupported)))
  }
}
