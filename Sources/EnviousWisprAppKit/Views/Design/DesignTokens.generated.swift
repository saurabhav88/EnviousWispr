// GENERATED from DESIGN.md by scripts/design/generate-tokens.py. Do not edit.
// Edit the values block in DESIGN.md, then run: python3 scripts/design/generate-tokens.py

import SwiftUI

// MARK: - Colors (light and dark pairs, resolved per appearance by Color.stDynamic)
//
// Settings palette: Each token pairs the exact light value shipped before #1047 with a dark night-comfort value (low-chroma surfaces, off-white text, desaturated lavender accent, muted semantics). Consumers read these statics unchanged, so the whole window adapts when `NSApp.appearance` flips.
//
// Onboarding palette: #1047: each token pairs the exact pre-dark light value with a dark night-comfort value via `Color.stDynamic`. `obRainbow` is the brand signature and stays vivid in both modes. `obButtonFill` / `obKeycapTop` are new role tokens (see note below) that resolve a light/dark conflict: `obTextPrimary` was doubling as both heading text AND a primary-button background with white text — inverting it would make that white text vanish on dark, so the button-fill role is now its own token.

extension Color {
  // Settings surfaces
  /// Settings page background (#f8f5ff / #131019).
  static let stPageBg = stDynamic(
    lightRGB: (0.973, 0.961, 1.0, 1), darkRGB: (0.075, 0.063, 0.098, 1))
  /// Card surface (#ffffff / #201b2b).
  static let stSectionBg = stDynamic(
    lightRGB: (1, 1, 1, 1), darkRGB: (0.125, 0.106, 0.169, 1))
  /// Sidebar card (#e8e2f5 / #1a1623).
  static let stSidebarBg = stDynamic(
    lightRGB: (0.91, 0.886, 0.961, 1), darkRGB: (0.102, 0.086, 0.137, 1))
  /// Window canvas (#ddd5ee / #0d0b12).
  ///
  /// The window canvas BEHIND the two floating frame cards (sidebar + content). Deliberately darker than every card surface so both panels read as raised, uniformly-inset cards on a common ground (founder, 2026-07-03: sidebar and content as two equal, equally-spaced bordered cards).
  static let stWindowBg = stDynamic(
    lightRGB: (0.867, 0.835, 0.933, 1), darkRGB: (0.051, 0.043, 0.071, 1))
  // Settings text
  /// Titles, labels and reading copy (#0f0a1a / #ece9f4).
  ///
  /// Primary is the reading-copy colour: near-black in light, near-white in dark. The dark value is capped below pure white (~92%) to limit halation on the night-comfort surfaces while staying markedly crisper than the secondary grey.
  static let stTextPrimary = stDynamic(
    lightRGB: (0.059, 0.039, 0.102, 1), darkRGB: (0.925, 0.914, 0.957, 1))
  /// Secondary text (#4a3d60 / #aaa2bf).
  static let stTextSecondary = stDynamic(
    lightRGB: (0.29, 0.239, 0.376, 1), darkRGB: (0.667, 0.635, 0.749, 1))
  /// Quiet text and disabled labels (#6b5e86 / #7a7290).
  static let stTextTertiary = stDynamic(
    lightRGB: (0.42, 0.369, 0.525, 1), darkRGB: (0.478, 0.447, 0.565, 1))
  /// Descriptions (#332d47 / #d5d1e2).
  ///
  /// Reading-copy body: a "whiter grey" — clearly brighter than the secondary grey (which the founder disliked), sitting just under the near-white primary of labels/titles so descriptions read calm but not dim (#1296 pass).
  static let stTextBody = stDynamic(
    lightRGB: (0.2, 0.176, 0.278, 1), darkRGB: (0.835, 0.82, 0.886, 1))
  // Settings accent
  /// Brand purple for TEXT and OUTLINES only (#7c3aed / #a78bfa).
  static let stAccent = stDynamic(
    lightRGB: (0.486, 0.227, 0.929, 1), darkRGB: (0.655, 0.545, 0.98, 1))
  /// Faint accent wash behind outlined controls and badges.
  static let stAccentLight = stDynamic(
    lightRGB: (0.486, 0.227, 0.929, 0.09), darkRGB: (0.655, 0.545, 0.98, 0.16))
  /// FILLED selected surfaces that carry white text (#7c3aed / #8b46f0).
  ///
  /// Solid brand purple for FILLED selected surfaces that carry white text/glyphs (segmented pills, filled check badges). Stays the darker brand #7c3aed in BOTH modes — the desaturated lavender `stAccent` is for text/outlines only; as a fill under white it reads washed-out (founder, 2026-07-03). Dark mode lifts it a hair (#8b46f0) so the pill still pops on the night surface.
  static let stAccentSolid = stDynamic(
    lightRGB: (0.486, 0.227, 0.929, 1), darkRGB: (0.545, 0.275, 0.941, 1))
  // Settings toggle
  /// Switch track when on (#00a366 / #5cc99a).
  static let stToggleOn = stDynamic(
    lightRGB: (0.0, 0.639, 0.4, 1), darkRGB: (0.361, 0.788, 0.604, 1))
  /// Switch track when off (#9b8eb8 / #4a4360).
  static let stToggleOff = stDynamic(
    lightRGB: (0.608, 0.557, 0.722, 1), darkRGB: (0.29, 0.263, 0.376, 1))
  // Settings status
  /// Success. Status (semantic — use these, not raw .red/.green/.orange) (#00a366 / #5cc99a).
  static let stSuccess = stDynamic(
    lightRGB: (0.0, 0.639, 0.4, 1), darkRGB: (0.361, 0.788, 0.604, 1))
  /// Warning (#cc7000 / #e6b766).
  static let stWarning = stDynamic(
    lightRGB: (0.8, 0.439, 0.0, 1), darkRGB: (0.902, 0.718, 0.4, 1))
  /// Warning wash behind warning notices.
  static let stWarningSoft = stDynamic(
    lightRGB: (0.8, 0.439, 0.0, 0.1), darkRGB: (0.902, 0.718, 0.4, 0.14))
  /// Error and destructive actions (#c0392b / #ef7c89).
  static let stError = stDynamic(
    lightRGB: (0.753, 0.224, 0.169, 1), darkRGB: (0.937, 0.486, 0.537, 1))
  // Settings controls
  /// Every field, picker box and segmented track (#f6f4fb / #2a2536).
  ///
  /// One fill for all of them, so a control reads the same wherever it sits. The dark value is the mockup's purple-grey (#2a2536, the card lifted 7% toward lavender), replacing the near-black boxes (founder, 2026-10-03: "I want these color boxes. I don't like the black"). The border below keeps a typable field obvious (founder, 2026-09-10: "the top box isn't obvious it's editable").
  static let stInputBg = stDynamic(
    lightRGB: (0.965, 0.957, 0.984, 1), darkRGB: (0.165, 0.145, 0.212, 1))
  /// Border of typable fields and picker boxes.
  static let stInputBorder = stDynamic(
    lightRGB: (0.541, 0.169, 0.886, 0.2), darkRGB: (0.722, 0.667, 0.839, 0.3))
  // Settings dividers
  /// Row dividers and hairlines.
  static let stDivider = stDynamic(
    lightRGB: (0.541, 0.169, 0.886, 0.08), darkRGB: (0.722, 0.667, 0.839, 0.14))
  // Onboarding backgrounds
  /// Onboarding window background.
  static let obSurface = stDynamic(
    lightRGB: (0.941, 0.925, 0.976, 1), darkRGB: (0.125, 0.106, 0.169, 1))
  /// Onboarding card surface.
  static let obCardBg = stDynamic(
    lightRGB: (1, 1, 1, 1), darkRGB: (0.145, 0.122, 0.216, 1))
  // Onboarding text
  /// Onboarding headings and primary text.
  static let obTextPrimary = stDynamic(
    lightRGB: (0.059, 0.039, 0.102, 1), darkRGB: (0.91, 0.894, 0.945, 1))
  /// Onboarding secondary text.
  static let obTextSecondary = stDynamic(
    lightRGB: (0.29, 0.239, 0.376, 1), darkRGB: (0.667, 0.635, 0.749, 1))
  /// Onboarding quiet text.
  static let obTextTertiary = stDynamic(
    lightRGB: (0.49, 0.435, 0.588, 1), darkRGB: (0.478, 0.447, 0.565, 1))
  /// Primary onboarding button fill.
  ///
  /// Primary button fill — dark in light mode (near-black brand fill), a rich purple in dark mode. White button text reads on both (≈5.8:1 on dark).
  static let obButtonFill = stDynamic(
    lightRGB: (0.059, 0.039, 0.102, 1), darkRGB: (0.42, 0.31, 0.82, 1))
  /// Raised keycap face in the shortcut steps.
  ///
  /// Keycap top — the raised key face; white in light, a light-violet face in dark so the key still reads as a key against the dark window.
  static let obKeycapTop = stDynamic(
    lightRGB: (1, 1, 1, 1), darkRGB: (0.18, 0.155, 0.255, 1))
  // Onboarding brand
  /// Onboarding accent.
  static let obAccent = stDynamic(
    lightRGB: (0.486, 0.227, 0.929, 1), darkRGB: (0.655, 0.545, 0.98, 1))
  /// Onboarding accent wash.
  static let obAccentSoft = stDynamic(
    lightRGB: (0.486, 0.227, 0.929, 0.1), darkRGB: (0.655, 0.545, 0.98, 0.16))
  // Onboarding semantic
  /// Onboarding success.
  static let obSuccess = stDynamic(
    lightRGB: (0.0, 0.784, 0.502, 1), darkRGB: (0.361, 0.788, 0.604, 1))
  /// Onboarding success wash.
  static let obSuccessSoft = stDynamic(
    lightRGB: (0.0, 0.784, 0.502, 0.1), darkRGB: (0.361, 0.788, 0.604, 0.16))
  /// Onboarding success text.
  static let obSuccessText = stDynamic(
    lightRGB: (0.0, 0.541, 0.337, 1), darkRGB: (0.361, 0.788, 0.604, 1))
  /// Onboarding warning.
  static let obWarning = stDynamic(
    lightRGB: (0.902, 0.761, 0.0, 1), darkRGB: (0.902, 0.718, 0.4, 1))
  /// Onboarding error.
  static let obError = stDynamic(
    lightRGB: (0.902, 0.145, 0.227, 1), darkRGB: (0.937, 0.486, 0.537, 1))
  /// Onboarding error wash.
  static let obErrorSoft = stDynamic(
    lightRGB: (0.902, 0.145, 0.227, 0.1), darkRGB: (0.937, 0.486, 0.537, 0.16))
  // Onboarding borders
  /// Onboarding card borders.
  static let obBorder = stDynamic(
    lightRGB: (0.541, 0.169, 0.886, 0.06), darkRGB: (0.722, 0.667, 0.839, 0.14))
  // First-run Setup
  /// Setup quiet text (eyebrows, hints). Mockup t3, raised from obTextTertiary to pass 4.5:1 on obSurface and obCardBg in both modes.
  static let firstRunTextTertiary = stDynamic(
    lightRGB: (0.4, 0.345, 0.502, 1), darkRGB: (0.627, 0.596, 0.714, 1))
  /// Setup success text (key valid, checks). Mockup success-text, 4.5:1 on light cards.
  static let firstRunSuccessText = stDynamic(
    lightRGB: (0.0, 0.459, 0.29, 1), darkRGB: (0.361, 0.788, 0.604, 1))
  /// Setup error text (failed key check, download stopped). Mockup error-text, 4.5:1.
  static let firstRunErrorText = stDynamic(
    lightRGB: (0.784, 0.118, 0.192, 1), darkRGB: (0.937, 0.486, 0.537, 1))
  /// Setup primary button fill while hovered.
  static let firstRunButtonHover = stDynamic(
    lightRGB: (0.169, 0.133, 0.251, 1), darkRGB: (0.486, 0.38, 0.871, 1))
  /// Setup primary button fill while it cannot be pressed.
  static let firstRunButtonDisabled = stDynamic(
    lightRGB: (0.89, 0.871, 0.925, 1), darkRGB: (0.212, 0.188, 0.278, 1))
  /// Text on firstRunButtonDisabled (4.26:1 in both modes; disabled controls are exempt from WCAG 1.4.3, kept readable).
  static let firstRunButtonDisabledText = stDynamic(
    lightRGB: (0.435, 0.38, 0.537, 1), darkRGB: (0.604, 0.573, 0.69, 1))
  /// Text or icon on an obAccent fill (selected tab, step dot).
  static let firstRunOnAccent = stDynamic(
    lightRGB: (1.0, 1.0, 1.0, 1), darkRGB: (0.082, 0.071, 0.11, 1))
  /// Setup accent wash (selected card, greeting bubble). Dark alpha 0.12 instead of obAccentSoft 0.16 so text on it keeps 4.5:1.
  static let firstRunAccentSoft = stDynamic(
    lightRGB: (0.486, 0.227, 0.929, 0.1), darkRGB: (0.655, 0.545, 0.98, 0.12))
  /// Setup hairline (mockup --rule): unreached step-strip segments, dividers and keycap edges. obBorder (accent at 6%) is too faint for these.
  static let firstRunRule = stDynamic(
    lightRGB: (0.0, 0.0, 0.0, 0.1), darkRGB: (1.0, 1.0, 1.0, 0.12))
}

// MARK: - Fonts (SF Pro)
//
// One small type scale, four roles, used across every Settings page: stSectionHeader — the small uppercased eyebrow above a card/group. stRowTitle — the lead line of a row (control name, engine name). stBody — descriptions + explainer paragraphs (the reading copy). stHelper — captions, hints, status, footnotes (the quiet microcopy). Hierarchy comes from SIZE + WEIGHT, not colour: titles and body share the near-white primary colour so a page never has a bright paragraph shouting over a dim title. Only stHelper steps down to a quieter colour.
//
// 14pt is the FLOOR for every piece of Settings text — nothing renders smaller (founder directive 2026-07-03). Hierarchy is built UP from 14 with weight and the title size bump, never down with a smaller size.

extension Font {
  /// Section eyebrow: uppercased label above a card or group ("ON THIS MAC").
  static let stSectionHeader = Font.system(size: 14, weight: .semibold)
  /// Row / control title: the lead line of a whole section/card (its subject, e.g. "AI Polish", an engine name). Used sparingly, one per section.
  static let stRowTitle = Font.system(size: 16, weight: .semibold)
  /// Sub-row / control label: the lead line of a control row inside a section (e.g. "Language suggestions"). Emphasis via weight, not a bigger size.
  static let stRowLabel = Font.system(size: 14, weight: .semibold)
  /// Reading-copy body: descriptions and multi-sentence explainers. Regular weight, primary (near-white) colour, one uniform size everywhere.
  static let stBody = Font.system(size: 14, weight: .regular)
  /// Caption / hint / status microcopy: footnotes, link hints, status lines. Same 14pt floor as body; it reads quieter through colour, not size.
  static let stHelper = Font.system(size: 14)
  /// A settings row's short grey line under its name (#3385). Held at the 14pt floor by founder decision (2026-10-02) rather than the mockup's 13px; kept as its own token so the row line has one owner.
  static let stRowHelper = Font.system(size: 14)
  /// Onboarding step headline.
  static let obDisplay = Font.system(size: 22, weight: .heavy, design: .rounded)
  /// Onboarding subheading and button text.
  static let obSubheading = Font.system(size: 14, weight: .semibold)
  /// Onboarding body copy.
  static let obBody = Font.system(size: 14, weight: .regular)
  /// Onboarding caption.
  static let obCaption = Font.system(size: 12, weight: .regular)
  /// Onboarding small caption.
  static let obCaptionSmall = Font.system(size: 11, weight: .regular)
  /// Onboarding label.
  static let obLabel = Font.system(size: 13, weight: .medium)
  /// Setup big number (the speed card).
  static let firstRunHero = Font.system(size: 64, weight: .heavy, design: .rounded)
  /// Setup screen title.
  static let firstRunDisplay = Font.system(size: 28, weight: .heavy, design: .rounded)
  /// Setup card title and film caption title.
  static let firstRunTitle = Font.system(size: 20, weight: .heavy, design: .rounded)
  /// Setup practice sentence the person reads aloud.
  static let firstRunSay = Font.system(size: 17, weight: .semibold)
  /// Setup reading copy under a title.
  static let firstRunBody = Font.system(size: 15, weight: .regular)
  /// Setup card name, option name and button text.
  static let firstRunLabel = Font.system(size: 15, weight: .semibold)
  /// Setup card detail lines, hints and film caption subtitle.
  static let firstRunCaption = Font.system(size: 13, weight: .regular)
  /// Setup uppercase eyebrow and badge (RECOMMENDED).
  static let firstRunEyebrow = Font.system(size: 11, weight: .semibold)
}

// MARK: - Layout (points)

enum SettingsLayout {
  /// Corner radius of a settings card.
  static let sectionRadius: CGFloat = 14
  /// Horizontal padding inside a settings row.
  static let rowPaddingH: CGFloat = 14
  /// Vertical padding inside a settings row.
  static let rowPaddingV: CGFloat = 12
  /// Gap between settings cards.
  static let sectionSpacing: CGFloat = 18
  /// Gap above the first content card.
  ///
  /// Gap between the top bar and the first content card (the page-header card), so the bar reads as chrome and the header as the first content object.
  static let contentTop: CGFloat = 18
  /// Page side margin.
  static let contentH: CGFloat = 24
  /// Page bottom margin.
  static let contentBottom: CGFloat = 32
  /// Corner radius of the two window frame cards.
  ///
  /// Two-card window frame (#1296): the sidebar card and content card are each inset from the window edge by `windowFrameInset` and separated from one another by the same value, so the spacing reads uniform on all sides. Their corner radius is a touch larger than the inner setting cards so the frame cards clearly contain the content cards rather than competing with them.
  static let windowCardRadius: CGFloat = 18
  /// Inset of the frame cards from the window edge and from each other.
  static let windowFrameInset: CGFloat = 14
}

enum SettingsPR1Layout {
  /// Dictation Settings dense row padding.
  ///
  /// #3385: density belongs to Dictation Settings, not every shared consumer.
  static let rowPaddingV: CGFloat = 10
  /// Dictation Settings dense heading gap.
  static let headingGap: CGFloat = 8
}

enum DesignRadius {
  /// Smallest radius.
  static let xs: CGFloat = 4
  /// Small radius.
  static let sm: CGFloat = 6
  /// Default small surface (the most-used radius).
  static let md: CGFloat = 8
  /// Medium-large radius.
  static let lg: CGFloat = 10
  /// Large radius.
  static let xl: CGFloat = 12
  /// Largest scale radius.
  static let xxl: CGFloat = 16
}

enum DesignSpacing {
  /// Hairline gaps.
  static let xxs: CGFloat = 2
  /// Tight gaps inside a control.
  static let xs: CGFloat = 4
  /// Icon-to-label gaps.
  static let sm: CGFloat = 6
  /// Default stack gap (the most-used spacing).
  static let md: CGFloat = 8
  /// Gap between related controls.
  static let lg: CGFloat = 10
  /// Gap between groups inside a card.
  static let xl: CGFloat = 12
  /// Gap between unrelated blocks.
  static let xxl: CGFloat = 16
  /// Page-level separation.
  static let xxxl: CGFloat = 24
}

// MARK: - Motion

enum DesignMotion {
  /// Small state changes.
  static let quick = Animation.easeInOut(duration: 0.15)
  /// Short transitions.
  static let brisk = Animation.easeInOut(duration: 0.25)
  /// Default transition (the most-used duration).
  static let standard = Animation.easeInOut(duration: 0.3)
  /// Larger panels appearing or moving.
  static let gentle = Animation.easeInOut(duration: 0.35)
  /// Setup screen entering (slide and fade).
  static let firstRunScreenIn = Animation.easeOut(duration: 0.32)
  /// Setup card, caption or check rising into place.
  ///
  /// The approved mockup (the founder's source of truth, 2026-11-12) rises rows and cards with obRise 0.4s on cubic-bezier(.22,1,.36,1); the generator offers standard curves only, so easeOut at the same duration is the closest token.
  static let firstRunRise = Animation.easeOut(duration: 0.4)
}
