import Foundation

/// How much speaker evidence one recording may keep (#4013 13B.5), counted across all its
/// segments. Like the leading meeting apps, the log records runs of the same talkers instead of
/// every sample, under fixed count caps; with every name bounded too, the whole file always
/// fits what storage accepts (`MeetingStore.maximumCallSpeakersBytes`; the worst-case
/// arithmetic is checked by `CallSpeakerLogSizeTests`). Past a cap, collection keeps what it has
/// and stops; nothing is evicted or truncated.
public struct CallEvidenceLimits: Sendable, Equatable {
  /// Distinct stored name spellings (roster, self, presence and talkers together).
  public var names = 512
  /// Runs of the same talkers, quiet runs included.
  public var runs = 10_000
  /// Samples kept inside runs.
  public var samples = 345_600
  /// Talker names named by runs, summed over runs.
  public var speakingReferences = 40_000
  /// Roster and self names, duplicates included, summed over segments.
  public var rosterReferences = 20_000
  /// Presence entries (one per name per segment).
  public var presenceEntries = 4_096
  /// Sightings over all presence entries.
  public var sightings = 8_000
  /// Absences over all presence entries.
  public var absences = 8_000

  public static let current = CallEvidenceLimits()

  public init() {}
}

/// Which cap a recording reached. Stored as text in session health.
public enum CallEvidenceCapacity: String, Sendable, Equatable, CaseIterable {
  case segments, names, runs, samples
  case speakingReferences = "speaking_references"
  case rosterReferences = "roster_references"
  case presenceEntries = "presence_entries"
  case sightings, absences
}

/// What some segments' evidence uses of `CallEvidenceLimits`.
public struct CallEvidenceUsage: Sendable, Equatable {
  public var names: Set<String> = []
  public var runs = 0
  public var samples = 0
  public var speakingReferences = 0
  public var rosterReferences = 0
  public var presenceEntries = 0
  public var sightings = 0
  public var absences = 0

  public init() {}

  /// The usage of `segments`, counted the way the log stores them.
  public init(_ segments: [CallSpeakerSegment]) {
    for segment in segments { add(segment) }
  }

  public mutating func add(_ segment: CallSpeakerSegment) {
    names.formUnion(segment.roster.names)
    names.formUnion(segment.roster.selfNames)
    rosterReferences += segment.roster.names.count + segment.roster.selfNames.count
    var previous: CallSpeakerObservation?
    for observation in segment.observations {
      names.formUnion(observation.speaking)
      samples += 1
      if !CallSpeakerRun.continues(previous, with: observation) {
        runs += 1
        speakingReferences += observation.speaking.count
      }
      previous = observation
    }
    for entry in segment.presence ?? [] {
      names.insert(entry.name)
      presenceEntries += 1
      sightings += entry.sightings.count
      absences += entry.absences.count
    }
  }

  /// The first cap this usage passes, or `nil`.
  public func exceeded(_ limits: CallEvidenceLimits) -> CallEvidenceCapacity? {
    if names.count > limits.names { return .names }
    if runs > limits.runs { return .runs }
    if samples > limits.samples { return .samples }
    if speakingReferences > limits.speakingReferences { return .speakingReferences }
    if rosterReferences > limits.rosterReferences { return .rosterReferences }
    if presenceEntries > limits.presenceEntries { return .presenceEntries }
    if sightings > limits.sightings { return .sightings }
    if absences > limits.absences { return .absences }
    return nil
  }
}

/// A stored run: consecutive samples with the same talkers, each at its exact time.
/// The log is written as runs and read back as the very same samples, so naming votes are
/// counted exactly as before.
public enum CallSpeakerRun {
  /// The longest gap between two samples of one run, in milliseconds.
  public static let maximumGapMs = 1_500

  /// Whether `next` extends the run that `previous` is in.
  public static func continues(
    _ previous: CallSpeakerObservation?, with next: CallSpeakerObservation
  ) -> Bool {
    guard let previous else { return false }
    return previous.speaking == next.speaking
      && next.observationMs - previous.observationMs <= maximumGapMs
  }
}
