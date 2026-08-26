import SwiftUI

// MARK: - The hover vocabulary for Settings

/// Every hover treatment in the settings window, named once.
///
/// **Why this is one file and not a modifier written at each site.** #2445
/// measured what happens when an affordance is re-derived per call site: five
/// separate defects turned out to be one fact, that `.borderedProminent` renders
/// accent-filled inside a sheet and plain grey on a settings page in the same
/// build. A button's appearance had become a property of its container. Hover is
/// the same shape of risk across many more sites, so the treatments live here
/// and the sites opt in.
///
/// Regenerate the coverage figure rather than trusting a number written here:
/// `grep -rn "\.settingsHover" Sources --include='*.swift'`.
///
/// **The honesty rule, which decides the geometry at every site: the hover
/// region must be exactly the region that responds to a click.** A tint wider
/// than the hit area promises a press that does nothing; a tint narrower than it
/// hides a target the user has already found. Two treatments therefore paint
/// exactly the rectangle their `Button` already claimed, and the third
/// (`settingsHoverQuiet`) pads INSIDE the label so the target grows with the
/// shape rather than the shape outgrowing the target.
///
/// **Motion is gated, colour is not.** Under Reduce Motion the state change
/// still happens, it simply arrives without the fade. Hover carries information
/// about what is clickable, so suppressing it entirely would remove an
/// affordance rather than an animation.
enum SettingsHover {
  /// The one curve and duration, so nothing in the window fades at a different
  /// speed from anything else. It is the value the four hand-rolled hovers had
  /// each written out separately before this file existed; the two that still
  /// keep local hover state read it from here.
  static let animation = Animation.easeOut(duration: 0.12)

  /// A row or list item under the pointer. Deliberately faint: this reads on a
  /// dark card without competing with a selected row, which carries the solid
  /// brand gradient.
  static let rowTint = Color.stAccent.opacity(0.06)

  /// A row that is ALREADY selected. The selected background is a saturated
  /// brand gradient, so `rowTint` beneath it is invisible; hover is carried by a
  /// white veil on top instead.
  static let selectedRowVeil = Color.white.opacity(0.10)

  /// A card-sized target -- an engine card, a theme swatch, a sound preview.
  /// Larger than a row, so the border does the work and the fill stays quiet.
  static let cardTint = Color.stAccent.opacity(0.05)

  /// The default corner radius for a row tint, matching the sidebar row's
  /// selection pill so a row that is hovered and then selected does not change
  /// shape. Every call site whose own shape differs passes its own -- the picker
  /// segment is 7, a settings card is `SettingsLayout.sectionRadius`.
  static let rowRadius: CGFloat = 9

  /// Whether this control should currently be lit up.
  ///
  /// **Ask this at RENDER time, from a stored pointer POSITION -- never store its
  /// answer.** SwiftUI emits `onHover` when the pointer crosses the boundary, so
  /// a control that becomes disabled while the pointer is already inside it gets
  /// no second event: a stored `true` would keep advertising an unavailable
  /// control until the pointer left. Press the Apple Intelligence refresh button
  /// and leave the mouse where it is, and that is exactly the window. Derived,
  /// the answer follows `isEnabled` the instant it changes (review r2, #2447).
  ///
  /// **Two sources, and BOTH have to say yes, because each is blind to the other
  /// half of the truth.** The explicit parameter carries a condition the call
  /// site knows and SwiftUI does not -- a keybind field that is mid-recording is
  /// perfectly enabled and still should not tint. The environment carries the
  /// `.disabled(...)` a PARENT applied, which the call site usually does not
  /// restate and often does not own: `.disabled` propagates down, so a glyph
  /// inside a disabled button reads the flag its button set.
  ///
  /// Reading only the parameter is the defect this exists to fix (review, #2447):
  /// it defaults to `true`, so the Apple Intelligence refresh button while
  /// checking, and the Ollama Delete button while a pull runs, both brightened
  /// under the pointer while refusing every click. **Hover that answers a
  /// control which will not respond is worse than no hover**, because it is a
  /// promise rather than a decoration.
  ///
  /// **Two review rounds found this same root, so here is the enumeration and
  /// the condition that would reopen it.** A rendered hover can disagree with
  /// whether a control accepts a click in exactly three ways: an input is
  /// MISSING, an input is STALE, or the refusal is expressed through a channel
  /// neither input can see. The first two are closed by construction -- both
  /// inputs are read here, at render, and nothing stores the answer.
  ///
  /// The third is the live one, and it is `allowsHitTesting(false)` applied
  /// above a hovering control, which refuses clicks while leaving `\.isEnabled`
  /// true. **A third finding would have to look like that**, and today it cannot:
  /// the only uses in this window are the three decoration overlays in this file
  /// and the zero-size key-capture overlay in `HotkeyRecorderView`, none of which
  /// sits above a control that hovers. Anything that changes is what reopens
  /// this.
  static func respondsToPointer(
    _ inside: Bool, _ callSiteEnabled: Bool, _ environmentEnabled: Bool
  ) -> Bool {
    inside && callSiteEnabled && environmentEnabled
  }
}

// MARK: - Row hover

/// Tints the receiver's own bounds when the pointer is over it.
///
/// Apply INSIDE a `Button`'s label, before `contentShape`, so the tint and the
/// hit area are the same rectangle. Applied outside the button, the tint tracks
/// the pointer over a region that does not respond to a click.
private struct SettingsHoverRowModifier: ViewModifier {
  var cornerRadius: CGFloat
  var tint: Color
  var isEnabled: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// See `SettingsHover.respondsToPointer`.
  @Environment(\.isEnabled) private var environmentEnabled
  @State private var pointerInside = false

  /// DERIVED, never stored. See `SettingsHover.respondsToPointer`.
  private var hovering: Bool {
    SettingsHover.respondsToPointer(pointerInside, isEnabled, environmentEnabled)
  }

  func body(content: Content) -> some View {
    content
      // OVERLAY, not background, and this is load-bearing rather than a style
      // preference. A selected sidebar row paints a saturated brand gradient in
      // its own `.background`; a hover fill added behind that gradient is
      // invisible, so the one row the pointer is most often over would be the
      // one row that never responded. An overlay is also equivalent for the
      // unselected case -- a 6% accent over a transparent row composites to the
      // same pixels as a 6% accent behind it -- so one treatment covers both
      // states instead of two that can drift apart.
      //
      // `allowsHitTesting(false)` is not optional here. A filled `Shape` is
      // hit-testable in SwiftUI even when its fill is `Color.clear`, so an
      // un-disabled overlay would sit on top of the very button it decorates and
      // swallow the click -- the same defect shape #2445 shipped and the founder
      // caught ("the bottom half of the preview engine cards are not clickable").
      // A decoration must never be in the hit path.
      .overlay(
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .fill(hovering ? tint : Color.clear)
          .allowsHitTesting(false)
      )
      .onHover { pointerInside = $0 }
      .animation(reduceMotion ? nil : SettingsHover.animation, value: hovering)
  }
}

/// Lifts a card-sized target so the shape reads as reachable rather than drawn.
///
/// **Which half does the work depends on what the card already spends.** An
/// UNSELECTED card rests on a 1pt divider border, so hover draws an accent
/// border over it -- at card size a fill alone is close to invisible against
/// `stSectionBg`. A SELECTED card already draws a 2pt accent border, so a hover
/// border would land on an identical line and change nothing; that branch
/// brightens the fill instead. Neither branch removes the resting border: both
/// overlay on top of it.
///
/// The pre-existing card hover (`AIPolishProviderRail`) reached for a scale
/// effect for the same "a fill is invisible here" reason, and a scale effect is
/// suppressed entirely under Reduce Motion, taking the affordance with it. That
/// is the trade this modifier exists to avoid.
private struct SettingsHoverCardModifier: ViewModifier {
  var cornerRadius: CGFloat
  var isEnabled: Bool
  /// A selected card already draws a 2pt accent border of its own, so a hover
  /// border would land on top of an identical line and change nothing. The
  /// selected case brightens its FILL instead -- the one channel the resting
  /// selected state leaves unused.
  var isSelected: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// See `SettingsHover.respondsToPointer`.
  @Environment(\.isEnabled) private var environmentEnabled
  @State private var pointerInside = false

  /// DERIVED, never stored. See `SettingsHover.respondsToPointer`.
  private var hovering: Bool {
    SettingsHover.respondsToPointer(pointerInside, isEnabled, environmentEnabled)
  }

  func body(content: Content) -> some View {
    content
      .overlay(
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .fill(hovering ? (isSelected ? SettingsHover.rowTint : SettingsHover.cardTint) : Color.clear)
          .allowsHitTesting(false)
      )
      .overlay(
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .strokeBorder(
            hovering && !isSelected ? Color.stAccent.opacity(0.55) : Color.clear,
            lineWidth: 1)
          .allowsHitTesting(false)
      )
      .onHover { pointerInside = $0 }
      .animation(reduceMotion ? nil : SettingsHover.animation, value: hovering)
  }
}

/// A small quiet control: a close X, a play triangle, a trash, or a bare word
/// like Retry or Delete standing in for a button. It brightens and gains a soft
/// shape behind it.
///
/// **The shape is a `Capsule`, not a `Circle`, and that is the whole reason one
/// treatment covers both cases.** A `Circle` sizes to the smaller dimension and
/// centres, so behind a square glyph it is a disc and behind the word "Delete"
/// it is a disc in the middle of the word with the letters hanging off both
/// ends. A capsule is a circle when the content is square and a pill when it is
/// wide, which is exactly the pair this modifier is asked for.
private struct SettingsHoverQuietModifier: ViewModifier {
  var isEnabled: Bool
  /// How much room the capsule gets around the content.
  ///
  /// **A parameter because this modifier GROWS its site, and 5pt is not small
  /// everywhere.** Around a 12pt refresh glyph in a row it is the difference
  /// between a comfortable target and a smudge; around the 8pt xmark inside an
  /// alias chip it would be most of the chip. The default suits a row; tight
  /// contexts pass their own.
  var inset: CGFloat
  /// Optional tone for a glyph whose ACTION has one: the error red on a trash,
  /// where hover is the last moment before something irreversible and is worth
  /// spending colour on. `nil` keeps the neutral brighten, which is right for a
  /// close X or a page chevron.
  var tint: Color?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// See `SettingsHover.respondsToPointer`.
  @Environment(\.isEnabled) private var environmentEnabled
  @State private var pointerInside = false

  /// DERIVED, never stored. See `SettingsHover.respondsToPointer`.
  private var hovering: Bool {
    SettingsHover.respondsToPointer(pointerInside, isEnabled, environmentEnabled)
  }

  func body(content: Content) -> some View {
    recoloured(content)
      // The padding is part of the treatment, not spacing. A bare SF Symbol is
      // 12-14pt of glyph, so a shape drawn tight to it reads as a smudge and the
      // hit region is smaller than a pointer can comfortably land on. Padding
      // first, shape second, so both grow -- and because this sits inside the
      // `Button`'s label at every call site, the target grows with them.
      .padding(inset)
      .background(
        Capsule()
          .fill(hovering ? (tint?.opacity(0.15) ?? Color.stSectionBg) : Color.clear)
      )
      // Brightness is the UNTINTED path only. On a red glyph it washes toward
      // pink, which reads as less urgent at the exact moment more urgency is
      // wanted.
      .brightness(hovering && tint == nil ? 0.18 : 0)
      .onHover { pointerInside = $0 }
      .animation(reduceMotion ? nil : SettingsHover.animation, value: hovering)
  }

  /// Applies the tint ONLY while hovering, and only when there is one.
  ///
  /// An unconditional `foregroundStyle` here would win over the colour each call
  /// site already set on its own glyph -- the clear-search X sets
  /// `.stTextSecondary` immediately before this modifier -- so a decoration
  /// meant to describe the hover state would silently repaint the resting one.
  @ViewBuilder
  private func recoloured(_ content: Content) -> some View {
    if let tint, hovering {
      content.foregroundStyle(tint)
    } else {
      content
    }
  }
}

extension View {
  /// Row-sized hover tint. See `SettingsHoverRowModifier` for where to apply it.
  func settingsHoverRow(
    cornerRadius: CGFloat = SettingsHover.rowRadius,
    tint: Color = SettingsHover.rowTint,
    isEnabled: Bool = true
  ) -> some View {
    modifier(
      SettingsHoverRowModifier(cornerRadius: cornerRadius, tint: tint, isEnabled: isEnabled))
  }

  /// Card-sized hover lift: faint fill plus an accent border.
  func settingsHoverCard(
    cornerRadius: CGFloat,
    isEnabled: Bool = true,
    isSelected: Bool = false
  ) -> some View {
    modifier(
      SettingsHoverCardModifier(
        cornerRadius: cornerRadius, isEnabled: isEnabled, isSelected: isSelected))
  }

  /// Quiet-control hover: brighten the content, add a soft capsule behind it.
  func settingsHoverQuiet(
    isEnabled: Bool = true, inset: CGFloat = 5, tint: Color? = nil
  ) -> some View {
    modifier(SettingsHoverQuietModifier(isEnabled: isEnabled, inset: inset, tint: tint))
  }
}
