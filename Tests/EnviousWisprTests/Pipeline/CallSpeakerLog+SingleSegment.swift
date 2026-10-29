import EnviousWisprCore

/// Test fixtures only (#4013 13B.2): most tests describe a recording read from one call source,
/// so they build and read a log of exactly one segment from 0 with the single-surface fields a
/// format-1 log had. Production code has no such view: it reads `segments`.
extension CallSpeakerLog {
  init(
    surface: CallSpeakerSurface?, source: CallSpeakerSource?,
    status: CallSpeakerObservationStatus?, lag: CallSpeakerLag?, rules: FrozenTalkerRules?,
    roster: CallSpeakerRoster, rosterFromParticipantList: Bool?,
    observations: [CallSpeakerObservation]
  ) {
    self.init(
      rules: rules,
      segments: [
        CallSpeakerSegment(
          startMs: 0, endMs: nil, endReason: nil, surface: surface, source: source,
          status: status, lag: lag, roster: roster,
          rosterFromParticipantList: rosterFromParticipantList, observations: observations)
      ])
  }

  /// The one segment of a single-source log.
  var onlySegment: CallSpeakerSegment {
    precondition(segments.count == 1, "a single-source fixture has one segment")
    return segments[0]
  }

  var surface: CallSpeakerSurface? { onlySegment.surface }
  var source: CallSpeakerSource? { onlySegment.source }
  var status: CallSpeakerObservationStatus? { onlySegment.status }
  var lag: CallSpeakerLag? { onlySegment.lag }
  var roster: CallSpeakerRoster { onlySegment.roster }
  var rosterFromParticipantList: Bool? { onlySegment.rosterFromParticipantList }
  var observations: [CallSpeakerObservation] { onlySegment.observations }
  var surfaceRaw: String? { onlySegment.surfaceRaw }
  var sourceRaw: String? { onlySegment.sourceRaw }
  var statusRaw: String? { onlySegment.statusRaw }
}
