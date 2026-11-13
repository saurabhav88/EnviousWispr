import EnviousWisprCore
import Foundation

// #3147 PR4A contract (main). Lane A draws the meeting cards and after view against these
// protocols; lane B implements `MeetingNotesAccessing` on the existing documents owner; lane C
// implements `MeetingSummaryReferencing`. No placeholder production implementation exists.

/// Whether a meeting's notes are durable.
enum MeetingNotesSaveState: Equatable {
  case loading, saved, saving, failed
}

/// What the notes editor draws: the app-owned draft, never a second UI-owned store.
struct MeetingNotesSnapshot: Equatable {
  let document: MeetingNotesDocument
  /// The draft revision (bumped on every accepted edit), not a disk revision.
  let revision: Int
  let canEdit: Bool
  let saveState: MeetingNotesSaveState
}

@MainActor
protocol MeetingNotesAccessing: AnyObject {
  func snapshot(for meetingID: UUID) -> MeetingNotesSnapshot
  /// Applies `edit` only over `expectedRevision`; false when the draft moved on, the meeting is
  /// gone or the notes cannot be edited. `atMs` is the meeting time a new block starts at.
  func apply(
    _ edit: MeetingNotesEdit, to meetingID: UUID, expectedRevision: Int, atMs: Int?
  ) -> Bool
  /// Writes the draft now; true when it is durable.
  func flush(_ meetingID: UUID) async -> Bool
}

@MainActor
protocol MeetingSummaryReferencing: AnyObject {
  /// The structured summary for the meeting's CURRENT summary, or nil (none, edited, out of date).
  func document(for meetingID: UUID) -> MeetingSummaryDocument?
  /// The sources a summary item may link to, only when the validator accepted them now.
  func validatedSource(for itemID: UUID, meetingID: UUID) -> ValidatedMeetingSummarySource?
}

/// #3147 PR4A: no summary links, for a meeting screen built without the app's validator.
final class NoMeetingSummaryReferences: MeetingSummaryReferencing {
  func document(for meetingID: UUID) -> MeetingSummaryDocument? { nil }
  func validatedSource(for itemID: UUID, meetingID: UUID) -> ValidatedMeetingSummarySource? {
    nil
  }
}
