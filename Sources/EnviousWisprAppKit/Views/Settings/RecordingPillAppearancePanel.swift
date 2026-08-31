import EnviousWisprCore
import SwiftUI

/// Choose the recording pill's design (#2376 Phase 4, C7; redrawn as pictures in
/// #2435; flattened to one row in #2446).
///
/// **The picker SHOWS each design instead of describing it (#2435).** A user
/// could not previously see what any option looked like without starting a
/// recording and cancelling it. Every option is now the real pill, rendered by
/// the same view the overlay uses, and the words it used to print move into the
/// accessibility label — which is the only channel a macOS user cannot silence
/// (VoiceOver Utility can turn hints and custom content off).
///
/// **ONE row of identical cards, shaped like the theme cards above them**
/// (founder, 2026-08-26, on seeing the alternative rendered). This REPLACES a
/// split into a "Live Preview off" group and a "Live Preview on" group, each
/// with its own heading, state dot and reason line. That split was accurate and
/// it was the wrong subject: a user opens this page to pick a PICTURE, and the
/// page opened by explaining a setting. The pill previews are now scaled to a
/// fixed thumbnail and paired with a name and a tick, which is the same control
/// the theme row already is.
///
/// **The constraint the split encoded has NOT gone away.** A design that shows
/// words is unusable when words are unavailable, and vice versa; that is carried
/// per card by `isEnabled` and by a single line under the row, instead of by two
/// headed groups. Two selections are still remembered behind the one visible
/// tick — see `selected(in:)`.
///
/// **Offerability comes from `PillCatalog`, never from this view.** A design this
/// page greys out is exactly a design the pill would refuse, because `offers` is
/// defined in terms of the same `resolve` the director calls. A local
/// `allCases.filter { $0.canHoldWords == x }` would be a second derivation of
/// that rule even on the day it agreed.
///
/// **The reason is stated ONCE, under the row.** Two precedents were considered
/// and both rejected: `EngineCard` puts a reason inside a card that stays
/// selectable, and `LivePreviewSettingsView` deliberately moved its reason OUT of
/// the disabled control onto another card, on the recorded grounds that two
/// places saying why is how they come to disagree. One line for one row keeps
/// that property with no group to hang it on.
struct RecordingPillAppearancePanel: View {

  @Environment(PillAppearanceModel.self) private var model
  @Environment(\.settingsNavigate) private var navigate

  var body: some View {
    BrandedPanel(
      icon: "waveform.badge.mic",
      header: "Recording Pill"
    ) {
      VStack(alignment: .leading, spacing: 10) {
        // **ONE row of identical cards, no with-words / without-words split**
        // (founder, 2026-08-26, on seeing the split rendered). The two groups
        // each carried a heading, a state dot and their own reason line, which
        // put the SETTING's state in front of a user who came here to pick a
        // PICTURE. The constraint that split them has not gone away — it is
        // carried by `isEnabled` per card and one line beneath the row.
        //
        // Deliberately the SAME grid metric as the theme cards above
        // (`AppearanceSettingsView`), because the founder's ask was that these
        // read as the same kind of control. A shared literal would be a second
        // authority for one number, so if these ever need to move together the
        // fix is a named constant on `SettingsLayout`, not a copy here.
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 270, maximum: .infinity), spacing: 12)],
          alignment: .leading,
          spacing: 12
        ) {
          ForEach(Self.displayOrder, id: \.self) { design in
            RecordingPillPreviewTile(
              design: design,
              isSelected: Self.selected(in: model) == design,
              isEnabled: model.offersCoupled(design, capability: model.wordsCapability),
              // **Picking a pill also sets Live Preview to what that pill needs**
              // (founder, 2026-08-26). The slot written is still the design's own,
              // so the two remembered choices survive; what is new is that the
              // capability follows the tap instead of gating it.
              onSelect: { model.chooseCoupled(design) })
          }
        }

        // ONE line for the whole row, and only when something in it is greyed —
        // which is now only a Mac that cannot show words at all.
        if let reason = Self.reason(for: model.wordsCapability) {
          Text(reason)
            .settingsReadingCopy()
        }

        // **The way out to the settings this choice just turned on** (founder,
        // 2026-08-26). Picking the pill that shows words switches Live Preview on
        // silently, and the user's next question is how to configure it — which
        // lives on another page. Shown only when that pill is the live choice,
        // because it is answering a question nobody else has asked.
        if Self.selected(in: model).canHoldWords {
          Button {
            navigate(.livePreview)
          } label: {
            Text("Configure Live Preview")
          }
          .buttonStyle(.link)
          .accessibilityHint("Opens the Live Preview settings page")
        }
      }
    }
    // **NO footnote.** "Design and position changes apply the next time the pill
    // appears." was a founder decision earlier in this same work and was DELETED
    // by the founder on 2026-08-26 along with the two instruction lines above it.
    // The page is now three pictures and one link, and a caveat about when a
    // change takes effect is not what a user came here to read.
    //
    // Recorded rather than silently dropped because it was ASKED FOR: the thing
    // it warned about is still true — a design or position change does not touch a
    // recording already on screen.
  }

  /// The order the cards appear in, left to right.
  ///
  /// **The two designs that cannot show words come first, then the one that can**
  /// (founder, 2026-08-26: "the order is wrong"). The enum declares `classic`,
  /// `readingWell`, `levelRail`, which put the odd one out in the MIDDLE and split
  /// the pair that behave alike — and since exactly one side of the row is greyed
  /// at any moment, that also meant the greyed cards were never adjacent.
  ///
  /// Taken from `PillCatalog.designs(holdingWords:)`, whose doc comment already
  /// says it exists "for the picker's ORDER only", rather than by reordering the
  /// enum: the enum's order is a declaration site with other readers, and a
  /// presentation concern has no business moving it.
  static var displayOrder: [RecordingPillDesign] {
    PillCatalog.designs(holdingWords: false) + PillCatalog.designs(holdingWords: true)
  }

  /// The design the pill would use for the NEXT recording.
  ///
  /// **The flat row shows one check, and this is what it marks.** Two slots are
  /// still remembered — one for each capability state — so the mark follows the
  /// state the user is actually in rather than a third stored value that could
  /// disagree with both.
  ///
  /// **RESOLVED, not read raw.** Reading the slot directly returned whatever is
  /// persisted, while the recording director puts the same value through
  /// `PillDesignSelections.resolve` and SUBSTITUTES an incompatible one. A
  /// downgrade or a hand-edited plist can leave a words-capable design in the
  /// wordless slot, and the picker then ticked a card the next recording would
  /// not use — and, since the Configure link keys off this, showed or hid the link
  /// against the wrong design. Found by Codex review; it is the same root as
  /// `offersCoupled`, which was routed through the catalog one round earlier while
  /// this second site was missed.
  static func selected(in model: PillAppearanceModel) -> RecordingPillDesign {
    model.resolvedSelection()
  }

  /// Why some cards in the row are greyed, in one line, or `nil` when none are.
  ///
  /// **Names the ACTION where there is one.** The greyed cards are the ones that
  /// cannot be used in the current state, and every sentence here is about THEM,
  /// never about the state — a line opening "Live Preview is on" reads as a
  /// status report on a page the user opened to choose a picture.
  static func reason(for capability: PillWordsCapability) -> String? {
    switch capability {
    case .available, .previewOff:
      // **Nothing is greyed in these two states any more, so there is nothing to
      // explain.** Picking a design now sets Live Preview to whatever that design
      // needs, which is what the two sentences here used to instruct the user to
      // go and do by hand.
      return nil
    case .engineUnsupported:
      return "Your engine cannot show words on this Mac."
    case .modelBeingRemoved:
      return "Unavailable while a removed model finishes clearing."
    }
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

  /// What a card announces as its VALUE.
  ///
  /// **Extracted because a test and a Python harness both depend on the exact
  /// string.** `wispr_eyes.read_cards` compares `AXValue` against "Selected", and
  /// the Runtime UAT decides whether a tap landed by asking it. Reworded inline,
  /// the harness silently stops seeing selection and reports a working picker as
  /// broken. `theSelectedValueIsExactly` pins it.
  static func accessibilityValue(isSelected: Bool) -> String {
    isSelected ? "Selected" : ""
  }

  /// **Every card draws its pill into THIS box, each at its own scale.**
  ///
  /// **The CARD matches a theme card exactly** (founder, 2026-08-26: "I want the
  /// dimensions to be identical to the light/dark theme rectangles"). An earlier
  /// pass grew these until they were several times a theme card's height and the
  /// two rows stopped reading as the same kind of control, which was the whole
  /// point of the shape.
  ///
  /// The height is `AppearanceCard`'s drawn thumbnail height — 116 x 0.54 — so
  /// both rows come out the same card height once the shared 12pt padding is
  /// added. The WIDTH is not matched and deliberately so: a theme card spends its
  /// remaining width on an icon and a name, and this card has neither, so the
  /// picture takes that room instead. Same rectangle, more of it given to the
  /// preview.
  static let thumbnailSize = CGSize(width: 300, height: 63)

  /// **Each design fills the box on its OWN scale** (founder, 2026-08-26).
  ///
  /// The alternative — one shared factor taken from the widest design — keeps the
  /// pills' RELATIVE sizes honest, and was rendered and rejected: at a scale that
  /// fits a 400pt reading well, a 185pt capsule is a smudge. Two of the three
  /// previews showed nothing, which fails the only job this picker has (#2435:
  /// SHOW the design rather than describe it).
  ///
  /// What is given up is the sense that one pill takes more screen than another.
  /// That is real information, and it is recoverable the first time the user
  /// dictates; an unreadable thumbnail is not recoverable at all.
  ///
  /// **The life-size cap was LIFTED at the founder's direction** (2026-08-26,
  /// after seeing it: "make the mock ups fill out the useable area more"). It had
  /// been 1, on the argument that magnifying a compact pill misrepresents how much
  /// screen it takes — the same objection as the rejected shared scale, pointed the
  /// other way. That argument is still true and was overruled knowingly: at the
  /// window widths people use, the cards run nearly full width and a life-size
  /// 185pt pill in a 445pt card reads as a mistake rather than as fidelity.
  ///
  /// **`maxMagnification` is what stops it becoming absurd.** Uncapped, the fill
  /// rule would draw a compact pill at nearly 5x in a wide window. The bound keeps
  /// the pictures comparable to each other, which is the property that actually
  /// mattered underneath the life-size argument.

  /// The same rule against a REAL card width, which is what the view uses.
  ///
  /// Split out so a test can ask the question at any width rather than only at the
  /// nominal one — the card reflows, so the nominal width is the one case that is
  /// guaranteed not to be what a user sees.
  static func scale(for design: RecordingPillDesign, inWidth available: CGFloat) -> CGFloat {
    guard available > 0, design.width > 0 else { return 1 }
    // **The card can be WIDER than the picture may safely grow**, because the
    // card's HEIGHT is fixed at a theme card's and the pill's height scales with
    // its width. At a single-column layout the reader is ~370pt, which scales the
    // reading well to ~0.93x — and that pill's fixed 34pt header plus its well
    // insets and text then exceed the 63pt box, so it is drawn clipped. Found by
    // cloud review.
    //
    // Capping the width used for the scale is what closes it WITHOUT a per-design
    // height table the view cannot measure. It also removes the gap that hid the
    // defect: the scale is now the same at every card width at or above the
    // nominal one, so a test taken at the nominal width describes what a user
    // actually gets rather than the one case they never see.
    //
    // The cost, and it is the honest trade: at a wide card the picture stops
    // growing and sits centred with margin either side. It could not have grown
    // safely anyway.
    let usable = min(available, thumbnailSize.width)
    return min(maxMagnification, usable / design.width)
  }

  /// How far past life size a preview may be drawn.
  ///
  /// Chosen, not measured: it is the point at which the narrow designs read as
  /// pictures rather than as stamps, without the widest one and the narrowest one
  /// arriving at visibly the same size — which is the failure the rejected shared
  /// scale had, and the one the fill rule would recreate if nothing bounded it.
  ///
  /// **It also has to keep the tallest-for-its-width design inside
  /// `thumbnailSize.height`, and that is the binding constraint.** The card height
  /// matches a theme card by instruction, so it cannot grow to accommodate a
  /// magnified pill; at 2 the capsule drew 71pt into a 63pt box and was silently
  /// clipped. `thePreviewIsTheRealPillScaled` measures every design against the box
  /// and is what caught it — a new design taller for its width than the capsule
  /// fails there LOUDLY rather than shipping cut off.
  /// **1.4, and the number is the CAPSULE's height budget, not a taste call.** Its
  /// pill is 44pt tall against a 63pt box, so anything above ~1.43 clips it — and
  /// 2 and 1.7 both did, the second only because the card WIDTH happened to bound
  /// the scale below the cap and hid it. Tuned against
  /// `thePreviewIsTheRealPillScaled` rather than derived, because the view cannot
  /// measure a leaf's height; that test is what makes a wrong value loud instead of
  /// silently cropping a pill.
  static let maxMagnification: CGFloat = 1.4

  /// What this design's pill measures ON THE CARD, after its own scale.
  ///
  /// Kept as a function rather than read off the rendered view because a test
  /// can hold the RELATION — the widest design fills the box, the others are
  /// proportionally narrower — without hosting anything.
  static func thumbnailWidth(for design: RecordingPillDesign) -> CGFloat {
    design.width * scale(for: design, inWidth: thumbnailSize.width)
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
  /// **Exactly `RainbowLevelMeter.barCount` samples, and it is the whole
  /// picture.** A seeded meter ignores tick changes, so these bars are what
  /// renders on the first frame and on every frame after it — no dependence on
  /// how many times the pill polls or on how `bars` pads a short history.
  ///
  /// Two earlier attempts tuned the LENGTH instead and each only moved the
  /// artifact by one bar; the owner of that reasoning is now
  /// `RainbowLevelMeter.isSeeded`, which is where it belongs.
  ///
  /// It ENDS at `sampleLevel`, because the newest bar and the rainbow mark are
  /// driven by the same instant and a picker drawing them disagreeing would be
  /// showing a pill that cannot occur.
  ///
  /// `internal`, like `sampleDisplay`, because "what the sample pill shows" has
  /// one owner and a test has to be able to read it.
  static let sampleLevelHistory: [CGFloat] = [
    0.06, 0.11, 0.24, 0.38, 0.52, 0.61, 0.55, 0.40,
    0.22, 0.13, 0.09, 0.18, 0.34, 0.49, 0.66, 0.73,
    0.64, 0.47, 0.29, 0.16, 0.10, 0.21, 0.35, CGFloat(sampleLevel),
  ]

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: 12) {
        // **No spacers around the picture.** They were added to centre a fixed-width
        // preview inside a much wider card; now that the preview TAKES the card's
        // width they only compete with it for that width, and the picture ends up
        // smaller than the space it was given. Centring is handled inside the
        // preview instead, by the scale anchor.

        // **Drawn at full size, then scaled WHOLE** — the same move
        // `AppearanceCard` makes with its window thumbnail, and for the same
        // reason: a pill's parts are fixed points, so re-laying it out into a 160
        // point frame would change the proportions of the thing being previewed
        // rather than shrink it.
        // **The preview takes the width the card actually has** (founder,
        // 2026-08-26: "make the mock ups fill out the useable area more"). A fixed
        // box left a wide margin at the window sizes people use, because the cards
        // stack full-width below ~900pt and a 300pt picture in an 890pt card reads
        // as an accident.
        //
        // `GeometryReader` rather than a bigger constant: the card's width is
        // decided by the grid above, which reflows, so any constant is wrong at
        // every width except the one it was picked at.
        GeometryReader { geo in
          RecordingPillPreview(design: self.design)
            // Natural WIDTH, natural height. `scaleEffect` is a draw-time
            // transform and does not change layout, so the frames here are what
            // reserve space; letting the height come from the pill is what keeps a
            // one-line design from reserving a two-line design's box.
            .fixedSize(horizontal: false, vertical: true)
            .scaleEffect(Self.scale(for: design, inWidth: geo.size.width), anchor: .center)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(height: Self.thumbnailSize.height)
        // The scaled draw can exceed the reserved box by a hair on a design whose
        // natural height is unusually tall; clip rather than let it paint over the
        // tick beside it.
        .clipped()

        // **NO VISIBLE NAME** (founder, 2026-08-26): "people know what it is
        // without explaining the name". The picture is the label, which is the
        // whole thesis of #2435 carried to its end — a name beside a drawing of
        // the thing is the description this redesign existed to delete.
        //
        // **The name is NOT gone, it moved.** `accessibilityLabel(for:)` still
        // announces "<name>. <summary>", so a VoiceOver user gets more than a
        // sighted one rather than less. `theLabelCarriesNameAndDescription`
        // guards that, and it is now the ONLY thing standing between this change
        // and a row of unnamed buttons for anyone who cannot see the drawing.
        //
        // Checked before removing: no help article, blog post or website page
        // refers to a design by name, so nothing in the documentation now points
        // at a label the user cannot find.
        // **The tick's slot is reserved whether or not it is shown, and that is a
        // correctness requirement rather than tidiness.** The preview's scale is
        // computed from the width its `GeometryReader` is handed, so a tick that
        // appears only when selected TAKES that width from the card it is on:
        // selecting a design visibly shrank its own pill while the previous
        // selection grew. Found by Codex review — invisible in a static render,
        // because every render captures one selection and the effect is only
        // legible as a change.
        //
        // An empty frame rather than an overlay, so the picture is never drawn
        // underneath the tick.
        ZStack {
          if isSelected {
            Image(systemName: "checkmark.circle.fill")
              .font(.system(size: 18, weight: .semibold))
              .foregroundStyle(Color.white, isEnabled ? Color.stAccent : Color.stTextSecondary)
          }
        }
        .frame(width: 18)
      }
      .padding(12)
      // Before `.buttonStyle(.plain)`: the reserved tick slot is otherwise dead
      // space rather than part of the hit target.
      .contentShape(Rectangle())
      .background(Color.stSectionBg)
      .clipShape(RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius))
      // **An unselected card needs a border you can actually see** (founder,
      // 2026-08-26). At `stDivider` and one point it disappeared against the card's
      // own fill, so a row of three read as one undivided block with a highlight
      // floating in it. Heavier than the theme cards above deliberately: those
      // carry a name and an icon that give them an edge, and these are now bare
      // pictures with nothing else to bound them.
      .overlay(
        RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius)
          .strokeBorder(
            isSelected && isEnabled ? Color.stAccent : Color.stTextTertiary.opacity(0.5),
            lineWidth: isSelected && isEnabled ? 2 : 1.5)
      )
      // These tiles SHOW the product rather than describing it (#2435), which
      // makes them read as illustrations. Hover is what says they are also the
      // control. Gated on `isEnabled` for the same reason `.disabled` is below:
      // a tile at 45% opacity that still answers the pointer is worse than one
      // that does nothing, because it invites the press it will refuse.
      .settingsHoverCard(
        cornerRadius: SettingsLayout.sectionRadius,
        isEnabled: isEnabled,
        isSelected: isSelected && isEnabled)
    }
    .buttonStyle(.plain)
    .disabled(!isEnabled)
    .opacity(isEnabled ? 1 : 0.45)
    // **Addressed by role and title, never by an accessibility identifier**
    // (swift-patterns). A greyed card must REPORT as disabled rather than merely
    // look it: the mistake `EngineCard` records for itself is a control that is
    // visible and inaudible.
    .accessibilityElement(children: .combine)
    .accessibilityLabel(Self.accessibilityLabel(for: design))
    .accessibilityValue(Self.accessibilityValue(isSelected: isSelected))
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
      // **`self.` is required here and is not a style choice.** A bare `design`
      // is whatever is nearest in scope, so a local of that name introduced above
      // this line would make every card draw one design while this line still
      // reads correctly. `self.design` cannot be shadowed, so writing it is what
      // lets `theTileDrawsItsOwnChrome` be an exact question instead of a
      // name-resolution guess.
      chrome: self.design.chrome,
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
