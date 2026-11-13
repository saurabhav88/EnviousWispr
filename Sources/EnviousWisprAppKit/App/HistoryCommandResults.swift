import EnviousWisprCore
import Foundation

/// One History preference change (#3147 §3.4), kept so Undo can put back exactly what it
/// replaced, and only while nothing changed the preference since.
struct HistoryPreferenceChange: Sendable, Equatable {
  let rowID: UUID
  let before: Transcript.PreferredVersion?
  let after: Transcript.PreferredVersion?
}

/// What a History deletion removes (#3147 §3.4 selection mode).
enum HistoryDeleteKind: Sendable {
  /// The audio only; the text stays.
  case recordingsOnly
  /// The whole entry: its text and its audio.
  case textAndRecordings
}

/// What one History deletion actually did, as its owner reported it.
enum HistoryDeleteOutcome: Sendable, Equatable {
  /// The owner removed it.
  case removed
  /// It was already gone (or had no recording to delete).
  case alreadyAbsent
  /// The owner kept it on purpose (a meeting still recording, an entry with no audio kind).
  case skipped
  /// The owner tried and could not; the item stays.
  case failed
}
