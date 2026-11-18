import AppKit
import SwiftUI

// MARK: - Auto-learn Undo pill (#996, 2026-09-21 plan §3.1 step 9)

/// Every string the Undo pill, its results and its announcements show. The
/// overlay owns the copy; the coordinator hands over a typed model and a typed
/// error and never a sentence. Wording is the founder's (2026-09-21): the pill
/// names the correct word only, never the mishearing.
enum CorrectionLearnedPillCopy {
  /// Plan §3.1 step 9: the Undo window. Widened from 3.0 to 4.0 (founder
  /// 2026-09-27, ENVIOUSWISPR-5E) when the pill gained a countdown rail, then
  /// to 12.0 (founder 2026-11-17/18, #4675), with hover pausing it.
  static let learnedDwellSeconds = 12.0
  /// A hover that ends with less than this left resumes with this much, so a
  /// person who reached for Undo at the last moment still has time to press it.
  static let hoverResumeFloorSeconds = 2.0
  /// `Undone` shows for this long, without a button.
  static let undoneDwellSeconds = 1.5
  /// `Couldn’t undo` and `Couldn’t save “…”` show for this long.
  static let errorDwellSeconds = 3.0
  /// The least time a pill that has accepted Undo stays up, so an Undo pressed in the last
  /// seconds still shows its result. A display policy: how long the write takes is not known
  /// (it can wait behind another dictionary command).
  static let undoPendingMinimumSeconds = 3.0
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
    // Undo accepted, write not finished: the same card, no button (#4675).
    case .undoPending: return (sentence(for: model), false, false)
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

/// The twelve-second pill: one sentence and a bordered Undo button, drawn in the
/// overlay's capsule. **This view owns no clock, same contract as
/// `EscapeRecoveryPillView`.** `PillCatalog` arms the real dismissal at
/// `CorrectionLearnedPillCopy.learnedDwellSeconds`, `PillExpiryClock` is the
/// sole thing that dismisses and freezes and resumes the countdown on hover, and
/// this view only draws the REMAINDER of that dwell, as a share of the original
/// total, as a filling rail (founder 2026-09-27, ENVIOUSWISPR-5E: the Undo
/// window closed with nothing on screen to say it was running out). The rail
/// draws only while the Undo button itself shows — the `Undone` / `Couldn't
/// undo` results are short, buttonless morphs with nothing left to act on.
struct CorrectionLearnedPillView: View {
  let model: LearnedCorrectionPillModel
  let onUndo: () -> Void
  /// The director's dwell, matched to this presentation. `nil` until it lands
  /// (`OverlayRootView` passes `frame.dwell` straight through, the same
  /// signal `EscapeRecoveryPillView` reads).
  let dwell: OverlayDwellWindow?

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// How far the rail has travelled, 0 to 1. Driven by `dwell`, never by a
  /// clock of its own — see `EscapeRecoveryPillView.progress` for why.
  @State private var progress: Double = 0

  var body: some View {
    let line = CorrectionLearnedPillCopy.line(for: model)
    HStack(spacing: UndoPillMetrics.rowGap) {
      Text(line.text)
        .font(.system(size: UndoPillMetrics.sentenceSize, weight: .medium))
        .foregroundStyle(line.isError ? Color.red.opacity(0.9) : .white)
        .lineLimit(1)
        .minimumScaleFactor(CorrectionLearnedPillCopy.minimumScale)
        .frame(maxWidth: CorrectionLearnedPillCopy.maximumSentenceWidth)
        .accessibilityLabel(CorrectionLearnedPillCopy.announcement(for: model))
      if line.showsUndo {
        Button(action: onUndo) {
          Text(CorrectionLearnedPillCopy.undo)
            .font(.system(size: UndoPillMetrics.actionSize, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, UndoPillMetrics.actionPaddingAcross)
            .padding(.vertical, UndoPillMetrics.actionPaddingDown)
            .contentShape(Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.55), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(CorrectionLearnedPillCopy.undo)
      }
    }
    .padding(.horizontal, UndoPillMetrics.sidePadding)
    .padding(.vertical, UndoPillMetrics.verticalPadding)
    .background(OverlayCapsuleBackground())
    .overlay {
      if line.showsUndo {
        SpectralRail(
          progress: progress, palette: .dark,
          showsBloom: RailMotion.showsBloom(reduceMotion: reduceMotion)
        )
        .padding(1.5)
      }
    }
    .onAppear { followDwell() }
    .onChange(of: dwell) { _, _ in followDwell() }
  }

  /// Draw the rail for the dwell as it stands now: a running dwell animates the
  /// rest of the way, a paused one holds still.
  ///
  /// **Runs on every dwell change, not once per pill.** A hover freezes the
  /// countdown and leaving resumes it, possibly with MORE time than was left
  /// (the floor), so the rail must follow each published window. The view is
  /// rebuilt for a new presentation (`OverlayRootView` keys it by id), which is
  /// what ends one pill's rail before the next begins. The share drawn is the
  /// window's own remainder of the ORIGINAL total, so a resume that added time
  /// moves the line back, which is the truth.
  private func followDwell() {
    guard let dwell else { return }
    let now = Date()
    var instant = Transaction()
    instant.disablesAnimations = true
    withTransaction(instant) { progress = dwell.elapsedFraction(at: now) }
    guard !dwell.isPaused else { return }
    let remaining = dwell.remaining(at: now)
    guard remaining > 0 else {
      withTransaction(instant) { progress = 1 }
      return
    }
    withAnimation(.linear(duration: remaining)) { progress = 1 }
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
