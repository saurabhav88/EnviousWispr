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
  /// Two-person stretches (`CallPairStretch`), each holding at most five names.
  public var pairs = 4_096

  public static let current = CallEvidenceLimits()

  public init() {}
}

/// Which cap a recording reached. Stored as text in session health.
public enum CallEvidenceCapacity: String, Sendable, Equatable, CaseIterable {
  case segments, names, runs, samples
  case speakingReferences = "speaking_references"
  case rosterReferences = "roster_references"
  case presenceEntries = "presence_entries"
  case sightings, absences, pairs
}

/// What some segments' evidence uses of `CallEvidenceLimits`.
public struct CallEvidenceUsage: Sendable, Equatable {
  /// Distinct stored spellings, by their bytes: two spellings Swift calls equal (composed and
  /// decomposed accents) are still two spellings in the log.
  public var names: Set<[UInt8]> = []
  public var runs = 0
  public var samples = 0
  public var speakingReferences = 0
  public var rosterReferences = 0
  public var presenceEntries = 0
  public var sightings = 0
  public var absences = 0
  public var pairs = 0

  public init() {}

  /// The usage of `segments`, counted the way the log stores them.
  public init(_ segments: [CallSpeakerSegment]) {
    for segment in segments { add(segment) }
  }

  public mutating func insertNames(_ more: some Sequence<String>) {
    for name in more { names.insert(Array(name.utf8)) }
  }

  public mutating func add(_ segment: CallSpeakerSegment) {
    insertNames(segment.roster.names)
    insertNames(segment.roster.selfNames)
    rosterReferences += segment.roster.names.count + segment.roster.selfNames.count
    var previous: CallSpeakerObservation?
    for observation in segment.observations {
      samples += 1
      // A run's samples all name the same spellings.
      if !CallSpeakerRun.continues(previous, with: observation) {
        runs += 1
        speakingReferences += observation.speaking.count
        insertNames(observation.speaking)
      }
      previous = observation
    }
    for entry in segment.presence ?? [] {
      insertNames([entry.name])
      presenceEntries += 1
      sightings += entry.sightings.count
      absences += entry.absences.count
    }
    for pair in segment.pairs ?? [] {
      insertNames(pair.names)
      insertNames(pair.selfNames)
      insertNames(pair.accountNames)
      pairs += 1
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
    if pairs > limits.pairs { return .pairs }
    return nil
  }
}

/// A stored run: consecutive samples with the same talkers, each at its exact time.
/// The log is written as runs and read back as the very same samples, so naming votes are
/// counted exactly as before.
public enum CallSpeakerRun {
  /// The longest gap between two samples of one run, in milliseconds.
  public static let maximumGapMs = 1_500

  /// Whether `next` extends the run that `previous` is in: the same talkers spelled with the
  /// same bytes, in the same order, close enough in time.
  public static func continues(
    _ previous: CallSpeakerObservation?, with next: CallSpeakerObservation
  ) -> Bool {
    guard let previous, sameTalkers(previous, next) else { return false }
    return next.observationMs - previous.observationMs <= maximumGapMs
  }

  /// The same talkers spelled with the same bytes, in the same order.
  public static func sameTalkers(_ a: CallSpeakerObservation?, _ b: CallSpeakerObservation) -> Bool
  {
    guard let a, a.speaking.count == b.speaking.count else { return false }
    return zip(a.speaking, b.speaking).allSatisfy(sameSpelling)
  }

  /// Whether two names have the same bytes; compared as memory, since this runs for every
  /// sample of a long recording.
  public static func sameSpelling(_ a: String, _ b: String) -> Bool {
    guard a.utf8.count == b.utf8.count else { return false }
    let fast = a.utf8.withContiguousStorageIfAvailable { x in
      b.utf8.withContiguousStorageIfAvailable { y in
        x.count == 0 || memcmp(x.baseAddress!, y.baseAddress!, x.count) == 0
      }
    }
    return (fast ?? nil) ?? a.utf8.elementsEqual(b.utf8)
  }
}
