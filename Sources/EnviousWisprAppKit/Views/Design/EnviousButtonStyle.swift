import SwiftUI

// The app's button parts (#4506 Phase 2 PR 2): one style, one face, one label and two glyph
// adapters. DESIGN.md "Approved parts" names them; this file owns their paint.

// MARK: - Style

/// A branded action button for settings sheets and rows.
///
/// **Enabled and disabled must not look alike.** The bordered style this
/// replaced rendered both as low-contrast grey on this surface, and every row's
/// button genuinely disables while any other install runs — so the state that
/// mattered was the state that could not be read.
///
/// **And the SYSTEM prominent style is not a substitute, measured rather than
/// assumed.** `.borderedProminent` renders accent-filled inside the sheet and
/// plain grey on the settings page, in the same build, from the same modifier —
/// so a button's affordance depended on which container it landed in. Owning the
/// fill, border and hover here makes the appearance a property of the control
/// rather than of its surroundings.
///
/// #4506: a `PrimitiveButtonStyle`, not a `ButtonStyle`. Every action button was a `Button` with
/// `.buttonStyle(.plain)`, and `PlainButtonStyle` is itself a `PrimitiveButtonStyle` whose pressed
/// dimming and disabled half-strength opacity are drawn by the system. This style delegates both
/// to an inner real `Button` with `.plain` instead of re-drawing them by guessed values. The face
/// paints; the inner button presses, dims and activates. Disabled paint is compared in the design
/// render captures; pressed paint is compared in Live UAT (plan §11.1).
struct EnviousButtonStyle: PrimitiveButtonStyle {
  var emphasis: EnviousButtonFace.Emphasis = .outlined
  var shape: EnviousButtonFace.Shape = .capsule
  var size: EnviousButtonFace.Size = .regular
  /// The legacy paint switch: the caller's own `isEnabled`, which decides the enabled or
  /// disabled colours. It never enables anything: activation and hover follow the effective
  /// environment (`.disabled` on this button or any parent).
  var paintsEnabled = true

  func makeBody(configuration: Configuration) -> some View {
    // **The ROLE, not just the colour.** `emphasis` decides how this looks;
    // `role` is what AppKit and VoiceOver read, and the system `Button`s this
    // replaced supplied it. Carrying the tone visually while dropping the
    // semantics would leave an irreversible action indistinguishable from an
    // ordinary one to anyone not looking at the pixels -- which is the same
    // defect as the grey Delete button, one sense over (cloud review, #2447).
    Button(role: configuration.role, action: configuration.trigger) {
      configuration.label
        .modifier(
          EnviousButtonFace(
            emphasis: Self.paint(for: configuration.role, emphasis),
            shape: shape, size: size, paintsEnabled: paintsEnabled))
    }
    .buttonStyle(.plain)
  }

  /// The destructive look follows the ROLE only: a destructive role paints destructive whatever
  /// emphasis was asked for, and `.destructive` asked for on a button without that role paints
  /// `outlined`, so red never appears without the meaning VoiceOver reads. A decorative,
  /// non-control instance keeps the destructive look through `EnviousButtonFace` directly.
  static func paint(for role: ButtonRole?, _ emphasis: EnviousButtonFace.Emphasis)
    -> EnviousButtonFace.Emphasis
  {
    if role == .destructive { return .destructive }
    return emphasis == .destructive ? .outlined : emphasis
  }
}

extension View {
  /// A Settings action button: the style, the search-arrival focus adapter every Settings
  /// action button carries (#3482), the keyboard shortcut and the disabled state, in the order
  /// the `SettingsActionButton` wrapper applied them (#4506). Apply to the `Button` itself.
  ///
  /// `isEnabled` is the caller's own enabled condition, written once: it picks the enabled or
  /// disabled paint (`EnviousButtonStyle.paintsEnabled`) and disables the button. A parent's
  /// `.disabled` still disables it as well; the paint then stays as `isEnabled` says and only
  /// the system dimming shows, as it did before.
  ///
  /// `shortcut`: Return or Escape for a sheet's confirm and cancel.
  ///
  /// **A parameter rather than something the call site applies, so the shortcut
  /// lands on a control rather than on a wrapper.** Apple documents
  /// `keyboardShortcut(_:modifiers:)` as assigning the shortcut to "the modified
  /// control"; this type is a composite `View`, not a control, so a call site
  /// writing the modifier on the outside is relying on behaviour the
  /// documentation does not describe. Passed in, it is applied to the `Button`
  /// below, which is unambiguously the control.
  ///
  /// The failure this avoids is a silent one: a footer that swapped `Button` for
  /// this type and kept its own modifier still works when CLICKED, so nothing on
  /// screen would say Escape had stopped answering.
  func settingsButton(
    _ emphasis: EnviousButtonFace.Emphasis = .outlined, shape: EnviousButtonFace.Shape = .capsule,
    size: EnviousButtonFace.Size = .regular, isEnabled: Bool, shortcut: KeyboardShortcut? = nil
  ) -> some View {
    buttonStyle(
      EnviousButtonStyle(emphasis: emphasis, shape: shape, size: size, paintsEnabled: isEnabled)
    )
    .settingsArrivalFocusControl()
    .modifier(SettingsButtonShortcut(shortcut: shortcut))
    .disabled(!isEnabled)
  }
}

/// Binds `shortcut` to the `Button`, and leaves the shortcut ALONE when there
/// is none.
///
/// **The branch is the fix, not a style choice.** An unconditional
/// `.keyboardShortcut(shortcut)` also runs for `nil`, and a caller that
/// applies its own modifier on the OUTSIDE of this composite then has it
/// overridden from within -- which is how a Cancel button keeps working when
/// clicked and silently stops answering Escape. Found by review on exactly
/// that: the two #2445 sheet footers had their `.cancelAction` and
/// `.defaultAction` cleared by this type's own default.
private struct SettingsButtonShortcut: ViewModifier {
  let shortcut: KeyboardShortcut?

  @ViewBuilder
  func body(content: Content) -> some View {
    if let shortcut {
      content.keyboardShortcut(shortcut)
    } else {
      content
    }
  }
}

// MARK: - Label

/// The words and optional glyphs inside an action button, at the face's type size.
///
/// The label, already resolved. Callers pass a literal to `title:`, which the catalog
/// extracts by its type, or text that is already translated (or is the user's own) to
/// `verbatimTitle:`. There is deliberately no `String` `title:`: a literal would bind to it
/// and ship in English (#3142).
struct EnviousButtonLabel: View {
  let title: String
  var size: EnviousButtonFace.Size = .regular
  /// An optional leading SF Symbol, for the few actions whose glyph does real
  /// work: Preview's play triangle, Refresh's arrows.
  var systemImage: String? = nil
  /// A trailing SF Symbol, for the prototype's "Continue ->" arrow. Separate from
  /// `systemImage`, which leads, because a button can want one, the other, or neither.
  var trailingSystemImage: String? = nil

  init(
    _ title: LocalizedStringResource, size: EnviousButtonFace.Size = .regular,
    systemImage: String? = nil, trailingSystemImage: String? = nil
  ) {
    self.init(
      verbatim: String(localized: title), size: size, systemImage: systemImage,
      trailingSystemImage: trailingSystemImage)
  }

  init(
    verbatim title: String, size: EnviousButtonFace.Size = .regular, systemImage: String? = nil,
    trailingSystemImage: String? = nil
  ) {
    self.title = title
    self.size = size
    self.systemImage = systemImage
    self.trailingSystemImage = trailingSystemImage
  }

  var body: some View {
    HStack(spacing: 5) {
      if let systemImage {
        Image(systemName: systemImage)
          .font(.system(size: 11, weight: .semibold))
          // Decoration. Without this the symbol contributes its own
          // symbol-derived name beside the title, so "Add term" is announced
          // as a plus sign AND the words -- where the `Label` this replaced
          // announced one thing.
          .accessibilityHidden(true)
      }
      Text(title)
        .font(.system(size: size.fontSize, weight: .semibold))
      if let trailingSystemImage {
        Image(systemName: trailingSystemImage)
          .font(.system(size: size.fontSize - 1, weight: .semibold))
          // Decoration, same reason as the leading glyph above: the arrow in "Continue ->"
          // is the shape of the word, not a second thing to announce.
          .accessibilityHidden(true)
      }
    }
  }
}

// MARK: - Face

/// The treatment, with no control around it. Shared so a decorative instance and a real
/// button cannot drift apart visually — which is the whole reason the drop zone draws one
/// at all.
struct EnviousButtonFace: ViewModifier {
  /// How loud this button is. `outlined` is a row-level action, `filled` the one
  /// primary on a surface — a hierarchy the system styles could not express here
  /// because their rendering depended on the container.
  /// `destructive` is `outlined` in the error tone, for Clear / Delete / Remove
  /// All. Those sites reached for `.bordered` plus a red `foregroundStyle`,
  /// which on a settings page rendered as grey with red text — the same
  /// "looks disabled" reading that made the Download buttons unreadable, on the
  /// one class of action where a misread is expensive.
  ///
  /// #2772 finding 9: `quiet` is the SECONDARY of the approved Transcribe a File prototype
  /// — a hairline border in the divider tone, no fill, and the ordinary body colour for the
  /// label. Founder: "Secondary (Back): rounded RECTANGLE ... hairline border, no fill,
  /// plain white label. NOT a pill, NO purple border." `outlined` is the purple-bordered
  /// pill that description rejects, and it stays exactly as it is because every other
  /// settings page ships it.
  enum Emphasis { case outlined, filled, destructive, quiet }

  /// The outline this button is cut from. Capsule everywhere in Settings; the file-import
  /// wizard uses the prototype's 9pt rounded rectangle (#2772 finding 9).
  enum Shape { case capsule, roundedRect }

  /// How big. `regular` is every pre-#2772 call site, byte for byte. The other two are the
  /// prototype's `.btn` (14px, 8x14) and `.btn.big` (15px, 10x22), which the founder called
  /// "visibly larger than shipped".
  enum Size {
    case regular, medium, large

    var fontSize: CGFloat {
      switch self {
      case .regular: return 12
      case .medium: return 14
      case .large: return 15
      }
    }

    var horizontalPadding: CGFloat {
      switch self {
      case .regular, .medium: return 14
      case .large: return 22
      }
    }

    var verticalPadding: CGFloat {
      switch self {
      case .regular: return 6
      case .medium: return 8
      case .large: return 10
      }
    }
  }

  var emphasis: Emphasis = .outlined
  var shape: Shape = .capsule
  var size: Size = .regular
  /// The caller's own enabled flag, for paint only. See `EnviousButtonStyle.paintsEnabled`.
  var paintsEnabled = true

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// A PARENT can disable this control without touching `isEnabled`, and then
  /// the two disagree. See `SettingsHover.respondsToPointer`.
  @Environment(\.isEnabled) private var environmentEnabled
  @State private var pointerInside = false

  /// DERIVED, never stored. See `SettingsHover.respondsToPointer`.
  private var hovering: Bool {
    SettingsHover.respondsToPointer(pointerInside, paintsEnabled, environmentEnabled)
  }

  func body(content: Content) -> some View {
    content
      .padding(.horizontal, size.horizontalPadding)
      .padding(.vertical, size.verticalPadding)
      .foregroundStyle(foreground)
      .background(fill, in: outline)
      .overlay(outline.strokeBorder(border, lineWidth: 1).allowsHitTesting(false))
      .contentShape(outline)
      .onHover { pointerInside = $0 }
      .animation(reduceMotion ? nil : SettingsHover.animation, value: hovering)
  }

  /// The one place `shape` becomes geometry, so the fill, the border and the hit target
  /// cannot end up cut from three different outlines.
  private var outline: AnyInsettableShape {
    switch shape {
    case .capsule: return AnyInsettableShape(Capsule())
    case .roundedRect:
      return AnyInsettableShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
  }

  /// The one place emphasis becomes a colour. `destructive` is the only
  /// emphasis that leaves the brand accent, so the three rules below read the
  /// tone from here instead of each testing the emphasis themselves.
  private var tone: Color { emphasis == .destructive ? Color.stError : Color.stAccent }

  private var foreground: Color {
    guard paintsEnabled else { return Color.stTextTertiary }
    if emphasis == .filled { return Color.white }
    // The prototype's `.btn.sec`: body colour at rest, accent on hover. It never fills, so
    // white-on-hover would be white on the page background.
    if emphasis == .quiet { return hovering ? Color.stAccent : Color.stTextPrimary }
    return hovering ? Color.white : tone
  }

  private var fill: Color {
    guard paintsEnabled else { return Color.clear }
    switch emphasis {
    case .filled:
      return hovering ? Color.stAccent : Color.stAccentSolid
    case .destructive:
      return hovering ? Color.stError : Color.stError.opacity(0.12)
    case .outlined:
      return hovering ? Color.stAccentSolid : Color.stAccentLight
    case .quiet:
      return Color.clear
    }
  }

  private var border: Color {
    guard paintsEnabled else { return Color.stDivider }
    if emphasis == .filled { return Color.clear }
    if emphasis == .quiet { return hovering ? Color.stAccent : Color.stDivider }
    return hovering ? Color.clear : tone
  }
}

/// A type-erased `InsettableShape`, so one button can be cut from either a capsule or a
/// rounded rectangle without three modifiers each branching on which (#2772 finding 9).
///
/// `AnyShape` exists and is not enough: `strokeBorder` requires `InsettableShape`, which
/// `AnyShape` does not conform to. `stroke` would compile and draw the border straddling the
/// edge instead of inside it, which is a 1pt size difference between the two shapes for no
/// reason a reader could see.
struct AnyInsettableShape: InsettableShape {
  private let makePath: @Sendable (CGRect) -> Path
  private let makeInset: @Sendable (CGFloat) -> AnyInsettableShape

  init<S: InsettableShape>(_ shape: S) where S: Sendable, S.InsetShape: Sendable {
    makePath = { shape.path(in: $0) }
    makeInset = { AnyInsettableShape(shape.inset(by: $0)) }
  }

  func path(in rect: CGRect) -> Path { makePath(rect) }
  func inset(by amount: CGFloat) -> AnyInsettableShape { makeInset(amount) }
}

// MARK: - Glyph adapters

/// The close glyph of a settings sheet's title bar. Its hover paint is `settingsHoverQuiet`'s,
/// not a second painter.
struct EnviousCloseGlyph: View {
  var body: some View {
    Image(systemName: "xmark")
      .font(.system(size: 11, weight: .bold))
      .foregroundStyle(Color.stTextSecondary)
      .frame(width: 22, height: 22)
      .settingsHoverQuiet()
      .contentShape(Circle())
  }
}

/// The "?" glyph of `SettingsInfoButton`. ONE `Image`; hover changes only its colour value, and
/// the capsule is `settingsHoverQuiet`'s.
struct EnviousHelpGlyph: View {
  /// Whether the pointer is over the button, as the button derives it.
  let hovering: Bool

  var body: some View {
    Image(systemName: "questionmark.circle")
      // The hover colour is a VALUE on this one Image, never a second view: the shared
      // tinted treatment swaps the content for another view while hovering, and under
      // this button's popover that swap is the leading suspect for the bubble closing at
      // once on macOS 15 (#3862).
      .foregroundStyle(hovering ? Color.stAccent : Color.stTextTertiary)
      .font(.system(size: 15, weight: .regular))
      // Accent on hover: the neutral treatment's capsule is the card's own colour,
      // so on a card it never showed (founder, 2026-10-03: "the help icons should
      // have the hover effect").
      .settingsHoverQuiet(tint: .stAccent, recoloursContent: false)
  }
}
