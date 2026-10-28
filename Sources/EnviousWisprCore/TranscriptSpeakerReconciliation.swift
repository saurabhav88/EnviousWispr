import Foundation

/// Who wrote a speaker's display name (#4013 r2 item 4). A speaker with neither has a generated
/// label.
public enum SpeakerNameSource: String, Sendable, Equatable, Codable {
  /// The user typed it, or picked it from the rename list.
  case manual
  /// Read from the call app by automatic naming.
  case auto
}

extension Transcript {

  /// Who wrote `speakerId`'s name, or `nil` for a generated label. A row written before #4013
  /// has no record; there every name that is not the label the app itself would have generated
  /// counts as the user's, so it is never replaced by an automatic one.
  public func speakerNameSource(for speakerId: String) -> SpeakerNameSource? {
    if let speakerNameSources { return speakerNameSources[speakerId] }
    guard let name = speakerNames?[speakerId] else { return nil }
    return Self.isGeneratedLabel(name, for: speakerId) ? nil : .manual
  }

  /// The labels the app generates: "Speaker N" (`TurnAssembler.defaultSpeakerNames`), "You" for
  /// the call's microphone and "Call" for an undivided call sound
  /// (`MeetingTranscriptComposer.speakerNames`).
  static func isGeneratedLabel(_ name: String, for speakerId: String) -> Bool {
    if TurnAssembler.defaultSpeakerNumber(in: name) != nil { return true }
    if speakerId == MeetingTranscriptComposer.fallbackMicrophoneSpeakerID,
      name == MeetingTranscriptComposer.youName
    {
      return true
    }
    return speakerId == MeetingTranscriptComposer.fallbackCallSpeakerID
      && name == MeetingTranscriptComposer.fallbackCallName
  }

  /// The user's names among `speakerIds`, in that order.
  func manualNames(of speakerIds: [String]) -> [String] {
    speakerIds.compactMap { id in
      speakerNameSource(for: id) == .manual ? speakerNames?[id] : nil
    }
  }

  /// `existing` with `added` appended, exact duplicates dropped, spelling untouched. `nil` when
  /// both are empty.
  static func keepingNames(_ existing: [String]?, adding added: [String]) -> [String]? {
    var seen = Set<String>()
    let kept = ((existing ?? []) + added).filter { seen.insert($0).inserted }
    return kept.isEmpty ? nil : kept
  }

  /// This replacement row, with the user's names carried over from `current`, the row History
  /// holds when the replacement is written (#4013 r2 item 4, r3 F2). Only speaker-name fields
  /// change; text, turns and everything else are this row's.
  ///
  /// - Names this row brings are generated labels, or automatic proposals marked `.auto`; any
  ///   other source it claims is ignored, so a stale name never arrives as the user's.
  /// - A name the user wrote moves to the one new speaker whose turns overlap the old speaker's
  ///   turns most, counting only speakers of the same track, and only when that largest
  ///   overlap is positive, unique, and not also claimed by another of the user's names. The
  ///   call's "You" (`mic:you`) keeps its name when it is still there and is never matched to
  ///   another speaker. A moved name replaces whatever this row proposed for that speaker.
  /// - Every name that cannot move is kept in `unassignedSpeakerNames`, as are those already
  ///   kept there.
  public func reconcilingSpeakerNames(withCurrent current: Transcript) -> Transcript {
    let incomingTurns = turns ?? []
    let newIDs = Set(incomingTurns.map(\.speakerId)).subtracting([
      TurnAssembler.unknownSpeakerID, TurnAssembler.bothSpeakersID,
    ])
    var names = speakerNames ?? [:]
    var sources = (speakerNameSources ?? [:]).filter {
      $0.value == .auto && names[$0.key] != nil
    }

    let oldManual = (current.speakerNames?.keys.sorted() ?? []).filter {
      current.speakerNameSource(for: $0) == .manual
    }
    var claims: [String: [String]] = [:]
    var unmatched: [String] = []
    for oldID in oldManual {
      if let target = Self.matchingSpeaker(
        for: oldID, oldTurns: current.turns ?? [], newTurns: incomingTurns, newIDs: newIDs)
      {
        claims[target, default: []].append(oldID)
      } else {
        unmatched.append(oldID)
      }
    }
    for (target, claimants) in claims.sorted(by: { $0.key < $1.key }) {
      guard claimants.count == 1, let oldID = claimants.first,
        let name = current.speakerNames?[oldID]
      else {
        unmatched.append(contentsOf: claimants)
        continue
      }
      names[target] = name
      sources[target] = .manual
    }
    // A moved name wins: an automatic proposal of the same name elsewhere goes back to a
    // generated label, so one person is never shown on two speakers.
    let manualNames = Set(sources.filter { $0.value == .manual }.compactMap { names[$0.key] })
    for (id, source) in sources where source == .auto {
      if let name = names[id], manualNames.contains(name) {
        names[id] = nil
        sources[id] = nil
      }
    }
    let regenerated = TurnAssembler.defaultSpeakerNames(for: incomingTurns, existingNames: names)
    for id in newIDs where names[id] == nil { names[id] = regenerated[id] }
    let lost = unmatched.sorted().compactMap { current.speakerNames?[$0] }
    let kept = Self.keepingNames(
      Self.keepingNames(current.unassignedSpeakerNames, adding: unassignedSpeakerNames ?? []),
      adding: lost)
    return withSpeakerNameFields(
      names: speakerNames == nil && names.isEmpty ? nil : names,
      sources: turns == nil ? nil : sources, unassigned: kept)
  }

  /// The new speaker an old speaker's name moves to, or `nil` when no single one qualifies.
  static func matchingSpeaker(
    for oldID: String, oldTurns: [Turn], newTurns: [Turn], newIDs: Set<String>
  ) -> String? {
    let you = MeetingTranscriptComposer.fallbackMicrophoneSpeakerID
    if oldID == you { return newIDs.contains(you) ? you : nil }
    guard let track = trackPrefix(of: oldID) else { return nil }
    let oldSpans = spans(of: oldID, in: oldTurns)
    guard !oldSpans.isEmpty else { return nil }
    var best: (id: String, overlap: Int)?
    var tied = false
    for newID in newIDs.sorted()
    where newID != you && trackPrefix(of: newID) == track {
      let overlap = overlapMs(oldSpans, spans(of: newID, in: newTurns))
      guard overlap > 0 else { continue }
      if let current = best {
        if overlap > current.overlap {
          best = (newID, overlap)
          tied = false
        } else if overlap == current.overlap {
          tied = true
        }
      } else {
        best = (newID, overlap)
      }
    }
    return tied ? nil : best?.id
  }

  /// `mic` or `sys` for a meeting speaker id (`MeetingTrackKind.speakerPrefix`); `nil` for any
  /// id that names no track, which is never matched.
  static func trackPrefix(of speakerId: String) -> String? {
    guard let colon = speakerId.firstIndex(of: ":") else { return nil }
    let prefix = String(speakerId[..<colon])
    let known = MeetingTrackKind.allCases.map(\.speakerPrefix)
    return known.contains(prefix) && speakerId.index(after: colon) < speakerId.endIndex
      ? prefix : nil
  }

  /// A speaker's timed turns as sorted, disjoint `[start, end)` spans, so overlapping turns
  /// are not counted twice.
  static func spans(of speakerId: String, in turns: [Turn]) -> [(start: Int, end: Int)] {
    let raw = turns.compactMap { turn -> (start: Int, end: Int)? in
      guard turn.speakerId == speakerId, let start = turn.startMs, let end = turn.endMs,
        start < end
      else { return nil }
      return (start, end)
    }.sorted { $0.start < $1.start }
    var merged: [(start: Int, end: Int)] = []
    for span in raw {
      if let last = merged.last, span.start <= last.end {
        merged[merged.count - 1].end = max(last.end, span.end)
      } else {
        merged.append(span)
      }
    }
    return merged
  }

  /// Total time two sorted, disjoint span lists share.
  static func overlapMs(_ a: [(start: Int, end: Int)], _ b: [(start: Int, end: Int)]) -> Int {
    var total = 0
    var i = 0
    var j = 0
    while i < a.count, j < b.count {
      let start = max(a[i].start, b[j].start)
      let end = min(a[i].end, b[j].end)
      if start < end { total += end - start }
      if a[i].end < b[j].end { i += 1 } else { j += 1 }
    }
    return total
  }
}
