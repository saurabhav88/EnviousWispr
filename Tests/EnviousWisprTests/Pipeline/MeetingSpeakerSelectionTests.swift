import Foundation
import Testing

@testable import EnviousWisprAudio
@testable import EnviousWisprCore
@testable import EnviousWisprPipeline

enum MeetingNeuralSpeakerTestData {
  /// `stray` adds one more voice of that many ms, in two stretches.
  static func analysis(_ count: Int, stray: Int? = nil, outcome: MeetingSpeakerOutcome? = nil) -> MeetingSpeakerAnalysis {
    let extra = stray.map { ms in [1_000, 20_000].map {
      SpeakerSegment(speakerId: "N\(count)", startMs: $0, endMs: $0 + ms / 2, quality: 1)
    } } ?? []
    return .init(outcome: outcome ?? (count == 1 ? .single : .labeled), segments: (0..<count).map {
      SpeakerSegment(speakerId: "N\($0)", startMs: 0, endMs: 30_000, quality: 1)
    } + extra)
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

/// #4424: model failure, finite-slot saturation or a refused comparison (#4945) must retain the old result;
/// decoded evidence alone must not enroll unknown calls or microphone audio into new grouping.
@Suite(.tags(.productOutcome)) struct MeetingSpeakerSelectionTests {
  @Test func frozenCountRoute() {
    typealias Data = MeetingNeuralSpeakerTestData
    let legacy = Data.analysis(4)
    let cases: [(MeetingSpeakerAnalysis, MeetingSpeakerAnalysis, MeetingSpeakerSelection.Reason)] = [
      (Data.analysis(1), Data.analysis(1), .selected), (Data.analysis(7), Data.analysis(7), .selected),
      (Data.analysis(1), Data.analysis(2), .disagreement), (Data.analysis(8), Data.analysis(7), .saturated),
      (Data.analysis(7), Data.analysis(8), .saturated), (Data.analysis(0), Data.analysis(0), .probeFailed),
      // #4945: a voice under 2 s in the whole meeting does not make low's count the larger one.
      (Data.analysis(2), Data.analysis(2, stray: 1_990), .selected),
      (Data.analysis(2), Data.analysis(2, stray: 2_000), .disagreement),
      (Data.analysis(3), Data.analysis(2), .selected), (Data.analysis(7), Data.analysis(7, stray: 140), .selected),
      // Equal raw counts stay selected even when offline's extra voice is short.
      (Data.analysis(2, stray: 1_000), Data.analysis(3), .selected),
    ]
    for (offline, low, reason) in cases {
      let decision = MeetingSpeakerSelection.choose(legacy: legacy, offline: offline, low: low)
      #expect(decision.reason == reason)
      #expect(decision.analysis.segments == (reason == .selected ? offline : legacy).segments)
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
