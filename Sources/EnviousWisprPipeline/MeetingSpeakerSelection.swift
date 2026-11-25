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
    /// Voices the comparison counted (`countedVoices`); nil when that analysis gave no result.
    package let offlineCounted: Int?
    package let lowCounted: Int?
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

  /// #4945: speech a neural voice needs in the whole meeting before it counts in the comparison.
  /// Real case: 0.21 s in 650 s made `choose` drop the right grouping. Segments are kept; only
  /// the count ignores them.
  package static let minimumVoiceMs = 2_000

  /// Neural voices with at least `minimumVoiceMs` of speech.
  package static func countedVoices(_ analysis: MeetingSpeakerAnalysis) -> Int {
    var ms: [String: Int] = [:]
    for segment in analysis.segments { ms[segment.speakerId, default: 0] += segment.endMs - segment.startMs }
    return ms.values.count { $0 >= minimumVoiceMs }
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
    let offlineRaw = count(offline)
    let lowRaw = count(low)
    guard offlineRaw > 0, lowRaw > 0 else { return keep(.probeFailed) }
    let preferred = countedVoices(offline)
    let verification = countedVoices(low)
    guard preferred < 8, verification < 8 else { return keep(.saturated) }
    // Offline found fewer voices than its check: it may have merged two (German control, #4424).
    // The raw-count clause keeps what #4424 selected; without it two measured recordings got worse.
    guard (offlineRaw < 8 && offlineRaw == lowRaw) || preferred >= verification else {
      return keep(.disagreement)
    }
    return Decision(analysis: offline, reason: .selected)
  }
}
