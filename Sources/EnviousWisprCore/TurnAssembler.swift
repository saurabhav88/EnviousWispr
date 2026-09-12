import Foundation

/// Partitions a transcript's full, ordered `ASRWordTiming` array into speaker turns by
/// temporal overlap against a diarizer's `SpeakerSegment`s (#2810, phase 3 of #2807).
///
/// Pure and stateless — every original entry is classified into exactly one turn, never
/// dropped or duplicated, so "every original word preserved" holds by construction: the
/// classification loop below consumes `entries` once, in order, and every entry is appended to
/// the turn being built before the loop advances.
public enum TurnAssembler {

  /// How close an untimed-by-overlap entry's own boundary must be to a segment's boundary to
  /// be assigned to it anyway, rather than to `"unknown"`. Provisional — no measured diarizer
  /// boundary-jitter value exists to cite; kept as a named constant so a future measurement
  /// has one place to update.
  static let nearestSegmentToleranceMs = 250

  static let unknownSpeakerID = "unknown"

  public static func assemble(entries: [ASRWordTiming], segments: [SpeakerSegment]) -> [Turn] {
    guard !entries.isEmpty else { return [] }

    var turns: [Turn] = []
    var groupSpeaker: String?
    var groupEntries: [ASRWordTiming] = []

    func flushGroup() {
      guard let speaker = groupSpeaker, !groupEntries.isEmpty else { return }
      turns.append(makeTurn(speaker: speaker, entries: groupEntries))
      groupEntries = []
    }

    for entry in entries {
      let speaker = resolveSpeaker(for: entry, segments: segments)
      if speaker != groupSpeaker {
        flushGroup()
        groupSpeaker = speaker
      }
      groupEntries.append(entry)
    }
    flushGroup()

    return turns
  }

  /// Greatest-overlap assignment with a deterministic tie-break, a bounded nearest-segment
  /// fallback, and `"unknown"` beyond that or for an untimed entry. Assignment is independent
  /// of whether the entry itself is timed: an entry can be `"unknown"` and still carry real
  /// `startMs`/`endMs` (assigned by the tolerance fallback but not within any segment's
  /// tolerance), or have no bounds at all.
  private static func resolveSpeaker(for entry: ASRWordTiming, segments: [SpeakerSegment])
    -> String
  {
    guard let entryStart = entry.startMs, let entryEnd = entry.endMs else {
      return unknownSpeakerID
    }

    var bestOverlap = 0
    var bestSegment: SpeakerSegment?
    for segment in segments {
      let overlap = max(0, min(entryEnd, segment.endMs) - max(entryStart, segment.startMs))
      guard overlap > 0 else { continue }
      if overlap > bestOverlap
        || (overlap == bestOverlap && isEarlierTiebreak(segment, than: bestSegment))
      {
        bestOverlap = overlap
        bestSegment = segment
      }
    }
    if let bestSegment { return bestSegment.speakerId }

    // No direct overlap: a bounded nearest-segment fallback.
    var nearestDistance = Int.max
    var nearestSegment: SpeakerSegment?
    for segment in segments {
      let distance: Int
      if entryEnd <= segment.startMs {
        distance = segment.startMs - entryEnd
      } else if entryStart >= segment.endMs {
        distance = entryStart - segment.endMs
      } else {
        distance = 0
      }
      if distance < nearestDistance
        || (distance == nearestDistance && isEarlierTiebreak(segment, than: nearestSegment))
      {
        nearestDistance = distance
        nearestSegment = segment
      }
    }
    if let nearestSegment, nearestDistance <= nearestSegmentToleranceMs {
      return nearestSegment.speakerId
    }
    return unknownSpeakerID
  }

  /// Deterministic tie-break: lowest `startMs`, then lexicographically lowest `speakerId`.
  /// No wall-clock or randomness, so a fresh pass over identical input reproduces identical
  /// assignments.
  private static func isEarlierTiebreak(_ candidate: SpeakerSegment, than current: SpeakerSegment?)
    -> Bool
  {
    guard let current else { return true }
    if candidate.startMs != current.startMs { return candidate.startMs < current.startMs }
    return candidate.speakerId < current.speakerId
  }

  private static func makeTurn(speaker: String, entries: [ASRWordTiming]) -> Turn {
    let range = entries.first!.range.lowerBound..<entries.last!.range.upperBound
    let timedEntries = entries.filter { $0.startMs != nil && $0.endMs != nil }
    let startMs = timedEntries.map { $0.startMs! }.min()
    let endMs = timedEntries.map { $0.endMs! }.max()
    return Turn(
      id: "\(range.lowerBound)-\(range.upperBound)",
      speakerId: speaker, startMs: startMs, endMs: endMs, originalTextRange: range)
  }

  /// Default `"Speaker N"` names in first-appearance order among the turns, excluding
  /// `"unknown"` — a classification outcome, never a named speaker.
  public static func defaultSpeakerNames(for turns: [Turn]) -> [String: String] {
    var names: [String: String] = [:]
    var nextNumber = 1
    for turn in turns where turn.speakerId != unknownSpeakerID {
      guard names[turn.speakerId] == nil else { continue }
      names[turn.speakerId] = "Speaker \(nextNumber)"
      nextNumber += 1
    }
    return names
  }
}
