import EnviousWisprCore
import SwiftUI

/// Choose the recording pill's design, per capability group (#2376 Phase 4, C7;
/// redrawn as pictures in #2435).
///
/// **The picker SHOWS each design instead of describing it (#2435).** A user
/// could not previously see what any option looked like without starting a
/// recording and cancelling it. Every option is now the real pill, rendered by
/// the same view the overlay uses, and the words it used to print move into the
/// accessibility label — which is the only channel a macOS user cannot silence
/// (VoiceOver Utility can turn hints and custom content off).
///
/// **Two groups, and the one that does not apply is GREYED WITH ITS REASON
/// rather than hidden.** Hiding it would leave a user who turns Live Preview on
/// wondering where the other pills went, and would give no clue to a user whose
/// engine cannot run here that the switch is not the thing standing in their way.
///
/// **The groups and their offerability come from `PillCatalog`, never from this
/// view.** A design this page greys out is exactly a design the pill would
/// refuse, because `offers` is defined in terms of the same `resolve` the
/// director calls. A local `allCases.filter { $0.canHoldWords == x }` would be a
/// second derivation of that rule even on the day it agreed.
///
/// **The reason is stated ONCE, at group level.** Two precedents were considered
/// and both rejected: `EngineCard` puts a reason inside a card that stays
/// selectable, and `LivePreviewSettingsView` deliberately moved its reason OUT of
/// the disabled control onto another card, on the recorded grounds that two
/// places saying why is how they come to disagree. Here the requirement is the
/// reason WITH the greyed group, so it is rendered once in that group's header
/// and nowhere else.
///
/// **The two group titles name a CONDITION, not the current state, and that is
/// what makes them true** (founder, 2026-08-26). Read as a status claim,
/// "Live Preview on" would be false at `.engineUnsupported` and
/// `.modelBeingRemoved`, where the setting is on and the pills are still out of
/// reach. Read as "the pills you get when Live Preview is on", it holds in all
/// four cases. Two things carry the CURRENT state instead, and both are
/// requirements rather than decoration: exactly one group shows the filled active
/// dot, and the other one prints `reason(for:groupHoldsWords:)`, which already
/// distinguishes every case. `AppearancePillPickerTests` asserts both.
struct RecordingPillAppearancePanel: View {

  @Environment(PillAppearanceModel.self) private var model

  var body: some View {
    BrandedPanel(
      icon: "waveform.badge.mic",
      header: "Recording Pill"
    ) {
      // **`ViewThatFits` rather than a width breakpoint**, because the number
      // would have to be re-derived every time a design's width moved, and the
      // designs already declare their own widths. Side by side while both groups
      // fit; stacked otherwise, with every pill still drawn at TRUE SIZE. The
      // alternative measured badly: the settings window opens at 820 points wide,
      // where fitting both groups side by side needs a shared 0.47 scale factor
      // and the reading well's words become unreadable.
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: 12) {
          group(holdingWords: false)
          group(holdingWords: true)
        }
        VStack(alignment: .leading, spacing: 12) {
          group(holdingWords: false)
          group(holdingWords: true)
        }
      }
    } footnote: {
      // ONE quiet line for the whole page's pill settings (founder, 2026-08-26),
      // replacing the sentence this panel and the position panel each carried.
      //
      // **It NAMES both settings, because it sits inside the Recording Pill
      // panel** and an unqualified "Changes" reads there as design changes only,
      // leaving the position panel above silently uncovered.
      //
      // "the next time the pill appears", not "the next time you record": the
      // position setting also places status notices, which the deleted copy said
      // outright ("Changes apply the next time one appears"). A notice can arrive
      // without a recording, so scoping this line to recording would be wrong for
      // half of what it now covers.
      Text("Design and position changes apply the next time the pill appears.")
        .settingsReadingCopy()
    }
  }

  /// Whether a group describes the situation the user is actually in.
  ///
  /// **A function rather than a computed property inside `body`, because it is
  /// the authority the active dot and the reason line BOTH read**, and because
  /// the rendered accessibility tree is not readable from a test (recorded in
  /// `RenderedPillHarness`). A test can hold this to "exactly one group is
  /// active, in every capability state" without hosting anything.
  static func isActive(_ capability: PillWordsCapability, groupHoldsWords: Bool) -> Bool {
    groupHoldsWords == capability.hasWords
  }

  @ViewBuilder
  private func group(holdingWords: Bool) -> some View {
    let isActive = Self.isActive(model.wordsCapability, groupHoldsWords: holdingWords)
    let title = holdingWords ? "Live Preview on" : "Live Preview off"

    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 7) {
        // The dot is the CURRENT state; the title beside it is the condition.
        Circle()
          .fill(isActive ? Color.green : Color.clear)
          .overlay(
            Circle().strokeBorder(
              isActive ? Color.clear : Color.stTextTertiary, lineWidth: 1)
          )
          .frame(width: 8, height: 8)
          // Announced through the title's own label instead, so a screen reader
          // hears one phrase rather than an unnamed shape beside a heading.
          .accessibilityHidden(true)

        Text(title)
          .font(.stRowTitle)
          .foregroundStyle(isActive ? .stTextPrimary : .stTextSecondary)
          .accessibilityLabel(isActive ? "\(title). In use." : title)
      }

      // The reason, rendered ONLY on the inactive group and only once.
      if !isActive,
        let reason = Self.reason(for: model.wordsCapability, groupHoldsWords: holdingWords)
      {
        Text(reason)
          .settingsReadingCopy()
      }

      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: 12) { tiles(holdingWords: holdingWords) }
        VStack(alignment: .leading, spacing: 12) { tiles(holdingWords: holdingWords) }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    // One animation on the container, never per `ForEach` child.
    .animation(.easeInOut(duration: 0.15), value: isActive)
  }

  @ViewBuilder
  private func tiles(holdingWords: Bool) -> some View {
    let isActive = Self.isActive(model.wordsCapability, groupHoldsWords: holdingWords)
    ForEach(model.designs(holdingWords: holdingWords), id: \.self) { design in
      RecordingPillPreviewTile(
        design: design,
        isSelected: model.selection(holdingWords: holdingWords) == design,
        isEnabled: model.offers(design, holdingWords: holdingWords) && isActive,
        onSelect: { model.choose(design, holdingWords: holdingWords) })
    }
  }

  /// Why the inactive group is inactive, in that user's terms.
  ///
  /// **Two refusals, two sentences, and that is the whole reason the capability
  /// carries a reason at all.** One sentence for both would tell a user whose
  /// engine cannot run on this Mac to turn on a setting that would not help them.
  ///
  /// **Shortened to a phrase each (#2435)** — the page is now pictures, and a
  /// paragraph under a greyed group is the text this change exists to remove. Each
  /// phrase still names its own cause, which is the property that matters: it is
  /// the only surface that distinguishes `previewOff` from `engineUnsupported`
  /// from `modelBeingRemoved`.
  static func reason(for capability: PillWordsCapability, groupHoldsWords: Bool) -> String? {
    if groupHoldsWords {
      switch capability {
      case .available: return nil
      case .previewOff: return "Turn on Live Preview to use these."
      case .engineUnsupported: return "Your engine cannot show words on this Mac."
      case .modelBeingRemoved: return "Unavailable while a removed model finishes clearing."
      }
    }
    // The wordless group is inactive exactly when words ARE available.
    return capability.hasWords ? "Live Preview is on, so the pill shows your words." : nil
  }
}

// MARK: - One design, drawn

/// One selectable pill design, shown as the pill itself (#2435).
///
/// `internal` rather than `private` so its accessibility string has a name a test
/// can call. The rendered accessibility TREE is not readable from a hosted view
/// (measured, and recorded in `RenderedPillHarness`), so the label is proven
/// through the function that produces it and confirmed by a VoiceOver pass.
struct RecordingPillPreviewTile: View {
  let design: RecordingPillDesign
  let isSelected: Bool
  let isEnabled: Bool
  let onSelect: () -> Void

  /// **The name AND the description, both in the LABEL.** Once the tile carries
  /// no visible text the drawing IS the content, and WCAG 1.1.1 asks for a text
  /// alternative serving an EQUIVALENT purpose — a bare "Capsule" names the
  /// option and says nothing about the thing every sighted user can now see.
  ///
  /// **Not a hint, and not `accessibilityCustomContent`, and that is a standards
  /// answer rather than a preference.** VoiceOver Utility's Verbosity pane lets a
  /// user set hints and extra content to "Do Nothing", so both can be silenced by
  /// the reader. The label is the only channel guaranteed to be announced, so it
  /// is where a text alternative that must arrive has to live.
  ///
  /// The cost is a longer announcement on every focus, which is accepted: the
  /// summaries are one short sentence each, which bounds it.
  static func accessibilityLabel(for design: RecordingPillDesign) -> String {
    "\(design.displayName). \(design.summary)"
  }

  /// What the pill inside the tile is shown SAYING.
  ///
  /// **Keyed off `canHoldWords`, so the panel names no design.** A design added
  /// later gets the right sample with no edit here.
  ///
  /// `internal` because a size test has to drive the same input through an
  /// independent measurement of the leaf; using a different sentence there would
  /// compare two different pictures and call the difference a defect.
  static func sampleDisplay(for design: RecordingPillDesign) -> LivePreviewDisplay {
    design.canHoldWords ? .text("the quarterly numbers came in") : .off
  }

  var body: some View {
    Button(action: onSelect) {
      ZStack(alignment: .topTrailing) {
        RecordingPillPreview(design: design)
          .padding(.horizontal, 16)
          .padding(.vertical, 16)
          .frame(maxWidth: .infinity, maxHeight: .infinity)

        if isSelected {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Color.white, isEnabled ? Color.stAccent : Color.stTextSecondary)
            .padding(9)
        }
      }
      // Before `.buttonStyle(.plain)`, so the whole tile is the hit target rather
      // than the pill's own glyphs.
      .contentShape(Rectangle())
      .background(Color.stPageBg)
      .clipShape(RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius))
      .overlay(
        RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius)
          .strokeBorder(
            isSelected && isEnabled ? Color.stAccent : Color.stDivider,
            lineWidth: isSelected && isEnabled ? 2 : 1)
      )
    }
    .buttonStyle(.plain)
    .disabled(!isEnabled)
    .opacity(isEnabled ? 1 : 0.45)
    // **Addressed by role and title, never by an accessibility identifier**
    // (swift-patterns). A greyed tile must REPORT as disabled rather than merely
    // look it: the mistake `EngineCard` records for itself is a control that is
    // visible and inaudible.
    .accessibilityElement(children: .combine)
    .accessibilityLabel(Self.accessibilityLabel(for: design))
    .accessibilityValue(isSelected ? "Selected" : "")
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
  }
}

/// The real recording pill, standing still (#2435).
///
/// **`RecordingOverlayView`, never a drawing of it.** `RecordingPillChrome`
/// exists so ONE table describes each design; a second renderer in Settings would
/// disagree with the overlay the first time a design changed, and would disagree
/// silently, because nothing compares a settings picture to a running pill.
///
/// **The sample state is FIXED and stated, because an unspecified sample is an
/// unspecified picture.** Lock state and preview state both change the pixels, so
/// leaving either to chance would make the tile a picture of some pill rather
/// than of this design.
private struct RecordingPillPreview: View {
  let design: RecordingPillDesign

  /// Mid level, so the meter and the rainbow mark are visibly alive rather than
  /// sitting on the silence floor.
  private static let sampleLevel: Float = 0.42

  /// A two digit clock, which is the widest ordinary case.
  private static let sampleElapsed: TimeInterval = 12

  var body: some View {
    let display = RecordingPillPreviewTile.sampleDisplay(for: design)
    RecordingOverlayView(
      audioLevelProvider: { Self.sampleLevel },
      recordingElapsedProvider: { Self.sampleElapsed },
      livePreviewProvider: { display },
      onContentHeightChange: { _ in },
      chrome: design.chrome,
      // Hands free is not what is being chosen here, and the locked variants
      // differ per design, so a picker showing ONE mode is the honest one.
      isLocked: false,
      // #1060's banner is a runtime event, not an appearance.
      noticeText: nil,
      // **Seeded, or the reading well renders empty on its first frame and
      // visibly fills in.** `preview` is `@State`, so this parameter is the only
      // way to make the first frame the right one.
      initialPreview: display,
      // One read to synchronise, then nothing. Three live pills on a settings
      // page would read their providers sixty times a second between them.
      cadence: .still,
      // A settings page is not the place for a permanent two second pulse, and
      // there would be one per capsule tile.
      animatesGlow: false
    )
    // **A PICTURE does not move, including on the way in.** The leaf animates
    // `audioLevel`, and its first poll moves that from 0 to the sample, so a tile
    // would fade its meter up every time `ViewThatFits` changes candidates or the
    // settings page recreates it. Rejecting inherited animations is the only
    // reach a caller has: the `.animation` modifiers are inside the leaf.
    .transaction { transaction in
      transaction.disablesAnimations = true
    }
    // **The design's OWN declared width, uniformly — no per design table here.**
    // It is the interaction window rather than the pill: `OverlayRootView`
    // applies it outside the leaf, so the capsule paints at its own content size
    // and centres inside. Passing it matters for the reading well, whose text
    // wraps to the width it is given; for the other two it reserves transparent
    // space either side and changes no pixel of the pill.
    .frame(width: design.width)
  }
}
