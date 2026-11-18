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
    comment:
      "Pill result after the user pressed Undo on a word that was updated: the earlier entry is back."
  )
  static let couldNotUndo = String(
    localized: "Couldn\u{2019}t undo",
    comment: "Pill result when removing the just-added word failed.")
  static let subtitleAdded = String(
    localized: "Added to dictionary",
    comment:
      "Small line under the word on the pill shown after a correction taught the app a new word.")
  static let subtitleUpdated = String(
    localized: "Updated in dictionary",
    comment:
      "Small line under the word on the pill shown after a correction changed a word already in the dictionary."
  )

  /// What the pill draws, and which controls it offers, in each phase. A value rather than a
  /// view so a test can hand the face a pseudo-translation and read what each phase shows.
  struct Line: Equatable {
    /// The controls on the card. `.live` is the unanswered offer: Undo and × press. `.reserved`
    /// is the offer after Undo was accepted: the card keeps its size and both stay invisible and
    /// unclickable until the result. `.none` is a result, which has nothing left to act on.
    enum Controls: Equatable {
      case live
      case reserved
      case none
    }
    /// The large first line: the word, or a result.
    let title: String
    /// The small second line under the word; nil on a result.
    let subtitle: String?
    let controls: Controls
    /// Draws the title in the error color: only `Couldn’t undo`.
    let isError: Bool
    let undoLabel: String
    /// VoiceOver label of ×. Names the word it keeps.
    let closeLabel: String
    /// What VoiceOver reads for the text of the card.
    let announcement: String
    /// Whether the countdown line draws: only while Undo can still be pressed.
    var showsCountdown: Bool { controls == .live }
  }

  static func subtitle(for kind: LearnedCorrectionPillModel.Kind) -> String {
    switch kind {
    case .added: return subtitleAdded
    case .updated: return subtitleUpdated
    }
  }

  /// What Undo of this word shows once it worked: an added word was removed, an updated word
  /// restored the earlier entry, so only the first can say "removed".
  static func undoneTitle(for model: LearnedCorrectionPillModel) -> String {
    switch model.kind {
    case .added:
      return String(
        localized: "\u{201C}\(model.canonical)\u{201D} removed",
        comment:
          "Pill result after the user pressed Undo on a word that was just added to the dictionary. %@ is that word."
      )
    case .updated: return undone
    }
  }

  static func closeLabel(for model: LearnedCorrectionPillModel) -> String {
    String(
      localized: "Close and keep \u{201C}\(model.canonical)\u{201D}",
      comment:
        "VoiceOver label of the × button on the pill shown after a word was saved to the dictionary: closes the pill and keeps the word. %@ is that word."
    )
  }

  static func line(for model: LearnedCorrectionPillModel) -> Line {
    let subtitle = subtitle(for: model.kind)
    let close = closeLabel(for: model)
    switch model.phase {
    case .learned:
      return Line(
        title: model.canonical, subtitle: subtitle, controls: .live, isError: false,
        undoLabel: undo, closeLabel: close,
        announcement: String(
          localized: "\(model.canonical), \(subtitle). Undo available.",
          comment:
            "VoiceOver reading of the pill: the first %@ is the saved word, the second the small line under it, then the Undo button is announced."
        ))
    // Undo accepted, write not finished: the same card, both controls out of play (#4675).
    case .undoPending:
      return Line(
        title: model.canonical, subtitle: subtitle, controls: .reserved, isError: false,
        undoLabel: undo, closeLabel: close, announcement: "\(model.canonical), \(subtitle)")
    case .undone:
      let title = undoneTitle(for: model)
      return Line(
        title: title, subtitle: nil, controls: .none, isError: false,
        undoLabel: undo, closeLabel: close, announcement: title)
    case .undoError:
      return Line(
        title: couldNotUndo, subtitle: nil, controls: .none, isError: true,
        undoLabel: undo, closeLabel: close, announcement: couldNotUndo)
    }
  }

  static func saveError(_ error: LearnedCorrectionSaveError) -> String {
    String(
      localized: "Couldn\u{2019}t save \u{201C}\(error.canonical)\u{201D}",
      comment: "Pill when a word could not be saved to the dictionary. %@ is that word.")
  }

  /// VoiceOver: what the card says, and for the offer that Undo is available (the buttons are
  /// separate elements, so the offer is audible before they are reached).
  static func announcement(for model: LearnedCorrectionPillModel) -> String {
    line(for: model).announcement
  }
}

// MARK: - Metrics

/// The learned-word pill's own geometry (#4675). The Escape Recovery pill keeps its own
/// (`EscapeRecoveryPillMetrics`); the two no longer match, with the founder's approval.
///
/// Layout is the approved mock's (round icon, word over a small line, filled Undo, quiet ×);
/// the sizes are chosen so the card is content-sized, never wider than its measured content, and
/// each control is a comfortable target.
enum LearnedPillMetrics {
  /// The round icon disc.
  static let discSize: CGFloat = 36
  static let discGlyphSize: CGFloat = 16
  /// The word, drawn semibold.
  static let wordSize: CGFloat = 15
  /// The small line under the word, drawn regular.
  static let subtitleSize: CGFloat = 12
  static let titleGap: CGFloat = 1
  /// The Undo word, drawn semibold. A FONT size, not the button height.
  static let undoSize: CGFloat = 13
  static let undoPaddingAcross: CGFloat = 14
  static let undoPaddingDown: CGFloat = 6
  /// The × button's round target and its glyph.
  static let closeSize: CGFloat = 28
  static let closeGlyphSize: CGFloat = 11
  /// Between the icon and the text.
  static let rowGap: CGFloat = 12
  /// Between Undo and ×.
  static let controlGap: CGFloat = 6
  /// Between the text and the controls.
  static let textToControlsGap: CGFloat = 16
  static let leadingPadding: CGFloat = 12
  static let trailingPadding: CGFloat = 10
  static let verticalPadding: CGFloat = 10
}

// MARK: - The face

/// The learned-word pill as it looks at ONE moment of the countdown: the card, drawn from a
/// `Line` and a rail `progress`, with no clock and no dwell. Split from the wrapper below, like
/// `EscapeRecoveryPillFace`, so a test, the atlas or the onboarding film can draw it at any
/// instant without waiting twelve seconds.
///
/// **One measured layout.** The card is content-sized; Undo and × are `fixedSize` and trail the
/// text, so a long translation widens the pill instead of clipping them, and their positions do
/// not change while the offer is unanswered (the text and the controls are the same for the whole
/// offer). The Pending card keeps the controls' room, invisible, so the card does not change size
/// when Undo is pressed; a result has no controls and the card fits its line.
struct CorrectionLearnedPillFace: View {
  let line: CorrectionLearnedPillCopy.Line
  /// How far the countdown line has travelled, 0 to 1.
  var progress: Double
  var palette: PillPalette
  var showsBloom: Bool = true
  var onUndo: () -> Void = {}
  var onDismiss: () -> Void = {}

  /// Purely visual, so they live with the picture rather than the clock.
  @State private var isUndoHovered = false
  @State private var isCloseHovered = false

  var body: some View {
    HStack(spacing: LearnedPillMetrics.textToControlsGap) {
      HStack(spacing: LearnedPillMetrics.rowGap) {
        icon
        text
      }
      if line.controls != .none { controls }
    }
    .padding(.leading, LearnedPillMetrics.leadingPadding)
    .padding(.trailing, LearnedPillMetrics.trailingPadding)
    .padding(.vertical, LearnedPillMetrics.verticalPadding)
    .background(Capsule().fill(palette.fill))
    // Both overlays sit IN FRONT of the buttons and are pure decoration, so both opt out of hit
    // testing: a stroked shape is hit-testable by default and the rim's stroke region overlaps
    // where a click aimed at ×, near the end cap, lands. `SpectralRail` opts out inside itself.
    .overlay(Capsule().strokeBorder(palette.rim, lineWidth: 1).allowsHitTesting(false))
    .overlay {
      if line.showsCountdown {
        SpectralRail(progress: progress, palette: palette, showsBloom: showsBloom)
          .padding(PillMetrics.railInset)
      }
    }
  }

  private var icon: some View {
    Image(systemName: "character.book.closed")
      .font(.system(size: LearnedPillMetrics.discGlyphSize, weight: .medium))
      .foregroundStyle(palette.accent)
      .frame(width: LearnedPillMetrics.discSize, height: LearnedPillMetrics.discSize)
      .background(Circle().fill(palette.accentWash))
      .accessibilityHidden(true)
  }

  /// The word, one line: it shrinks to half size, then truncates at its tail, inside the 400-point
  /// cap that gives the measured pill a finite width to shrink into (#3089). The small line is one
  /// line too and is NOT capped: a long translation widens the pill rather than clipping.
  private var text: some View {
    VStack(alignment: .leading, spacing: LearnedPillMetrics.titleGap) {
      Text(line.title)
        .font(.system(size: LearnedPillMetrics.wordSize, weight: .semibold))
        .foregroundStyle(line.isError ? Color.stError : palette.text)
        .lineLimit(1)
        .truncationMode(.tail)
        .minimumScaleFactor(CorrectionLearnedPillCopy.minimumScale)
        .frame(maxWidth: CorrectionLearnedPillCopy.maximumSentenceWidth, alignment: .leading)
      if let subtitle = line.subtitle {
        Text(subtitle)
          .font(.system(size: LearnedPillMetrics.subtitleSize, weight: .regular))
          .foregroundStyle(palette.secondaryText)
          .lineLimit(1)
          .truncationMode(.tail)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(line.announcement)
  }

  /// Undo and ×, laid out for the offer and for Pending alike so the card never changes size
  /// between them; Pending only hides them (a hidden view takes no hit and no VoiceOver focus).
  @ViewBuilder
  private var controls: some View {
    let live = line.controls == .live
    HStack(spacing: LearnedPillMetrics.controlGap) {
      undoButton
      closeButton
    }
    .fixedSize()
    .opacity(live ? 1 : 0)
    .allowsHitTesting(live)
    .accessibilityHidden(!live)
  }

  private var undoButton: some View {
    Button(action: onUndo) {
      Text(line.undoLabel)
        .font(.system(size: LearnedPillMetrics.undoSize, weight: .semibold))
        .foregroundStyle(palette.accent)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, LearnedPillMetrics.undoPaddingAcross)
        .padding(.vertical, LearnedPillMetrics.undoPaddingDown)
        .background(
          RoundedRectangle(cornerRadius: PillMetrics.actionRadius, style: .continuous)
            .fill(palette.accentWash)
        )
        .overlay(
          RoundedRectangle(cornerRadius: PillMetrics.actionRadius, style: .continuous)
            .fill(isUndoHovered ? palette.accentWash : .clear)
            .allowsHitTesting(false)
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(line.undoLabel)
    .onHover { isUndoHovered = $0 }
  }

  private var closeButton: some View {
    Button(action: onDismiss) {
      Image(systemName: "xmark")
        .font(.system(size: LearnedPillMetrics.closeGlyphSize, weight: .semibold))
        .foregroundStyle(palette.secondaryText)
        .frame(width: LearnedPillMetrics.closeSize, height: LearnedPillMetrics.closeSize)
        .background(Circle().fill(isCloseHovered ? palette.quietHover : .clear))
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(line.closeLabel)
    .onHover { isCloseHovered = $0 }
  }
}

// MARK: - The wrapper

/// The twelve-second pill: the face, plus the drawing of the published dwell. **This view owns
/// no clock, same contract as `EscapeRecoveryPillView`.** `PillCatalog` arms the real dismissal
/// at `CorrectionLearnedPillCopy.learnedDwellSeconds`, `PillExpiryClock` is the sole thing that
/// dismisses and freezes and resumes the countdown on hover, and this view only draws the
/// REMAINDER of that dwell, as a share of the original total, as a filling rail (founder
/// 2026-09-27, ENVIOUSWISPR-5E: the Undo window closed with nothing on screen to say it was
/// running out). The rail draws only while Undo can still be pressed.
struct CorrectionLearnedPillView: View {
  let model: LearnedCorrectionPillModel
  let onUndo: () -> Void
  let onDismiss: () -> Void
  /// The director's dwell, matched to this presentation. `nil` until it lands
  /// (`OverlayRootView` passes `frame.dwell` straight through, the same
  /// signal `EscapeRecoveryPillView` reads).
  let dwell: OverlayDwellWindow?

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// **The rail is drawn, not animated.** Every frame reads the share from the published dwell
  /// at that frame's instant. A `@State` progress driven by `withAnimation` cannot do this: SwiftUI
  /// animations are additive, so the in-flight fill keeps its residual after a hover freezes
  /// the value, and the line drew near empty and climbed back. A paused window is a still
  /// picture (the schedule stops and the share ignores the date); a resume that adds time moves
  /// the line back by construction.
  var body: some View {
    TimelineView(.animation(minimumInterval: nil, paused: dwell?.isPaused ?? true)) { context in
      CorrectionLearnedPillFace(
        line: CorrectionLearnedPillCopy.line(for: model),
        progress: Self.railProgress(for: dwell, at: context.date),
        palette: PillPalette.forScheme(colorScheme),
        showsBloom: RailMotion.showsBloom(reduceMotion: reduceMotion),
        onUndo: onUndo,
        onDismiss: onDismiss
      )
    }
  }

  /// The share of the original dwell that has run by `now`: a paused window is its frozen share
  /// whatever the instant, a running one grows with time, a window past its end is full, and no
  /// window yet is empty. Pure, so a test can read each case.
  static func railProgress(for dwell: OverlayDwellWindow?, at now: Date) -> Double {
    dwell?.elapsedFraction(at: now) ?? 0
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
