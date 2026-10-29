import EnviousWisprCore
import EnviousWisprServices
import Foundation

/// One stretch of the meeting timeline, half-open: `startMs` is inside, `endMs` is not.
package struct MeetingNamingInterval: Sendable, Equatable {
  package let startMs: Int
  package let endMs: Int

  /// `nil` for an empty or reversed stretch, which can hold no evidence.
  package init?(startMs: Int, endMs: Int) {
    guard startMs < endMs else { return nil }
    self.startMs = startMs
    self.endMs = endMs
  }

  func contains(_ ms: Int) -> Bool { startMs <= ms && ms < endMs }
}

/// A stretch the pass wrote a marker for instead of speech (#4013 r3 F1): a piece that failed
/// twice, or audio that exists but cannot be read. `endMs` is `nil` when nothing bounds it (a
/// damaged last file); such a marker excludes everything from its start on, never a guessed end.
/// A marker belongs to one track: only a call-sound marker removes call-sound evidence.
package struct MeetingNamingMarker: Sendable, Equatable {
  package let track: MeetingTrackKind
  package let startMs: Int
  package let endMs: Int?

  package init(track: MeetingTrackKind, startMs: Int, endMs: Int?) {
    self.track = track
    self.startMs = startMs
    self.endMs = endMs
  }
}

/// What the processing pass knows before composition discards piece provenance (#4013 r3 F1),
/// supplied with the composition so naming never infers it from rendered marker text.
///
/// The pass builds this from its `MeetingTrackInput` values (built after #3973 PR C lands);
/// tests supply it directly, which proves the policy, not that extraction.
package struct MeetingNamingEligibility: Sendable, Equatable {
  /// Genuine diarized call-sound speaker ids as composed (`sys:<diarizer id>`). The call
  /// fallback `sys:call`, microphone ids, Both and Unknown are never genuine and are ignored
  /// even if listed.
  package let callSpeakerIDs: Set<String>
  /// Where the call sound held transcribed speech.
  package let callSpeech: [MeetingNamingInterval]
  /// Markers on both tracks. Every call-sound marker is excluded, whichever speaker composition
  /// gave it; a microphone marker says nothing about the call sound and is not.
  package let markers: [MeetingNamingMarker]

  package init(
    callSpeakerIDs: Set<String>, callSpeech: [MeetingNamingInterval],
    markers: [MeetingNamingMarker]
  ) {
    self.callSpeakerIDs = callSpeakerIDs
    self.callSpeech = callSpeech
    self.markers = markers
  }
}

/// Proposed display names for call-sound speakers and why there are none when there are none.
/// Proposals only: the committed count of automatic names is the durable History write's
/// answer (#4013 r3 F4), because manual names may displace these.
package struct MeetingNamingResult: Sendable, Equatable {
  package enum Outcome: String, Sendable, Equatable {
    /// At least one proposal.
    case named
    /// No call-speaker evidence was saved for this meeting.
    case noLog
    /// The call app could not be read: no Accessibility permission.
    case noPermission
    /// The call app was found but could not be read.
    case unreadable
    /// The saved evidence is from a call app with no talker reader, or does not say which
    /// app, or its source does not match that app's reader.
    case unsupported
    /// A rules-driven call app whose frozen rules are missing, no longer decode, or could not
    /// have reported a talker.
    case rulesUnusable
    /// The saved evidence does not say how observation went (an older or newer log).
    case statusUnknown
    /// The saved log has no indicator correction (an older log, or a surface with none
    /// configured when it recorded); votes cannot be placed on the audio.
    case lagUnmeasured
    /// No genuine call-sound speaker has eligible speech, or eligibility was not supplied.
    case noEligibleSpeakers
    /// No usable talking evidence fell inside eligible speech.
    case noSignal
    /// Evidence existed but no speaker reached a unique, qualifying name.
    case ambiguous
  }

  /// Display names keyed by the composition's speaker id.
  package let proposals: [String: String]
  package let outcome: Outcome
  /// How many of `proposals` the one-on-one rule added (#4013 chunk 14); a local count only.
  package var pairProposals = 0
}

/// Automatic speaker naming (#4013 §3 item 5, r2 items 7-8, r3 F1). Pure and deterministic: the
/// same composition, eligibility and log always give the same proposals, on a fresh pass and on
/// one that reused checkpointed words. It never changes the composition.
///
/// For each genuine call-sound speaker, every saved observation whose audio-aligned time
/// (`observationMs - lag`) falls inside that speaker's eligible speech is one vote for the one
/// non-self name the app showed talking. A speaker is named when its top name has at least
/// `minimumVotes` votes and at least `minimumShare` of ALL its votes (competing names included),
/// and no other speaker claims that name as strongly. Anything less leaves "Speaker N".
///
/// One-on-one rule (#4013 chunk 14, after Granola 7.668.3's `zN`): where the saved evidence
/// proves a two-person call (`CallPairStretch`) and the app marked which of the two is the user,
/// the call sound in that stretch can only be the other person. A speaker with no vote name
/// takes that name when it is the only call-sound voice in such stretches (`pairProposals`).
/// Votes always come first; the rule only fills speakers votes left as "Speaker N".
package enum MeetingSpeakerNamer {
  /// Proposed in the plan, to be confirmed by the real-call measurements (C1).
  package static let minimumVotes = 3
  package static let minimumShare = 0.7
  /// A two-person stretch counts only after this long, unless the other person is the only one
  /// the recording ever showed (Granola `zN`: 15,000 ms).
  package static let minimumPairStretchMs = 15_000
  /// The least call speech one speaker needs inside a stretch for it to name them; an
  /// engineering threshold to validate with the real-call receipts, not a Granola constant.
  package static let minimumPairSpeechMs = 3_000

  package static func propose(
    composition: MeetingComposition, eligibility: MeetingNamingEligibility?, log: CallSpeakerLog?
  ) -> MeetingNamingResult {
    func none(_ outcome: MeetingNamingResult.Outcome) -> MeetingNamingResult {
      MeetingNamingResult(proposals: [:], outcome: outcome)
    }
    // A log with no segment read no call at all.
    guard let log, !log.segments.isEmpty else { return none(.noLog) }
    // Each segment is evidence on its own: its status, its surface and source, its own lag.
    var usable: [(segment: CallSpeakerSegment, lag: CallSpeakerLag)] = []
    var refusals: [MeetingNamingResult.Outcome] = []
    for segment in log.segments {
      if let refusal = segmentRefusal(segment, rules: log.rules) {
        refusals.append(refusal)
      } else if let lag = segment.lag {
        usable.append((segment, lag))
      }
    }
    if usable.isEmpty {
      // One reason when every segment gives the same one; mixed reasons are not guessed at.
      let reasons = Set(refusals)
      return none(reasons.count == 1 ? refusals[0] : .statusUnknown)
    }
    // `rosterFromParticipantList` is provenance only (#4013 r5 item 1): a tile roster names
    // people too. Only observations admitted by `CallSpeakerAdmission` were saved, and a name
    // two distinct participants share is excluded below.
    guard let eligibility else { return none(.noEligibleSpeakers) }

    let speech = eligibleSpeech(composition: composition, eligibility: eligibility)
    guard !speech.isEmpty else { return none(.noEligibleSpeakers) }

    // A name is nameable only where its own segment shows it once, and never when any segment
    // shows it shared or as the user. Votes from every segment add up before any name is chosen.
    let selfNames = Set(log.segments.flatMap(\.roster.selfNames))
    let shared = Set(
      log.segments.flatMap { segment -> [String] in
        var counts: [String: Int] = [:]
        for name in segment.roster.names { counts[name, default: 0] += 1 }
        return counts.filter { $0.value > 1 }.map(\.key)
      })
    var votes: [String: [String: Int]] = [:]
    for (segment, lag) in usable {
      let nameable = uniqueRosterNames(segment.roster).subtracting(shared).subtracting(selfNames)
      let presence = Dictionary(
        (segment.presence ?? []).map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
      for observation in segment.observations {
        let others = observation.speaking.filter { !selfNames.contains($0) }
        // Exactly one person talking, and that name names one person on this call.
        guard others.count == 1, let name = others.first, nameable.contains(name) else {
          continue
        }
        // A name the participant list had confirmed gone at that moment contradicts the vote.
        // Presence is on the recording clock, like the observation before its lag.
        if presence[name]?.isConfirmedAbsent(at: observation.observationMs) == true { continue }
        let (aligned, overflow) = observation.observationMs.subtractingReportingOverflow(
          lag.milliseconds)
        // The voice it points to must lie in this segment's own stretch, start included and end
        // excluded (the next segment may start there), so a lag never carries a vote onto
        // another call's speech or into a gap nothing read.
        guard !overflow, aligned >= segment.startMs, aligned < segment.endMs ?? Int.max else {
          continue
        }
        // At most one vote per speaker per observation, however many of its turns overlap.
        for (speaker, intervals) in speech where intervals.contains(where: { $0.contains(aligned) })
        {
          votes[speaker, default: [:]][name, default: 0] += 1
        }
      }
    }
    // Each speaker's qualifying name, if any.
    var claims: [String: [(speaker: String, votes: Int)]] = [:]
    for (speaker, tally) in votes {
      let total = tally.values.reduce(0, +)
      guard let top = tally.values.max() else { continue }
      let leaders = tally.filter { $0.value == top }
      guard leaders.count == 1, let winner = leaders.first,
        top >= minimumVotes, Double(top) >= minimumShare * Double(total)
      else { continue }
      claims[winner.key, default: []].append((speaker, top))
    }
    // A name goes only to its unique strongest claimant; an equal claim assigns it to none.
    var proposals: [String: String] = [:]
    for (name, claimants) in claims {
      guard let strongest = claimants.map(\.votes).max() else { continue }
      let atTop = claimants.filter { $0.votes == strongest }
      if atTop.count == 1 { proposals[atTop[0].speaker] = name }
    }
    let voteOutcome: MeetingNamingResult.Outcome =
      votes.isEmpty ? .noSignal : (proposals.isEmpty ? .ambiguous : .named)

    let added = pairProposals(
      log: log, segments: usable.map(\.segment), speech: speech, shared: shared,
      votes: votes, voteProposals: proposals)
    let merged = proposals.merging(added) { vote, _ in vote }
    var result = MeetingNamingResult(
      proposals: merged, outcome: merged.isEmpty ? voteOutcome : .named)
    result.pairProposals = merged.count - proposals.count
    return result
  }

  /// The one-on-one rule's names for speakers votes did not name (plan R1.5, R2.4, R3.2).
  static func pairProposals(
    log: CallSpeakerLog, segments: [CallSpeakerSegment],
    speech: [String: [MeetingNamingInterval]], shared: Set<String>,
    votes: [String: [String: Int]], voteProposals: [String: String]
  ) -> [String: String] {
    // The 15 s rule is waived only when the whole recording proves the other person was the
    // only one: every segment was read whole (`wholeReading`), and in every segment the app
    // marked exactly one name as the user (a user who changed name, or none marked, could hide
    // someone). Then every name the recording showed, less that segment's user, is a person who
    // is not the user; judged segment by segment, so the user's name in one call never erases a
    // real person of that name in another.
    let waivable = log.segments.allSatisfy { segment in
      segment.status == .observed && wholeReading(segment) && marks(in: segment).count == 1
    }
    let others = Set(
      log.segments.flatMap { segment -> [String] in
        let marked = marks(in: segment)
        let names =
          segment.roster.names + (segment.presence ?? []).map(\.name)
          + (segment.pairs ?? []).flatMap(\.names)
        return names.filter { !marked.contains($0) }
      }
    ).union(shared)

    // Windows that name one speaker, by speaker and name.
    var windows: [String: [String: [MeetingNamingInterval]]] = [:]
    for segment in segments {
      for stretch in segment.pairs ?? [] {
        guard let remote = remote(in: stretch, segmentSelf: segment.roster.selfNames),
          !shared.contains(remote),
          stretch.lastMs - stretch.firstMs >= minimumPairStretchMs
            || (waivable && others == [remote]),
          let window = MeetingNamingInterval(startMs: stretch.firstMs, endMs: stretch.lastMs)
        else { continue }
        // Exactly one call-sound voice: one speaker with enough speech, nobody else at all.
        var heard: [(speaker: String, ms: Int)] = []
        for (speaker, intervals) in speech {
          let ms = length(intersect(intervals, [window]))
          if ms > 0 { heard.append((speaker, ms)) }
        }
        guard heard.count == 1, heard[0].ms >= minimumPairSpeechMs else { continue }
        windows[heard[0].speaker, default: [:]][remote, default: []].append(window)
      }
    }

    // Each speaker's claim: its overlapping windows counted once, per name.
    var claims: [String: [(speaker: String, ms: Int)]] = [:]
    for (speaker, byName) in windows where voteProposals[speaker] == nil {
      let measured = byName.mapValues { length(intersect(speech[speaker] ?? [], normalized($0))) }
      let total = measured.values.reduce(0, +)
      guard let top = measured.values.max(), total > 0 else { continue }
      let leaders = measured.filter { $0.value == top }
      guard leaders.count == 1, let winner = leaders.first,
        Double(top) >= minimumShare * Double(total)
      else { continue }
      // Talker votes for this speaker that point at anyone else contradict the rule.
      if (votes[speaker] ?? [:]).keys.contains(where: { $0 != winner.key }) { continue }
      claims[winner.key, default: []].append((speaker, top))
    }
    let reserved = Set(voteProposals.values)
    var proposals: [String: String] = [:]
    for (name, claimants) in claims where !reserved.contains(name) {
      guard let strongest = claimants.map(\.ms).max() else { continue }
      let atTop = claimants.filter { $0.ms == strongest }
      if atTop.count == 1 { proposals[atTop[0].speaker] = name }
    }
    return proposals
  }

  /// The other person in a two-person stretch, or `nil` when the evidence does not identify
  /// exactly one of the two as the user (plan R3.2, r4). The stretch's marks come first; the
  /// segment's marks may confirm but never contradict them. Only when the app marked nobody in
  /// the stretch or the segment does the signed-in account name decide, and only when it is
  /// exactly one of the two (the founder's D5 exception, plan r4).
  static func remote(in stretch: CallPairStretch, segmentSelf: [String]) -> String? {
    let pair = Set(stretch.names)
    guard pair.count == 2 else { return nil }
    let stretchSelf = Set(stretch.selfNames)
    // A mark for someone not on this two-person call is a contradiction, not an absence.
    guard stretchSelf.isSubset(of: pair), stretchSelf.count <= 1 else { return nil }
    let segmentMarked = Set(segmentSelf).intersection(pair)
    let user: String
    if let marked = stretchSelf.first {
      guard segmentMarked.isSubset(of: [marked]) else { return nil }
      user = marked
    } else if !segmentSelf.isEmpty {
      guard segmentMarked.count == 1, let marked = segmentMarked.first else { return nil }
      user = marked
    } else {
      let account = Set(stretch.accountNames).intersection(pair)
      guard stretch.accountNames.count == 1, account.count == 1, let named = account.first else {
        return nil
      }
      user = named
    }
    return pair.subtracting([user]).first
  }

  /// Whether every capture of a segment was read and kept: `.observed` says only that one was.
  /// A failed, partial, skipped, stale or refused capture is a moment someone could have been on
  /// the call unseen, so it keeps the 15 s rule. A segment without health counts is not whole.
  static func wholeReading(_ segment: CallSpeakerSegment) -> Bool {
    guard let health = segment.health, health.captureAttempts > 0 else { return false }
    return health.completeCaptures == health.captureAttempts
      && health.truncatedCaptures == 0 && health.unreadableCaptures == 0
      && health.unresolvedScopeCaptures == 0 && health.skippedBusyTicks == 0
      && health.skippedDictationTicks == 0 && health.missingPermissionTicks == 0
      && health.staleResultDrops == 0 && (health.invalidNameReadings ?? 0) == 0
      && (health.evidenceCapacityDrops ?? 0) == 0
  }

  /// Every name the app marked as the user anywhere in a segment.
  static func marks(in segment: CallSpeakerSegment) -> Set<String> {
    Set(segment.roster.selfNames + (segment.pairs ?? []).flatMap(\.selfNames))
  }

  static func length(_ intervals: [MeetingNamingInterval]) -> Int {
    intervals.reduce(0) { $0 + ($1.endMs - $1.startMs) }
  }

  /// Why a segment is not naming evidence, in the order a single-surface log was judged: its
  /// status, then its reader, then its lag. `nil` when it may vote.
  static func segmentRefusal(_ segment: CallSpeakerSegment, rules: FrozenTalkerRules?)
    -> MeetingNamingResult.Outcome?
  {
    switch segment.status {
    case .observed: break
    case .noPermission: return .noPermission
    case .unreadable: return .unreadable
    case .unsupported: return .unsupported
    case nil: return .statusUnknown
    }
    if let refusal = evidenceRefusal(segment, rules: rules) { return refusal }
    return segment.lag == nil ? .lagUnmeasured : nil
  }

  /// Whether the segment could only have come from a reader that reports talkers: a talker
  /// surface, the source that surface's reader writes, and for a rules-driven surface frozen
  /// rules that still decode (the rules store's own decoder) and allow that surface to report a
  /// talker.
  static func evidenceRefusal(_ segment: CallSpeakerSegment, rules frozenRules: FrozenTalkerRules?)
    -> MeetingNamingResult.Outcome?
  {
    guard let surface = segment.surface else { return .unsupported }
    switch surface {
    // Native readers: the app's own words, or Zoom web's layout, never selector rules.
    case .zoomApp, .teamsApp, .zoomWeb:
      return segment.source == .app ? nil : .unsupported
    case .meet, .teamsWeb, .slackApp, .slackWeb:
      guard segment.source == .rules else { return .unsupported }
      guard let frozen = frozenRules, let rules = TalkerRulesSnapshot.thaw(frozen),
        rules.rule(for: surface).mayReportTalker
      else { return .rulesUnusable }
      return nil
    case .facetime, .webex, .dialpad, .gather, .lark, .voov, .whereby, .jitsi:
      return .unsupported
    }
  }

  /// Each genuine call-sound speaker's turns, cut to call speech and with every marker removed.
  /// Speakers left with no eligible time are absent.
  static func eligibleSpeech(
    composition: MeetingComposition, eligibility: MeetingNamingEligibility
  ) -> [String: [MeetingNamingInterval]] {
    let genuine = eligibility.callSpeakerIDs.filter(isGenuineCallSpeaker)
    let callSpeech = normalized(eligibility.callSpeech)
    var result: [String: [MeetingNamingInterval]] = [:]
    for turn in composition.turns where genuine.contains(turn.speakerId) {
      guard let start = turn.startMs, let end = turn.endMs,
        let interval = MeetingNamingInterval(startMs: start, endMs: end)
      else { continue }
      result[turn.speakerId, default: []].append(interval)
    }
    for (speaker, turns) in result {
      var kept = intersect(normalized(turns), callSpeech)
      for marker in eligibility.markers where marker.track == .callSound {
        kept = subtract(marker, from: kept)
      }
      result[speaker] = kept.isEmpty ? nil : kept
    }
    return result
  }

  static func isGenuineCallSpeaker(_ id: String) -> Bool {
    let prefix = "\(MeetingTrackKind.callSound.speakerPrefix):"
    return id.hasPrefix(prefix) && id.count > prefix.count
      && id != MeetingTranscriptComposer.fallbackCallSpeakerID
  }

  /// Roster names that appear exactly once; self names are never candidates.
  static func uniqueRosterNames(_ roster: CallSpeakerRoster) -> Set<String> {
    var counts: [String: Int] = [:]
    for name in roster.names { counts[name, default: 0] += 1 }
    let selfNames = Set(roster.selfNames)
    return Set(counts.filter { $0.value == 1 && !selfNames.contains($0.key) }.keys)
  }

  // MARK: - Interval sets (sorted, disjoint, half-open)

  static func normalized(_ intervals: [MeetingNamingInterval]) -> [MeetingNamingInterval] {
    let sorted = intervals.sorted { ($0.startMs, $0.endMs) < ($1.startMs, $1.endMs) }
    var merged: [MeetingNamingInterval] = []
    for interval in sorted {
      if let last = merged.last, interval.startMs <= last.endMs {
        if interval.endMs > last.endMs,
          let joined = MeetingNamingInterval(
            startMs: last.startMs, endMs: interval.endMs)
        {
          merged[merged.count - 1] = joined
        }
      } else {
        merged.append(interval)
      }
    }
    return merged
  }

  static func intersect(_ a: [MeetingNamingInterval], _ b: [MeetingNamingInterval])
    -> [MeetingNamingInterval]
  {
    var result: [MeetingNamingInterval] = []
    var i = 0
    var j = 0
    while i < a.count, j < b.count {
      if let overlap = MeetingNamingInterval(
        startMs: max(a[i].startMs, b[j].startMs), endMs: min(a[i].endMs, b[j].endMs))
      {
        result.append(overlap)
      }
      if a[i].endMs < b[j].endMs { i += 1 } else { j += 1 }
    }
    return result
  }

  static func subtract(_ marker: MeetingNamingMarker, from intervals: [MeetingNamingInterval])
    -> [MeetingNamingInterval]
  {
    intervals.flatMap { interval -> [MeetingNamingInterval] in
      // An open-ended marker reaches past every interval.
      let markerEnd = marker.endMs ?? Int.max
      // A zero-length bounded marker covers no time; an open-ended one at its start does.
      guard marker.startMs < markerEnd, marker.startMs < interval.endMs,
        markerEnd > interval.startMs
      else { return [interval] }
      return [
        MeetingNamingInterval(startMs: interval.startMs, endMs: marker.startMs),
        MeetingNamingInterval(startMs: markerEnd, endMs: interval.endMs),
      ].compactMap { $0 }
    }
  }
}
