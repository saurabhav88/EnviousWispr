import Foundation

/// Partitions a transcript's full, ordered `ASRWordTiming` array into speaker turns by
/// temporal overlap against a diarizer's `SpeakerSegment`s (#2810, phase 3 of #2807).
///
/// Deterministic over its inputs, and reads no state of its own — every original entry is
/// classified into exactly one turn, never dropped or duplicated, so "every original word
/// preserved" holds by construction, UNLESS the calling Task is cancelled (see below), in
/// which case the return is a partial result the caller must treat as unusable.
///
/// **Checks `Task.isCancelled` once per entry.** A long, highly segmented recording makes
/// this an O(words × segments) synchronous scan; called from a detached task (found by
/// cloud review) specifically so it can be interrupted rather than run to completion after
/// the user has moved on. The classification loop below consumes `entries` once, in order,
/// and every entry is appended to the turn being built before the loop advances.
public enum TurnAssembler {

  /// How close an untimed-by-overlap entry's own boundary must be to a segment's boundary to
  /// be assigned to it anyway, rather than to `"unknown"`. Provisional — no measured diarizer
  /// boundary-jitter value exists to cite; kept as a named constant so a future measurement
  /// has one place to update.
  static let nearestSegmentToleranceMs = 250

  public static let unknownSpeakerID = "unknown"

  /// An `"unknown"` group of this many entries or fewer folds into its nearest neighbour
  /// (#2851 §3 C). Measured on the founder's 48-minute interview, 2026-09-13: 105 of 372
  /// turns were `"unknown"`, 87 of them 1 to 4 words ("w", "too", "a", "Go on. We"), median
  /// 0.8 s, and on screen they cut sentences in two ("Very" / "Soon. Now by the time this
  /// airs."). Five words and up stay unknown: those are real overlaps, not boundary jitter.
  public static let unknownFoldMaxEntries = 4
  /// The fold is a GUESS by proximity where the diarizer had none; the plan's hand-check of
  /// twenty folded fragments against the audio decides whether it ships on. Off leaves
  /// every unknown group as its own turn, exactly as before #2851.
  public static let unknownFoldEnabled = true

  public static func assemble(entries: [ASRWordTiming], segments: [SpeakerSegment]) -> [Turn] {
    guard !entries.isEmpty else { return [] }

    var groups: [(speaker: String, entries: [ASRWordTiming])] = []
    var groupSpeaker: String?
    var groupEntries: [ASRWordTiming] = []

    func flushGroup() {
      guard let speaker = groupSpeaker, !groupEntries.isEmpty else { return }
      groups.append((speaker, groupEntries))
      groupEntries = []
    }

    for entry in entries {
      guard !Task.isCancelled else { break }
      let speaker = resolveSpeaker(for: entry, segments: segments)
      if speaker != groupSpeaker {
        flushGroup()
        groupSpeaker = speaker
      }
      groupEntries.append(entry)
    }
    flushGroup()

    if unknownFoldEnabled { groups = foldingTinyUnknownGroups(groups) }
    return coalescingAdjacentSpeakers(groups).map { makeTurn(speaker: $0.speaker, entries: $0.entries) }
  }

  /// Folds each `"unknown"` group of `unknownFoldMaxEntries` entries or fewer into the
  /// neighbour with the smaller time gap; the previous one on a tie, when the fragment is
  /// untimed, or when there is no next; the next one when there is no previous. A fragment
  /// with no neighbour at all stays. Runs on the speaker groups BEFORE `makeTurn`, so the
  /// merged group's range and bounds derive from its entries like any other; the final
  /// adjacent-speaker coalescing then merges what the fold made adjacent.
  static func foldingTinyUnknownGroups(_ groups: [(speaker: String, entries: [ASRWordTiming])])
    -> [(speaker: String, entries: [ASRWordTiming])]
  {
    var result = groups
    var i = 0
    while i < result.count {
      let group = result[i]
      guard group.speaker == unknownSpeakerID, group.entries.count <= unknownFoldMaxEntries
      else {
        i += 1
        continue
      }
      let previous = i > 0 ? i - 1 : nil
      let next = i + 1 < result.count ? i + 1 : nil
      guard previous != nil || next != nil else {
        i += 1
        continue
      }
      let target: Int
      switch (previous, next) {
      case (let p?, nil): target = p
      case (nil, let n?): target = n
      case (let p?, let n?):
        let fragmentStart = group.entries.compactMap(\.startMs).min()
        let fragmentEnd = group.entries.compactMap(\.endMs).max()
        let previousEnd = result[p].entries.compactMap(\.endMs).max()
        let nextStart = result[n].entries.compactMap(\.startMs).min()
        guard let fragmentStart, let fragmentEnd, let previousEnd, let nextStart else {
          target = p  // untimed on either side: the previous turn keeps the sentence going
          break
        }
        let gapBefore = max(0, fragmentStart - previousEnd)
        let gapAfter = max(0, nextStart - fragmentEnd)
        target = gapAfter < gapBefore ? n : p
      case (nil, nil):
        target = i
      }
      if target == i {
        i += 1
        continue
      }
      if target < i {
        result[target].entries.append(contentsOf: group.entries)
        result.remove(at: i)
        // `i` now points at what followed the fragment; it is re-examined next.
      } else {
        result[target].entries.insert(contentsOf: group.entries, at: 0)
        result.remove(at: i)
        // The next group moved into `i`; re-examine it (it may itself be a fragment).
      }
    }
    return result
  }

  static func coalescingAdjacentSpeakers(_ groups: [(speaker: String, entries: [ASRWordTiming])])
    -> [(speaker: String, entries: [ASRWordTiming])]
  {
    var result: [(speaker: String, entries: [ASRWordTiming])] = []
    for group in groups {
      if let last = result.last, last.speaker == group.speaker {
        result[result.count - 1].entries.append(contentsOf: group.entries)
      } else {
        result.append(group)
      }
    }
    return result
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
  /// `"unknown"` — a classification outcome, never a named speaker — and excluding any
  /// speakerId that is a key in `existingNames` (already named, so it needs no default).
  ///
  /// Numbering CONTINUES past the highest number already used by an `"Speaker N"`-shaped
  /// value in `existingNames`, so a newly appearing speaker never gets the SAME generated
  /// label as a currently-surviving one that kept its number from an earlier pass — a
  /// retry that turns A/B ("Speaker 1"/"Speaker 2") into B/C would otherwise renumber this
  /// pass's turns from 1, handing C "Speaker 2" while B still holds it too (found by cloud
  /// review). Never reuses a number a RETIRED speaker held; simplicity over density.
  public static func defaultSpeakerNames(
    for turns: [Turn], existingNames: [String: String] = [:]
  ) -> [String: String] {
    let usedNumbers = Set(existingNames.values.compactMap(speakerNumber(in:)))
    var nextNumber = (usedNumbers.max() ?? 0) + 1
    var names: [String: String] = [:]
    for turn in turns where turn.speakerId != unknownSpeakerID {
      guard names[turn.speakerId] == nil, existingNames[turn.speakerId] == nil else { continue }
      names[turn.speakerId] = "Speaker \(nextNumber)"
      nextNumber += 1
    }
    return names
  }

  private static func speakerNumber(in name: String) -> Int? {
    let prefix = "Speaker "
    guard name.hasPrefix(prefix) else { return nil }
    return Int(name.dropFirst(prefix.count))
  }
}
