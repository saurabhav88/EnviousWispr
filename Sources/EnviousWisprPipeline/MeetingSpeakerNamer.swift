import EnviousWisprCore
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
package struct MeetingNamingMarker: Sendable, Equatable {
  package let startMs: Int
  package let endMs: Int?

  package init(startMs: Int, endMs: Int?) {
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
  /// Markers on either track. Every one is excluded, whichever speaker composition gave it.
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
    /// The call app has no talker reader.
    case unsupported
    /// The saved evidence does not say how observation went (an older or newer log).
    case statusUnknown
    /// The talking indicator's lag on this call app was never measured; votes cannot be
    /// placed on the audio.
    case lagUnmeasured
    /// The roster did not come from the app's participant list, so a name's uniqueness on the
    /// call cannot be established.
    case rosterUncertain
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
package enum MeetingSpeakerNamer {
  /// Proposed in the plan, to be confirmed by the real-call measurements (C1).
  package static let minimumVotes = 3
  package static let minimumShare = 0.7

  package static func propose(
    composition: MeetingComposition, eligibility: MeetingNamingEligibility?, log: CallSpeakerLog?
  ) -> MeetingNamingResult {
    func none(_ outcome: MeetingNamingResult.Outcome) -> MeetingNamingResult {
      MeetingNamingResult(proposals: [:], outcome: outcome)
    }
    guard let log else { return none(.noLog) }
    switch log.status {
    case .observed: break
    case .noPermission: return none(.noPermission)
    case .unreadable: return none(.unreadable)
    case .unsupported: return none(.unsupported)
    case nil: return none(.statusUnknown)
    }
    guard let lag = log.lag else { return none(.lagUnmeasured) }
    guard log.rosterFromParticipantList == true else { return none(.rosterUncertain) }
    guard let eligibility else { return none(.noEligibleSpeakers) }

    let speech = eligibleSpeech(composition: composition, eligibility: eligibility)
    guard !speech.isEmpty else { return none(.noEligibleSpeakers) }

    let nameable = uniqueRosterNames(log.roster)
    let selfNames = Set(log.roster.selfNames)
    var votes: [String: [String: Int]] = [:]
    for observation in log.observations {
      let others = observation.speaking.filter { !selfNames.contains($0) }
      // Exactly one person talking, and that name names one person on this call.
      guard others.count == 1, let name = others.first, nameable.contains(name) else { continue }
      let (aligned, overflow) = observation.observationMs.subtractingReportingOverflow(
        lag.milliseconds)
      guard !overflow else { continue }
      // At most one vote per speaker per observation, however many of its turns overlap.
      for (speaker, intervals) in speech where intervals.contains(where: { $0.contains(aligned) }) {
        votes[speaker, default: [:]][name, default: 0] += 1
      }
    }
    guard !votes.isEmpty else { return none(.noSignal) }

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
    return MeetingNamingResult(
      proposals: proposals, outcome: proposals.isEmpty ? .ambiguous : .named)
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
      for marker in eligibility.markers { kept = subtract(marker, from: kept) }
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
