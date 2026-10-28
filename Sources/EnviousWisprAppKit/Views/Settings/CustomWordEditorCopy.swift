import EnviousWisprPostProcessing
import Foundation

/// What the word editor's error area says when a Save or Delete did not happen (#4086).
/// The one table from an edit's outcome to its sentence; the editor keeps the person's draft
/// beside it.
enum CustomWordEditorCopy {
  /// Nil when the word now holds the edit, so the editor may close.
  static func message(for outcome: CustomWordEditOutcome) -> String? {
    switch outcome {
    case .saved, .unchanged: nil
    case .targetGone: saveTargetGone
    case .conflict: saveConflict
    }
  }

  static var saveConflict: String {
    String(
      localized:
        "This word changed while you were editing. Your changes weren't saved. Close this editor and open the word again.",
      comment:
        "Dictionary word editor: Save stopped because the word was changed elsewhere meanwhile.")
  }

  static var saveTargetGone: String {
    String(
      localized: "This word is no longer in your words. Your changes weren't saved.",
      comment: "Dictionary word editor: Save stopped because the word was deleted meanwhile.")
  }

  static var deleteConflict: String {
    String(
      localized:
        "This word changed while this editor was open. Nothing was deleted. Close this editor and open the word again.",
      comment:
        "Dictionary word editor: Delete stopped because the word's text or settings were changed elsewhere meanwhile."
    )
  }

  static var deleteTargetGone: String {
    String(
      localized: "This word is no longer in your words. Nothing was deleted.",
      comment: "Dictionary word editor: Delete found the word already deleted.")
  }
}
