import Foundation

/// The rule a recording used to turn participant readings into presence (#4013 13B), frozen in
/// its evidence so Transcribe again never reinterprets an old recording with newer constants.
///
/// A name stops being present only when this many consecutive complete participant lists, each
/// read within `maximumGapMs` of the one before and together spanning at least
/// `minimumAbsenceSpanMs`, all leave it out. Anything else (a partial list, visible tiles only,
/// an unreadable copy, a pause for dictation, a lost source) breaks the run: it can never prove
/// that someone left.
public struct CallPresencePolicy: Sendable, Equatable, Codable {
  public let version: Int
  public let absenceReadings: Int
  public let minimumAbsenceSpanMs: Int
  public let maximumGapMs: Int

  public init(version: Int, absenceReadings: Int, minimumAbsenceSpanMs: Int, maximumGapMs: Int) {
    self.version = version
    self.absenceReadings = absenceReadings
    self.minimumAbsenceSpanMs = minimumAbsenceSpanMs
    self.maximumGapMs = maximumGapMs
  }

  /// Proposed in the 13B plan: three lists over at least a second, ticks 500 ms apart.
  public static let current = CallPresencePolicy(
    version: 1, absenceReadings: 3, minimumAbsenceSpanMs: 1_000, maximumGapMs: 1_500)
}

/// When one display name was seen in a segment. A name, not a person: two people sharing a
/// name share this record (the roster keeps how many there were).
public struct CallNamePresence: Sendable, Equatable, Codable {
  /// One stretch the name was shown, from its first to its last reading.
  public struct Sighting: Sendable, Equatable, Codable {
    public let firstSeenMs: Int
    public let lastSeenMs: Int
    /// True when the stretch ended because the participant list confirmed the name gone;
    /// false while it was still shown when collection ended (no claim that they left).
    public let absenceConfirmed: Bool

    public init(firstSeenMs: Int, lastSeenMs: Int, absenceConfirmed: Bool) {
      self.firstSeenMs = firstSeenMs
      self.lastSeenMs = lastSeenMs
      self.absenceConfirmed = absenceConfirmed
    }
  }

  /// Complete participant lists left the name out from `firstMissingMs`, confirmed at
  /// `confirmedAtMs`. Neither is an exact time of leaving: the person left after the sighting
  /// before it and by `firstMissingMs`.
  public struct Absence: Sendable, Equatable, Codable {
    public let firstMissingMs: Int
    public let confirmedAtMs: Int

    public init(firstMissingMs: Int, confirmedAtMs: Int) {
      self.firstMissingMs = firstMissingMs
      self.confirmedAtMs = confirmedAtMs
    }
  }

  public static let maximumSightings = 200

  public let name: String
  public let sightings: [Sighting]
  public let absences: [Absence]
  /// The name was seen again after its sightings were full, so whether it is still gone after
  /// its last absence is not known (`nil` in older logs means false).
  public let sightingsFull: Bool?

  public init(name: String, sightings: [Sighting], absences: [Absence], sightingsFull: Bool? = nil)
  {
    self.name = name
    self.sightings = sightings
    self.absences = absences
    self.sightingsFull = sightingsFull
  }

  /// Whether the name was confirmed gone at `ms`: after a confirmed absence began and before it
  /// was next seen. Time before its first sighting or after its last one is not an absence, and
  /// nor is time after the last absence once the sightings were full.
  public func isConfirmedAbsent(at ms: Int) -> Bool {
    absences.contains { absence in
      guard ms >= absence.firstMissingMs else { return false }
      guard let back = sightings.first(where: { $0.firstSeenMs > absence.firstMissingMs }) else {
        return sightingsFull != true
      }
      return ms < back.firstSeenMs
    }
  }

  /// Sightings in time order without overlap, only the last unconfirmed; one absence after
  /// each confirmed sighting and before the next sighting, in the same order.
  var shapeProblem: String? {
    guard sightings.count <= Self.maximumSightings, absences.count <= Self.maximumSightings
    else { return "too many" }
    var previous: Int?
    for (index, sighting) in sightings.enumerated() {
      guard sighting.lastSeenMs >= sighting.firstSeenMs,
        previous.map({ sighting.firstSeenMs > $0 }) ?? true
      else { return "sightings out of order" }
      if !sighting.absenceConfirmed, index != sightings.count - 1 {
        return "an unconfirmed sighting before another"
      }
      previous = sighting.lastSeenMs
    }
    let confirmed = sightings.enumerated().filter(\.element.absenceConfirmed)
    guard confirmed.count == absences.count else { return "absences do not match sightings" }
    for ((index, sighting), absence) in zip(confirmed, absences) {
      guard sighting.lastSeenMs < absence.firstMissingMs,
        absence.firstMissingMs <= absence.confirmedAtMs
      else { return "absence out of order" }
      if index + 1 < sightings.count, sightings[index + 1].firstSeenMs <= absence.confirmedAtMs {
        return "seen again before the absence was confirmed"
      }
    }
    return nil
  }
}

/// How one segment's captures went, as counts only: no names, no content (#4013 13B). Kept on
/// this Mac with the evidence. Counters overlap: an attempt is complete, truncated or unreadable;
/// a complete one may still be out of scope or withheld; admitted ones are speaking or quiet.
public struct CallCaptureHealth: Sendable, Equatable, Codable {
  public var captureAttempts = 0
  public var completeCaptures = 0
  public var truncatedCaptures = 0
  public var unreadableCaptures = 0
  public var unresolvedScopeCaptures = 0
  public var admittedSpeakingObservations = 0
  public var admittedQuietObservations = 0
  /// By `CallNamingAdmission.Reason` raw value.
  public var withheldByReason: [String: Int] = [:]
  public var skippedBusyTicks = 0
  public var skippedDictationTicks = 0
  public var missingPermissionTicks = 0
  /// Copies dropped at delivery because something changed while they were taken.
  public var staleResultDrops = 0
  /// Readings not kept because a name in them is longer than a log may hold.
  public var invalidNameReadings: Int? = 0
  /// Readings not kept because the recording's evidence reached `CallEvidenceLimits`.
  public var evidenceCapacityDrops: Int? = 0
  public var walkDurationCount = 0
  public var walkDurationTotalUs = 0
  public var walkDurationMaxUs = 0
  public var nodesVisitedTotal = 0
  public var nodesVisitedMax = 0
  /// Reads the call app could not answer, button subtrees left unread and windows skipped as
  /// not the call (#4013 13B receipt), summed over copies.
  /// `invalidNameReadings`, `evidenceCapacityDrops` and these three came later: a health object
  /// written before them reads them as unknown (`nil`), never zero; a new one starts them at zero.
  public var failedReads: Int? = 0
  public var prunedControls: Int? = 0
  public var skippedWindows: Int? = 0

  public init() {}

  /// Adds one copy's walk time, size and what it could not read or left out.
  public mutating func noteWalk(
    durationUs: Int, nodes: Int, failedReads: Int = 0, prunedControls: Int = 0,
    skippedWindows: Int = 0
  ) {
    self.failedReads = (self.failedReads ?? 0) + max(0, failedReads)
    self.prunedControls = (self.prunedControls ?? 0) + max(0, prunedControls)
    self.skippedWindows = (self.skippedWindows ?? 0) + max(0, skippedWindows)
    walkDurationCount += 1
    walkDurationTotalUs += max(0, durationUs)
    walkDurationMaxUs = max(walkDurationMaxUs, durationUs)
    nodesVisitedTotal += max(0, nodes)
    nodesVisitedMax = max(nodesVisitedMax, nodes)
  }
}

/// How the recording's search for its call went, as counts only (#4013 13B).
public struct CallSessionHealth: Sendable, Equatable, Codable {
  /// Discovery's cached answer, one sample per session check (every 500 ms), by kind: one
  /// call, none, two competing, or unreadable. Samples, not changes, fresh scans or seconds.
  public var uniqueSources = 0
  public var noSource = 0
  public var ambiguousSources = 0
  public var unavailableSources = 0
  public var saveAttempts = 0
  public var saveFailures = 0
  /// The cap that stopped speaker collection (`CallEvidenceCapacity` raw value); `nil` while
  /// none was reached.
  public var capacityReason: String?

  public init() {}
}
