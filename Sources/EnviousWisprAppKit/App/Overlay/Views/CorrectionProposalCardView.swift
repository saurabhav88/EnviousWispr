import AppKit
import SwiftUI

// MARK: - Correction proposal card (#996 §3.1 step 9)

/// Every string the card and its announcement show. The overlay owns the copy;
/// the coordinator hands over a typed `CorrectionCardState` and a typed
/// `CorrectionCardResult` and never a sentence, so the wire vocabulary and the
/// words on screen cannot drift apart in two places.
///
/// The wording is the founder's mock of 19 Sep 2026 (plan §16), chosen over the
/// earlier plan text on 20 Sep: the state line has a plain lead and an
/// emphasised outcome, and the result is one sentence behind a mark.
enum CorrectionProposalCardCopy {
  /// The two words shrink down to this fraction of 26 pt, about 13 pt and
  /// close to the state line's size, before SwiftUI truncates an even longer term.
  static let wordMinimumScale = 0.5
  static let misheardLabel = "MISHEARING"
  static let correctLabel = "CORRECT WORD"
  static let reject = "Reject"
  static let accept = "Accept"

  /// "Already in your words · adds the mishearing to it" /
  /// "New word · saved with its first mishearing", as lead and emphasis.
  static func stateLine(for state: CorrectionCardState) -> (lead: String, emphasis: String) {
    switch state {
    case .existingWord: return ("Already in your words", "adds the mishearing to it")
    case .newWord: return ("New word", "saved with its first mishearing")
    }
  }

  enum ResultTone: Equatable {
    case ok
    case dim
    case error
  }

  /// The mark and sentence the result phase draws. Saved reads differently for
  /// the two states because the two writes differ: a sound-alike joined a word
  /// the user already had, or a new word now exists.
  static func result(_ result: CorrectionCardResult, for model: CorrectionProposalCardModel)
    -> (mark: String, text: String, tone: ResultTone)
  {
    let heard = "\u{201C}\(model.original)\u{201D}"
    switch result {
    case .saved:
      switch model.state {
      case .existingWord(let name):
        return ("\u{2713}", "\(heard) added to \(name).", .ok)
      case .newWord:
        return ("\u{2713}", "\(model.corrected) saved. \(heard) now becomes \(model.corrected).", .ok)
      }
    case .alreadyInYourWords:
      return ("\u{2713}", "Already in your words. \(heard) becomes \(model.corrected).", .ok)
    case .wontAskAgain:
      return ("\u{2013}", "Dismissed. We won\u{2019}t ask about this pair again.", .dim)
    case .couldNotSave:
      return ("!", "Couldn\u{2019}t save. Try again in Pending.", .error)
    case .savedButNotRecorded:
      return ("!", "Saved, but couldn\u{2019}t record it. Check Pending.", .error)
    }
  }

  /// The catalog's direct VoiceOver sentence for the offer; the result phase
  /// is spoken from the card's own accessibility label as it morphs.
  static func announcement(for model: CorrectionProposalCardModel) -> String {
    switch model.phase {
    case .offer:
      let line = stateLine(for: model.state)
      return
        "Learn a word? \(model.original) was corrected to \(model.corrected). "
        + "\(line.lead), \(line.emphasis). Press Accept or Reject."
    case .result(let result):
      return Self.result(result, for: model).text
    }
  }
}

/// The mock's palette, fixed and dark like the other capsule pills: the card
/// floats over the user's document and does not follow the app appearance.
private enum CorrectionCardPalette {
  static let surface = Color(red: 22 / 255, green: 18 / 255, blue: 34 / 255).opacity(0.96)
  static let line = Color.white.opacity(0.10)
  static let ink = Color(red: 244 / 255, green: 241 / 255, blue: 251 / 255)
  static let dim = Color(red: 169 / 255, green: 162 / 255, blue: 189 / 255)
  static let label = Color(red: 164 / 255, green: 140 / 255, blue: 240 / 255)
  static let control = Color.white.opacity(0.10)
  static let primary = Color(red: 124 / 255, green: 58 / 255, blue: 237 / 255)
  static let ok = Color(red: 121 / 255, green: 218 / 255, blue: 176 / 255)
  static let error = Color(red: 255 / 255, green: 172 / 255, blue: 182 / 255)
  static let track = Color.white.opacity(0.12)
  static let trackFill = Color.white.opacity(0.6)
  static let cornerRadius: CGFloat = 22
}

/// The card. Two phases, one identity: the offer draws the pair with Reject and
/// Accept over a thin dwell bar; the result draws one sentence behind a mark.
/// It owns no clock, no hover policy and no lifecycle reason: the director arms
/// the dwell, `OverlayRootView` forwards hover so the reducer can cancel and
/// re-arm, and the reducer decides what expiry and displacement mean.
/// This view renders, draws the director's dwell, and reports presses.
///
/// Never takes keyboard focus: the overlay panel is non-activating, so the
/// card is answered with the mouse (Accept, Reject) or not at all, and an
/// unanswered card slides into Pending on its dwell. No key reaches it while
/// the user's app owns the keyboard, and none is meant to: Live UAT
/// 2026-09-20 proved a click inside the card leaves the document frontmost,
/// so an Escape path here was dead code. Wispr Flow's learned-word toast has
/// the same hands-off shape (a clickable Undo, no keyboard dismiss).
struct CorrectionProposalCardView: View {
  let model: CorrectionProposalCardModel
  /// The director's dwell, matched to this presentation (`PillRenderState.dwell`).
  /// `nil` until the presentation lands; the bar waits for it, the way
  /// `EscapeRecoveryPillView` does, so it never runs ahead of the real clock.
  let dwell: OverlayDwellWindow?
  let onAccept: () -> Void
  let onReject: () -> Void

  /// How far the dwell bar has travelled, 0 to 1. A picture of the director's
  /// clock, never a clock of its own.
  @State private var progress: Double = 0

  var body: some View {
    Group {
      switch model.phase {
      case .offer: offer
      case .result(let result): resultRow(result)
      }
    }
    .frame(width: 440, alignment: .leading)
    .background(CorrectionCardBackground())
    .accessibilityElement(children: .contain)
    .accessibilityLabel(CorrectionProposalCardCopy.announcement(for: model))
  }

  private var offer: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        label(CorrectionProposalCardCopy.misheardLabel)
          .frame(maxWidth: .infinity, alignment: .leading)
        label(CorrectionProposalCardCopy.correctLabel)
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
      // `lastTextBaseline`: the arrow sits between the two WORDS, on their
      // baseline, with the heard form on the left and the correct word on the
      // right exactly as the labels above them. Each word stays on ONE line
      // and shrinks to fit rather than wrapping: a wrapped term broke inside
      // the word ("EnviousStagin / g", founder UAT 2026-09-21), which reads as
      // two different words on a card whose whole point is one word.
      HStack(alignment: .lastTextBaseline, spacing: 12) {
        Text(model.original)
          .font(.system(size: 26, weight: .regular))
          .tracking(-0.5)
          .foregroundStyle(CorrectionCardPalette.dim)
          .lineLimit(1)
          .minimumScaleFactor(CorrectionProposalCardCopy.wordMinimumScale)
          .frame(maxWidth: .infinity, alignment: .leading)
        Text("\u{2192}")
          .font(.system(size: 22))
          .foregroundStyle(CorrectionCardPalette.dim)
          .accessibilityHidden(true)
        Text(model.corrected)
          .font(.system(size: 26, weight: .semibold))
          .tracking(-0.5)
          .foregroundStyle(CorrectionCardPalette.ink)
          .lineLimit(1)
          .minimumScaleFactor(CorrectionProposalCardCopy.wordMinimumScale)
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
      stateLine
        .padding(.top, -6)
      Rectangle().fill(CorrectionCardPalette.line).frame(height: 1)
      HStack(spacing: 10) {
        Spacer(minLength: 0)
        button(CorrectionProposalCardCopy.reject, fill: CorrectionCardPalette.control, action: onReject)
          .accessibilityLabel("Reject: don't learn \(model.corrected)")
        button(CorrectionProposalCardCopy.accept, fill: CorrectionCardPalette.primary, action: onAccept)
          .accessibilityLabel("Accept: learn \(model.corrected)")
      }
      dwellBar
    }
    .padding(.top, 24)
    .padding(.horizontal, 26)
    .padding(.bottom, 22)
    .onHover { isHovering in
      // Hover HOLDS the offer and hover-exit re-arms the full eight seconds
      // (the reducer's `pausesOnHover` rule), so the bar returns to empty
      // instantly rather than freezing part-way, which would promise a resume
      // that never comes. Same shape and same reason as the Escape pill's rail.
      if isHovering { resetBar() } else { scheduleBar() }
    }
    // Both forms: the dwell may already be set when this view is built (a
    // later presentation) or arrive after (the deferred first one).
    .onAppear { if dwell != nil { scheduleBar() } }
    .onChange(of: dwell) { _, window in
      // A dwell withdrawn (hover cancelled it; the director will re-arm on
      // exit) empties the bar; a new window draws its remainder.
      if window != nil { scheduleBar() } else { resetBar() }
    }
  }

  private var stateLine: some View {
    let line = CorrectionProposalCardCopy.stateLine(for: model.state)
    return (Text("\(line.lead) \u{00B7} ")
      .foregroundColor(CorrectionCardPalette.dim)
      + Text(line.emphasis)
      .fontWeight(.semibold)
      .foregroundColor(CorrectionCardPalette.ink))
      .font(.system(size: 12.5))
      .lineLimit(1)
      .frame(maxWidth: .infinity, alignment: .trailing)
  }

  private var dwellBar: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule().fill(CorrectionCardPalette.track)
        Capsule().fill(CorrectionCardPalette.trackFill)
          .frame(width: proxy.size.width * progress)
      }
    }
    .frame(height: 2)
    .accessibilityHidden(true)
  }

  private func resultRow(_ result: CorrectionCardResult) -> some View {
    let drawn = CorrectionProposalCardCopy.result(result, for: model)
    let tone: Color =
      switch drawn.tone {
      case .ok: CorrectionCardPalette.ok
      case .dim: CorrectionCardPalette.dim
      case .error: CorrectionCardPalette.error
      }
    return HStack(alignment: .center, spacing: 12) {
      Text(drawn.mark)
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(tone)
        .frame(width: 22)
        .accessibilityHidden(true)
      Text(drawn.text)
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(CorrectionCardPalette.ink)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.updatesFrequently)
      Spacer(minLength: 0)
    }
    .padding(.vertical, 18)
    .padding(.horizontal, 22)
  }

  private func label(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 11, weight: .semibold))
      .tracking(1.3)
      .foregroundStyle(CorrectionCardPalette.label)
  }

  private func button(_ title: String, fill: Color, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(CorrectionCardPalette.ink)
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(fill))
    }
    .buttonStyle(.plain)
  }

  /// Empty the bar with no animation of its own, so whatever runs next starts
  /// from a known value rather than from wherever an interrupted animation was.
  private func resetBar() {
    var instant = Transaction()
    instant.disablesAnimations = true
    withTransaction(instant) { progress = 0 }
  }

  /// Draw the REMAINDER of the director's dwell, not a fresh eight seconds: the
  /// timer is already running when the window arrives, and a bar started from
  /// empty would finish after the card is gone. With no dwell there is nothing
  /// to draw and the bar stays empty (review r3: a nil dwell used to read as
  /// `remaining = 0` and drew a COMPLETED countdown for a card the director had
  /// not armed yet).
  private func scheduleBar() {
    guard let plan = CorrectionCardDwellBar.plan(for: dwell, at: Date()) else {
      resetBar()
      return
    }
    var instant = Transaction()
    instant.disablesAnimations = true
    withTransaction(instant) { progress = plan.start }
    guard plan.remaining > 0 else {
      withTransaction(instant) { progress = 1 }
      return
    }
    withAnimation(.linear(duration: plan.remaining)) { progress = 1 }
  }
}

/// The bar's arithmetic, kept out of the view so it can be asserted directly:
/// SwiftUI state cannot be read from a test, and the three cases that matter
/// (no dwell, a running dwell, an exhausted dwell) are decisions, not pixels.
enum CorrectionCardDwellBar {
  struct Plan: Equatable {
    /// Where the bar starts, 0 to 1: the fraction already elapsed.
    let start: Double
    /// Seconds left to animate to full; zero means draw it full at once.
    let remaining: Double
  }

  /// `nil` when there is no dwell to draw: the bar stays empty.
  static func plan(for dwell: OverlayDwellWindow?, at now: Date) -> Plan? {
    guard let dwell else { return nil }
    return Plan(start: dwell.elapsedFraction(at: now), remaining: dwell.remaining(at: now))
  }
}

/// The mock's rounded panel with the brand hairline along its foot: the same
/// nine colours `OverlayCapsuleBackground.rainbowColors` draws under every
/// other pill, faded out at both ends and inset from the corners.
private struct CorrectionCardBackground: View {
  var body: some View {
    let shape = RoundedRectangle(cornerRadius: CorrectionCardPalette.cornerRadius, style: .continuous)
    shape
      .fill(CorrectionCardPalette.surface)
      .overlay(shape.strokeBorder(CorrectionCardPalette.line, lineWidth: 1))
      .overlay(alignment: .bottom) {
        LinearGradient(
          colors: [.clear] + OverlayCapsuleBackground.rainbowColors + [.clear],
          startPoint: .leading, endPoint: .trailing
        )
        .frame(height: 1)
        .padding(.horizontal, 22)
        .opacity(0.45)
      }
      .clipShape(shape)
      .shadow(color: .black.opacity(0.4), radius: 22, y: 18)
  }
}
