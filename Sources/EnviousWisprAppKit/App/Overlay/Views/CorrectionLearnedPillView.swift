import AppKit
import SwiftUI

// MARK: - Auto-learn Undo pill (#996, 2026-09-21 plan §3.1 step 9)

/// Every string the Undo pill, its results and its announcements show. The
/// overlay owns the copy; the coordinator hands over a typed model and a typed
/// error and never a sentence. Wording is the founder's (2026-09-21): the pill
/// names the correct word only, never the mishearing.
enum CorrectionLearnedPillCopy {
  /// Plan §3.1 step 9: the Undo window. Hover does not pause it.
  static let learnedDwellSeconds = 3.0
  /// `Undone` shows for this long, without a button.
  static let undoneDwellSeconds = 1.5
  /// `Couldn’t undo` and `Couldn’t save “…”` show for this long.
  static let errorDwellSeconds = 3.0
  /// The sentence shrinks to half its size before SwiftUI truncates a very
  /// long word (the #3089 long-word rule). The cap gives the measured pill a
  /// finite width to shrink INTO: without one the host measures the ideal
  /// width, the scale never engages, and a 512-scalar word would push the
  /// Undo button off the screen (final review 2026-09-22). 400 is the old
  /// card's Live Preview width.
  static let minimumScale = 0.5
  static let maximumSentenceWidth: CGFloat = 400

  // #3142: every sentence below is localized WHOLE, quotes included, so a
  // translator can move the word and use their own quotation marks. The word
  // itself is the user's, inserted verbatim.
  static let undo = String(
    localized: "Undo",
    comment: "Button on the pill shown after a word is added to the dictionary. Removes it again.")
  static let undone = String(
    localized: "Undone",
    comment: "Pill result after the user pressed Undo: the word was removed again.")
  static let couldNotUndo = String(
    localized: "Couldn\u{2019}t undo",
    comment: "Pill result when removing the just-added word failed.")

  /// The one line the `.learned` phase draws.
  static func sentence(for model: LearnedCorrectionPillModel) -> String {
    switch model.kind {
    case .added:
      return String(
        localized: "Added \u{201C}\(model.canonical)\u{201D} to Dictionary",
        comment: "Pill after a correction taught the app a new word. %@ is that word.")
    case .updated:
      return String(
        localized: "\u{201C}\(model.canonical)\u{201D} updated",
        comment:
          "Pill after a correction changed a word already in the dictionary. %@ is that word.")
    }
  }

  /// What the pill draws in each phase, and whether it offers Undo.
  static func line(for model: LearnedCorrectionPillModel) -> (
    text: String, showsUndo: Bool, isError: Bool
  ) {
    switch model.phase {
    case .learned: return (sentence(for: model), true, false)
    case .undone: return (undone, false, false)
    case .undoError: return (couldNotUndo, false, true)
    }
  }

  static func saveError(_ error: LearnedCorrectionSaveError) -> String {
    String(
      localized: "Couldn\u{2019}t save \u{201C}\(error.canonical)\u{201D}",
      comment: "Pill when a word could not be saved to the dictionary. %@ is that word.")
  }

  /// VoiceOver: the sentence, then that Undo is available (the button is a
  /// separate element, so the offer is audible before it is reached).
  static func announcement(for model: LearnedCorrectionPillModel) -> String {
    let line = line(for: model)
    guard line.showsUndo else { return line.text }
    return String(
      localized: "\(line.text). Undo available.",
      comment:
        "VoiceOver reading of the pill: %@ is the pill's sentence, then the Undo button is announced."
    )
  }
}

/// The three-second pill: one sentence and a bordered Undo button, drawn in the
/// overlay's capsule. No timer, no hover logic, no focus: the director owns
/// expiry, the reducer owns the phase, and the panel never activates.
struct CorrectionLearnedPillView: View {
  let model: LearnedCorrectionPillModel
  let onUndo: () -> Void

  var body: some View {
    let line = CorrectionLearnedPillCopy.line(for: model)
    HStack(spacing: 10) {
      Text(line.text)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(line.isError ? Color.red.opacity(0.9) : .white)
        .lineLimit(1)
        .minimumScaleFactor(CorrectionLearnedPillCopy.minimumScale)
        .frame(maxWidth: CorrectionLearnedPillCopy.maximumSentenceWidth)
        .accessibilityLabel(CorrectionLearnedPillCopy.announcement(for: model))
      if line.showsUndo {
        Button(action: onUndo) {
          Text(CorrectionLearnedPillCopy.undo)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .contentShape(Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.55), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(CorrectionLearnedPillCopy.undo)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(OverlayCapsuleBackground())
  }
}

/// `Couldn’t save “<word>”`: the same capsule, one red line, no button.
struct CorrectionLearnedSaveErrorView: View {
  let error: LearnedCorrectionSaveError

  var body: some View {
    Text(CorrectionLearnedPillCopy.saveError(error))
      .font(.system(size: 13, weight: .medium))
      .foregroundStyle(Color.red.opacity(0.9))
      .lineLimit(1)
      .minimumScaleFactor(CorrectionLearnedPillCopy.minimumScale)
      .frame(maxWidth: CorrectionLearnedPillCopy.maximumSentenceWidth)
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .background(OverlayCapsuleBackground())
  }
}
