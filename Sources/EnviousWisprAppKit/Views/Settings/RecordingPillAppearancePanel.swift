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
      // **The two groups always STACK, and each one reflows its own tiles.**
      //
      // A `ViewThatFits` chose the groups' side-by-side arrangement here and was
      // REMOVED after rendering it: nested inside the page's vertical
      // `ScrollView` it does not reliably receive a bounded horizontal proposal,
      // so it cannot judge whether a candidate fits and keeps its first one. At a
      // 530 point content width that clipped both wordless pills; at 1010 it
      // stacked two groups with room to sit side by side. A container that
      // guesses wrong CLIPS here rather than cramping, because every pill is a
      // fixed width by design.
      //
      // `LazyVGrid` is the container this page already proves receives a bounded
      // width — the theme cards above use one — so the reflow is decided by
      // arithmetic rather than by a proposal that may not arrive.
      VStack(alignment: .leading, spacing: 18) {
        group(holdingWords: false)
        group(holdingWords: true)
      }
      // **The page REFUSES to be narrower than its widest pill, rather than
      // clipping one.** Rendered at a 380 point content width the reading well
      // was cut off: a grid column cannot shrink below its content, and the tile
      // clips its own, so there is no width at which a too-narrow layout degrades
      // gracefully. A minimum propagates up to the window, so the window stops
      // resizing instead — which is the honest behaviour for a page whose whole
      // subject is fixed-size pictures.
      //
      // DERIVED, never a literal: a design added later widens it with no edit
      // here, and a literal would be a second authority for a number the tile
      // already owns.
      .frame(minWidth: Self.widestTile(holdingWords: true), alignment: .leading)
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

  /// The widest tile a group will contain, which is what its grid column has to
  /// be able to hold.
  ///
  /// Read off `PillCatalog` and the tile, so a design added later widens the
  /// column with no edit here.
  static func widestTile(holdingWords: Bool) -> CGFloat {
    PillCatalog.designs(holdingWords: holdingWords)
      .map(RecordingPillPreviewTile.width(for:))
      .max() ?? 0
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

      // **One column per tile that fits, sized by the WIDEST tile in this group.**
      // A narrower minimum would let a column form that the reading well cannot
      // sit in, and the tile clips its own content, so the pill would be cut
      // rather than cramped. Taken from the tile itself, never a literal here.
      LazyVGrid(
        columns: [
          GridItem(
            .adaptive(minimum: Self.widestTile(holdingWords: holdingWords), maximum: .infinity),
            spacing: 12)
        ],
        alignment: .leading,
        spacing: 12
      ) {
        tiles(holdingWords: holdingWords)
      }
    }
    // **NO `maxWidth: .infinity` HERE, and it stays absent deliberately.** It was
    // removed while this panel still chose its layout with `ViewThatFits`, which
    // asks each candidate for its IDEAL size: a greedy child answers that it will
    // take whatever it is given, so every candidate fit at every width and the
    // fallbacks were dead code. That container is gone, but a greedy group would
    // now stretch every column to the panel's full width instead, which is the
    // same wrong picture by another route.
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

  /// The pill's own inset inside the tile, on each side.
  static let horizontalInset: CGFloat = 16

  /// **What one tile occupies, derived rather than restated.** The panel's grid
  /// needs this to size a column that can hold the widest design; a literal there
  /// would be a second authority for the same number, free to disagree the day a
  /// design's width moves.
  static func width(for design: RecordingPillDesign) -> CGFloat {
    design.width + horizontalInset * 2
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

  /// Mid level, so the meter and the rainbow mark are visibly alive rather than
  /// sitting on the silence floor.
  static let sampleLevel: Float = 0.42

  /// A two digit clock, which is the widest ordinary case.
  static let sampleElapsed: TimeInterval = 12

  /// A plausible sentence's worth of level samples, oldest first (#2435).
  ///
  /// **A still pill has no history to build, so this IS the meter.** With one
  /// poll and nothing after it the rail would draw a single bar at the sample
  /// level and twenty-three at the silence floor — and the Level Rail's whole
  /// identity is that meter, so the picker would misrepresent the design it is
  /// asking the user to choose. Found by cloud review on #2439.
  ///
  /// **It is deliberately ONE SHORT of `RainbowLevelMeter.barCount`, and the
  /// coupling is the point rather than an accident.** `.still` polls once, that
  /// poll increments the tick, and the meter appends on a tick change — so a
  /// FULL seed would immediately drop its oldest sample and shift every bar,
  /// leaving the rendered meter one bar different from the array written here.
  /// Cloud review caught that as a consequence of the seed itself, on the round
  /// after the seed landed. Seeding one short lets the single poll COMPLETE the
  /// history instead: `pushed` drops only past capacity, so nothing shifts and
  /// the rail draws exactly this shape with `sampleLevel` newest.
  ///
  /// That also removes the need to end this array at `sampleLevel` by hand — the
  /// poll supplies it, from the same provider that drives the rainbow mark, so
  /// the newest bar and the mark cannot disagree.
  ///
  /// `internal`, like `sampleDisplay`, because "what the sample pill shows" has
  /// one owner and a test has to be able to read it.
  static let sampleLevelHistory: [CGFloat] = [
    0.06, 0.11, 0.24, 0.38, 0.52, 0.61, 0.55, 0.40,
    0.22, 0.13, 0.09, 0.18, 0.34, 0.49, 0.66, 0.73,
    0.64, 0.47, 0.29, 0.16, 0.10, 0.21, 0.35,
  ]

  var body: some View {
    Button(action: onSelect) {
      ZStack(alignment: .topTrailing) {
        RecordingPillPreview(design: design)
          .padding(.horizontal, Self.horizontalInset)
          .padding(.vertical, 16)
          // Height only, so tiles sharing a grid row are the same size. A greedy
          // WIDTH would make the tile report that it fits anywhere, which is what
          // stops any container above it from reflowing correctly.
          .frame(maxHeight: .infinity)

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

  ///
  var body: some View {
    let display = RecordingPillPreviewTile.sampleDisplay(for: design)
    RecordingOverlayView(
      audioLevelProvider: { RecordingPillPreviewTile.sampleLevel },
      recordingElapsedProvider: { RecordingPillPreviewTile.sampleElapsed },
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
      animatesGlow: false,
      // The meter is the Level Rail's whole identity, and a pill that never polls
      // has no history to build. See `sampleLevelHistory`.
      initialLevelHistory: RecordingPillPreviewTile.sampleLevelHistory,
      // **The last two of the poll's four pieces of state.** Without them the
      // first frame draws the rainbow mark at silence and a 0:00 clock, then
      // snaps to the sample once the single poll lands. The leaf's own doc
      // comment enumerates the set; the wiring guard reads the poll body and
      // requires a seed for each.
      initialAudioLevel: RecordingPillPreviewTile.sampleLevel,
      initialElapsed: RecordingPillPreviewTile.sampleElapsed
    )
    // **A PICTURE does not move, including on the way in.** The leaf animates
    // `audioLevel`, and its first poll moves that from 0 to the sample, so a tile
    // would fade its meter up every time the grid recreates a row or the settings
    // page rebuilds. Rejecting inherited animations is the only reach a caller
    // has: the `.animation` modifiers are inside the leaf.
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
