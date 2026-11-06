import EnviousWisprAudio
import EnviousWisprCore
import Foundation

/// #4424: an empirical acoustic route, never an identity/name score or forced headcount.
package enum MeetingSpeakerSelection {
  package struct ProbeRequest: Sendable {
    package let audio: MeetingTrackAudio
    package let preset: MeetingNeuralSpeakerPreset
    package let remainingBudgetSeconds: Double
    package let canContinue: MeetingNeuralSpeakerAnalyzer.Admission
  }

  package typealias Probe = @Sendable (ProbeRequest) async -> MeetingSpeakerAnalysis?

  package enum Reason: String, Sendable {
    case legacyOnly, modelsUnavailable, legacyFailed, capacity, budgetExhausted
    case priorityChanged, probeFailed, disagreement, saturated, selected
  }

  package struct Decision: Sendable {
    package let analysis: MeetingSpeakerAnalysis
    package let reason: Reason
  }

  package struct Observation: Sendable {
    package let reason: Reason
    package let legacyCount: Int
    package let offlineCount: Int?
    package let lowCount: Int?
    package let elapsedSeconds: Double
  }

  package static func eligible(
    track: MeetingTrackKind, evidence: MeetingCallSpeakerEvidence
  ) -> Bool {
    guard track == .callSound, let log = evidence.log else { return false }
    return log.segments.contains { MeetingSpeakerNamer.segmentRefusal($0, rules: log.rules) == nil }
  }

  package static func count(_ analysis: MeetingSpeakerAnalysis) -> Int {
    Set(analysis.segments.map(\.speakerId)).count
  }

  package static func succeeded(_ analysis: MeetingSpeakerAnalysis) -> Bool {
    switch analysis.outcome {
    case .single, .labeled: true
    case .noSpeech, .failed, .timedOut: false
    }
  }

  package static func choose(
    legacy: MeetingSpeakerAnalysis, offline: MeetingSpeakerAnalysis?, low: MeetingSpeakerAnalysis?
  ) -> Decision {
    func keep(_ reason: Reason) -> Decision { Decision(analysis: legacy, reason: reason) }
    guard succeeded(legacy) else { return keep(.legacyFailed) }
    guard count(legacy) <= 8 else { return keep(.capacity) }
    guard let offline, let low, succeeded(offline), succeeded(low) else { return keep(.probeFailed) }
    let preferred = count(offline)
    let verification = count(low)
    guard preferred > 0, verification > 0 else { return keep(.probeFailed) }
    guard preferred < 8, verification < 8 else { return keep(.saturated) }
    guard preferred == verification else { return keep(.disagreement) }
    return Decision(analysis: offline, reason: .selected)
  }
}
