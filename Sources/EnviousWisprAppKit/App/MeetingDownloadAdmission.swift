import Foundation

/// #4105 (plan R1.3): the one rule for when a live words download may start from EnviousMeet's
/// Live words row: never while a meeting records or processes, so a meeting never competes with
/// a transfer it started. Dictation's own Live Preview download is outside this rule (plan R1.3
/// scopes it to the meeting commands), so the row's copy promises only its own Download. A transfer accepted before a meeting started keeps
/// going: it was not started during the meeting, and Start never waits for it.
///
/// Every meeting download command asks this, in the same main-actor step that starts the
/// transfer, so a disabled button is never the only guard.
@MainActor
enum MeetingDownloadAdmission {
  static func canStart(meetingActive: Bool) -> Bool { !meetingActive }

  /// What the Live words row says in place of Download while a meeting is active.
  static var refusal: String {
    String(
      localized: "Available after the meeting.",
      comment: "EnviousMeet settings, Live Preview row: why Download is unavailable while a meeting records or is being transcribed.")
  }
}
