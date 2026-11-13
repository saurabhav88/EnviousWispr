# EnviousWispr Design Book

The single source for how the macOS app looks. Every Claude or Codex session reads this file before it designs, builds or changes any app screen, card, control, icon or animation.

- **Scope:** the macOS app (Settings window, onboarding, the recording pill and its notices). The website is not covered yet (#4508). Marketing visuals follow `.claude/skills/brand-guide/SKILL.md`.
- **Authority:** the values block below is the only place token values are edited. `scripts/design/generate-tokens.py` writes `Sources/EnviousWisprAppKit/Views/Design/DesignTokens.generated.swift` from it. Never edit the generated file. `DesignTokensSyncTests` fails when the two disagree.
- **The look is approved.** It came out of many founder review rounds. Reuse it. Do not redesign, "improve" or restyle a part while building a feature. A visible change needs the founder's approval as its own change.

## How to use this book

1. **Pick a part from "Approved parts".** If a part exists for the job, use it. Never build a second card, banner, button, row or badge.
2. **Use tokens, never raw values.** Colors, fonts and layout sizes come from the tokens below. `DesignLiteralRatchetTests` rejects new hand-typed corner sizes, font sizes and color literals.
3. **If nothing fits, stop and ask.** Do not invent a new part, color or size. Propose it to the founder with a mockup that uses these tokens.
4. **Both appearances, always.** Every color has a light and a dark value. Check every new screen in light and dark.

## Values

Edit values only here, then run `python3 scripts/design/generate-tokens.py`. Colors are sRGB RGBA decimal arrays `[r, g, b, a]` with a `light` and a `dark` value, resolved at draw time through `Color.stDynamic` so a theme switch re-colors every window. Fonts are SF Pro (system) with `size`, optional `weight` and optional `design`. Layout values, including the `DesignRadius` and `DesignSpacing` scales, are points (`CGFloat`). Motion entries are an ease curve and a duration in seconds. `reasons` holds recorded founder reasons that the generator repeats as comments.

```json design-tokens
{
  "reasons": {
    "colors": [
      "Settings palette: Each token pairs the exact light value shipped before #1047 with a dark night-comfort value (low-chroma surfaces, off-white text, desaturated lavender accent, muted semantics). Consumers read these statics unchanged, so the whole window adapts when `NSApp.appearance` flips.",
      "Onboarding palette: #1047: each token pairs the exact pre-dark light value with a dark night-comfort value via `Color.stDynamic`. `obRainbow` is the brand signature and stays vivid in both modes. `obButtonFill` / `obKeycapTop` are new role tokens (see note below) that resolve a light/dark conflict: `obTextPrimary` was doubling as both heading text AND a primary-button background with white text — inverting it would make that white text vanish on dark, so the button-fill role is now its own token."
    ],
    "fonts": [
      "One small type scale, four roles, used across every Settings page: stSectionHeader — the small uppercased eyebrow above a card/group. stRowTitle — the lead line of a row (control name, engine name). stBody — descriptions + explainer paragraphs (the reading copy). stHelper — captions, hints, status, footnotes (the quiet microcopy). Hierarchy comes from SIZE + WEIGHT, not colour: titles and body share the near-white primary colour so a page never has a bright paragraph shouting over a dim title. Only stHelper steps down to a quieter colour.",
      "14pt is the FLOOR for every piece of Settings text — nothing renders smaller (founder directive 2026-07-03). Hierarchy is built UP from 14 with weight and the title size bump, never down with a smaller size."
    ]
  },
  "colors": {
    "Color.stPageBg": {
      "light": [0.973, 0.961, 1.0, 1], "dark": [0.075, 0.063, 0.098, 1],
      "group": "Settings surfaces", "usage": "Settings page background (#f8f5ff / #131019)."
    },
    "Color.stSectionBg": {
      "light": [1, 1, 1, 1], "dark": [0.125, 0.106, 0.169, 1],
      "group": "Settings surfaces", "usage": "Card surface (#ffffff / #201b2b)."
    },
    "Color.stSidebarBg": {
      "light": [0.910, 0.886, 0.961, 1], "dark": [0.102, 0.086, 0.137, 1],
      "group": "Settings surfaces", "usage": "Sidebar card (#e8e2f5 / #1a1623)."
    },
    "Color.stWindowBg": {
      "light": [0.867, 0.835, 0.933, 1], "dark": [0.051, 0.043, 0.071, 1],
      "group": "Settings surfaces", "usage": "Window canvas (#ddd5ee / #0d0b12).",
      "note": "The window canvas BEHIND the two floating frame cards (sidebar + content). Deliberately darker than every card surface so both panels read as raised, uniformly-inset cards on a common ground (founder, 2026-07-03: sidebar and content as two equal, equally-spaced bordered cards)."
    },
    "Color.stTextPrimary": {
      "light": [0.059, 0.039, 0.102, 1], "dark": [0.925, 0.914, 0.957, 1],
      "group": "Settings text", "usage": "Titles, labels and reading copy (#0f0a1a / #ece9f4).",
      "note": "Primary is the reading-copy colour: near-black in light, near-white in dark. The dark value is capped below pure white (~92%) to limit halation on the night-comfort surfaces while staying markedly crisper than the secondary grey."
    },
    "Color.stTextSecondary": {
      "light": [0.290, 0.239, 0.376, 1], "dark": [0.667, 0.635, 0.749, 1],
      "group": "Settings text", "usage": "Secondary text (#4a3d60 / #aaa2bf)."
    },
    "Color.stTextTertiary": {
      "light": [0.420, 0.369, 0.525, 1], "dark": [0.478, 0.447, 0.565, 1],
      "group": "Settings text", "usage": "Quiet text and disabled labels (#6b5e86 / #7a7290)."
    },
    "Color.stTextBody": {
      "light": [0.200, 0.176, 0.278, 1], "dark": [0.835, 0.820, 0.886, 1],
      "group": "Settings text", "usage": "Descriptions (#332d47 / #d5d1e2).",
      "note": "Reading-copy body: a \"whiter grey\" — clearly brighter than the secondary grey (which the founder disliked), sitting just under the near-white primary of labels/titles so descriptions read calm but not dim (#1296 pass)."
    },
    "Color.stAccent": {
      "light": [0.486, 0.227, 0.929, 1], "dark": [0.655, 0.545, 0.980, 1],
      "group": "Settings accent", "usage": "Brand purple for TEXT and OUTLINES only (#7c3aed / #a78bfa)."
    },
    "Color.stAccentLight": {
      "light": [0.486, 0.227, 0.929, 0.09], "dark": [0.655, 0.545, 0.980, 0.16],
      "group": "Settings accent", "usage": "Faint accent wash behind outlined controls and badges."
    },
    "Color.stAccentSolid": {
      "light": [0.486, 0.227, 0.929, 1], "dark": [0.545, 0.275, 0.941, 1],
      "group": "Settings accent", "usage": "FILLED selected surfaces that carry white text (#7c3aed / #8b46f0).",
      "note": "Solid brand purple for FILLED selected surfaces that carry white text/glyphs (segmented pills, filled check badges). Stays the darker brand #7c3aed in BOTH modes — the desaturated lavender `stAccent` is for text/outlines only; as a fill under white it reads washed-out (founder, 2026-07-03). Dark mode lifts it a hair (#8b46f0) so the pill still pops on the night surface."
    },
    "Color.stToggleOn": {
      "light": [0.0, 0.639, 0.400, 1], "dark": [0.361, 0.788, 0.604, 1],
      "group": "Settings toggle", "usage": "Switch track when on (#00a366 / #5cc99a)."
    },
    "Color.stToggleOff": {
      "light": [0.608, 0.557, 0.722, 1], "dark": [0.290, 0.263, 0.376, 1],
      "group": "Settings toggle", "usage": "Switch track when off (#9b8eb8 / #4a4360)."
    },
    "Color.stSuccess": {
      "light": [0.0, 0.639, 0.400, 1], "dark": [0.361, 0.788, 0.604, 1],
      "group": "Settings status", "usage": "Success. Status (semantic — use these, not raw .red/.green/.orange) (#00a366 / #5cc99a)."
    },
    "Color.stWarning": {
      "light": [0.800, 0.439, 0.0, 1], "dark": [0.902, 0.718, 0.400, 1],
      "group": "Settings status", "usage": "Warning (#cc7000 / #e6b766)."
    },
    "Color.stWarningSoft": {
      "light": [0.800, 0.439, 0.0, 0.10], "dark": [0.902, 0.718, 0.400, 0.14],
      "group": "Settings status", "usage": "Warning wash behind warning notices."
    },
    "Color.stError": {
      "light": [0.753, 0.224, 0.169, 1], "dark": [0.937, 0.486, 0.537, 1],
      "group": "Settings status", "usage": "Error and destructive actions (#c0392b / #ef7c89)."
    },
    "Color.stInputBg": {
      "light": [0.965, 0.957, 0.984, 1], "dark": [0.165, 0.145, 0.212, 1],
      "group": "Settings controls", "usage": "Every field, picker box and segmented track (#f6f4fb / #2a2536).",
      "note": "One fill for all of them, so a control reads the same wherever it sits. The dark value is the mockup's purple-grey (#2a2536, the card lifted 7% toward lavender), replacing the near-black boxes (founder, 2026-10-03: \"I want these color boxes. I don't like the black\"). The border below keeps a typable field obvious (founder, 2026-09-10: \"the top box isn't obvious it's editable\")."
    },
    "Color.stInputBorder": {
      "light": [0.541, 0.169, 0.886, 0.20], "dark": [0.722, 0.667, 0.839, 0.30],
      "group": "Settings controls", "usage": "Border of typable fields and picker boxes."
    },
    "Color.stDivider": {
      "light": [0.541, 0.169, 0.886, 0.08], "dark": [0.722, 0.667, 0.839, 0.14],
      "group": "Settings dividers", "usage": "Row dividers and hairlines."
    },
    "Color.obSurface": {
      "light": [0.941, 0.925, 0.976, 1], "dark": [0.125, 0.106, 0.169, 1],
      "group": "Onboarding backgrounds", "usage": "Onboarding window background."
    },
    "Color.obCardBg": {
      "light": [1, 1, 1, 1], "dark": [0.145, 0.122, 0.216, 1],
      "group": "Onboarding backgrounds", "usage": "Onboarding card surface."
    },
    "Color.obTextPrimary": {
      "light": [0.059, 0.039, 0.102, 1], "dark": [0.910, 0.894, 0.945, 1],
      "group": "Onboarding text", "usage": "Onboarding headings and primary text."
    },
    "Color.obTextSecondary": {
      "light": [0.290, 0.239, 0.376, 1], "dark": [0.667, 0.635, 0.749, 1],
      "group": "Onboarding text", "usage": "Onboarding secondary text."
    },
    "Color.obTextTertiary": {
      "light": [0.490, 0.435, 0.588, 1], "dark": [0.478, 0.447, 0.565, 1],
      "group": "Onboarding text", "usage": "Onboarding quiet text."
    },
    "Color.obButtonFill": {
      "light": [0.059, 0.039, 0.102, 1], "dark": [0.420, 0.310, 0.820, 1],
      "group": "Onboarding text", "usage": "Primary onboarding button fill.",
      "note": "Primary button fill — dark in light mode (near-black brand fill), a rich purple in dark mode. White button text reads on both (≈5.8:1 on dark)."
    },
    "Color.obKeycapTop": {
      "light": [1, 1, 1, 1], "dark": [0.180, 0.155, 0.255, 1],
      "group": "Onboarding text", "usage": "Raised keycap face in the shortcut steps.",
      "note": "Keycap top — the raised key face; white in light, a light-violet face in dark so the key still reads as a key against the dark window."
    },
    "Color.obAccent": {
      "light": [0.486, 0.227, 0.929, 1], "dark": [0.655, 0.545, 0.980, 1],
      "group": "Onboarding brand", "usage": "Onboarding accent."
    },
    "Color.obAccentSoft": {
      "light": [0.486, 0.227, 0.929, 0.1], "dark": [0.655, 0.545, 0.980, 0.16],
      "group": "Onboarding brand", "usage": "Onboarding accent wash."
    },
    "Color.obSuccess": {
      "light": [0.0, 0.784, 0.502, 1], "dark": [0.361, 0.788, 0.604, 1],
      "group": "Onboarding semantic", "usage": "Onboarding success."
    },
    "Color.obSuccessSoft": {
      "light": [0.0, 0.784, 0.502, 0.1], "dark": [0.361, 0.788, 0.604, 0.16],
      "group": "Onboarding semantic", "usage": "Onboarding success wash."
    },
    "Color.obSuccessText": {
      "light": [0.0, 0.541, 0.337, 1], "dark": [0.361, 0.788, 0.604, 1],
      "group": "Onboarding semantic", "usage": "Onboarding success text."
    },
    "Color.obWarning": {
      "light": [0.902, 0.761, 0.0, 1], "dark": [0.902, 0.718, 0.400, 1],
      "group": "Onboarding semantic", "usage": "Onboarding warning."
    },
    "Color.obError": {
      "light": [0.902, 0.145, 0.227, 1], "dark": [0.937, 0.486, 0.537, 1],
      "group": "Onboarding semantic", "usage": "Onboarding error."
    },
    "Color.obErrorSoft": {
      "light": [0.902, 0.145, 0.227, 0.1], "dark": [0.937, 0.486, 0.537, 0.16],
      "group": "Onboarding semantic", "usage": "Onboarding error wash."
    },
    "Color.obBorder": {
      "light": [0.541, 0.169, 0.886, 0.06], "dark": [0.722, 0.667, 0.839, 0.14],
      "group": "Onboarding borders", "usage": "Onboarding card borders."
    },
    "Color.firstRunTextTertiary": {"light": [0.4, 0.345, 0.502, 1], "dark": [0.627, 0.596, 0.714, 1], "group": "First-run Setup", "usage": "Setup quiet text (eyebrows, hints). Mockup t3, raised from obTextTertiary to pass 4.5:1 on obSurface and obCardBg in both modes."},
    "Color.firstRunSuccessText": {"light": [0.0, 0.459, 0.29, 1], "dark": [0.361, 0.788, 0.604, 1], "group": "First-run Setup", "usage": "Setup success text (key valid, checks). Mockup success-text, 4.5:1 on light cards."},
    "Color.firstRunErrorText": {"light": [0.784, 0.118, 0.192, 1], "dark": [0.937, 0.486, 0.537, 1], "group": "First-run Setup", "usage": "Setup error text (failed key check, download stopped). Mockup error-text, 4.5:1."},
    "Color.firstRunButtonHover": {"light": [0.169, 0.133, 0.251, 1], "dark": [0.486, 0.38, 0.871, 1], "group": "First-run Setup", "usage": "Setup primary button fill while hovered."},
    "Color.firstRunButtonDisabled": {"light": [0.89, 0.871, 0.925, 1], "dark": [0.212, 0.188, 0.278, 1], "group": "First-run Setup", "usage": "Setup primary button fill while it cannot be pressed."},
    "Color.firstRunButtonDisabledText": {"light": [0.435, 0.38, 0.537, 1], "dark": [0.604, 0.573, 0.69, 1], "group": "First-run Setup", "usage": "Text on firstRunButtonDisabled (4.26:1 in both modes; disabled controls are exempt from WCAG 1.4.3, kept readable)."},
    "Color.firstRunOnAccent": {"light": [1.0, 1.0, 1.0, 1], "dark": [0.082, 0.071, 0.11, 1], "group": "First-run Setup", "usage": "Text or icon on an obAccent fill (selected tab, step dot)."},
    "Color.firstRunAccentSoft": {"light": [0.486, 0.227, 0.929, 0.1], "dark": [0.655, 0.545, 0.98, 0.12], "group": "First-run Setup", "usage": "Setup accent wash (selected card, greeting bubble). Dark alpha 0.12 instead of obAccentSoft 0.16 so text on it keeps 4.5:1."},
    "Color.firstRunRule": {"light": [0.0, 0.0, 0.0, 0.1], "dark": [1.0, 1.0, 1.0, 0.12], "group": "First-run Setup", "usage": "Setup hairline (mockup --rule): unreached step-strip segments, dividers and keycap edges. obBorder (accent at 6%) is too faint for these."},
    "Color.firstRunFilmWallTop": {"light": [0.796, 0.725, 0.965, 1.0], "dark": [0.173, 0.137, 0.337, 1.0], "group": "First-run film (film scenes only)", "usage": "Closing film Mac desktop (#4528 chunk E): wallpaper gradient, top-left stop (mockup --wall, 160deg)."},
    "Color.firstRunFilmWallMid": {"light": [0.604, 0.722, 0.949, 1.0], "dark": [0.114, 0.169, 0.341, 1.0], "group": "First-run film (film scenes only)", "usage": "Film wallpaper gradient, middle stop at 55% (mockup --wall)."},
    "Color.firstRunFilmWallBottom": {"light": [0.953, 0.761, 0.855, 1.0], "dark": [0.231, 0.129, 0.251, 1.0], "group": "First-run film (film scenes only)", "usage": "Film wallpaper gradient, bottom-right stop (mockup --wall)."},
    "Color.firstRunFilmMenuBar": {"light": [1, 1, 1, 0.55], "dark": [0.118, 0.102, 0.157, 0.6], "group": "First-run film (film scenes only)", "usage": "Film menu bar fill over the wallpaper (mockup --menubar)."},
    "Color.firstRunFilmMenuInk": {"light": [0.114, 0.106, 0.133, 1.0], "dark": [0.933, 0.918, 0.957, 1.0], "group": "First-run film (film scenes only)", "usage": "Film menu bar text and the held-key label (mockup --menuink)."},
    "Color.firstRunFilmDock": {"light": [1, 1, 1, 0.45], "dark": [0.157, 0.141, 0.204, 0.55], "group": "First-run film (film scenes only)", "usage": "Film Dock shelf fill (mockup --dockbg)."},
    "Color.firstRunFilmLightRed": {"light": [1.0, 0.373, 0.341, 1.0], "dark": [1.0, 0.373, 0.341, 1.0], "group": "First-run film (film scenes only)", "usage": "Film active window close light (gen_film.py lights nth-child(1) #FF5F57)."},
    "Color.firstRunFilmLightYellow": {"light": [0.996, 0.737, 0.18, 1.0], "dark": [0.996, 0.737, 0.18, 1.0], "group": "First-run film (film scenes only)", "usage": "Film active window minimize light (gen_film.py lights nth-child(2) #FEBC2E)."},
    "Color.firstRunFilmLightGreen": {"light": [0.157, 0.784, 0.251, 1.0], "dark": [0.157, 0.784, 0.251, 1.0], "group": "First-run film (film scenes only)", "usage": "Film active window zoom light (gen_film.py lights nth-child(3) #28C840)."},
    "Color.firstRunFilmSlack": {"light": [0.29, 0.082, 0.294, 1.0], "dark": [0.29, 0.082, 0.294, 1.0], "group": "First-run film (film scenes only)", "usage": "Film Slack window sidebar (gen_film.py slack mwin #4A154B)."},
    "Color.firstRunFilmMistakeWash": {"light": [0.988, 0.337, 0.522, 0.11], "dark": [0.988, 0.337, 0.522, 0.11], "group": "First-run film (film scenes only)", "usage": "Film wash behind the misheard word (mockup #fc56851c)."},
    "Color.firstRunFilmMistakeText": {"light": [0.694, 0.153, 0.333, 1.0], "dark": [0.694, 0.153, 0.333, 1.0], "group": "First-run film (film scenes only)", "usage": "Film misheard word text (mockup #b12755)."},
    "Color.firstRunFilmMistakeStrike": {"light": [0.831, 0.263, 0.42, 1.0], "dark": [0.831, 0.263, 0.42, 1.0], "group": "First-run film (film scenes only)", "usage": "Film line through the misheard word (mockup #d4436b)."}
  },
  "fonts": {
    "Font.stSectionHeader": {
      "size": 14, "weight": "semibold",
      "usage": "Section eyebrow: uppercased label above a card or group (\"ON THIS MAC\")."
    },
    "Font.stRowTitle": {
      "size": 16, "weight": "semibold",
      "usage": "Row / control title: the lead line of a whole section/card (its subject, e.g. \"AI Polish\", an engine name). Used sparingly, one per section."
    },
    "Font.stRowLabel": {
      "size": 14, "weight": "semibold",
      "usage": "Sub-row / control label: the lead line of a control row inside a section (e.g. \"Language suggestions\"). Emphasis via weight, not a bigger size."
    },
    "Font.stBody": {
      "size": 14, "weight": "regular",
      "usage": "Reading-copy body: descriptions and multi-sentence explainers. Regular weight, primary (near-white) colour, one uniform size everywhere."
    },
    "Font.stHelper": {
      "size": 14,
      "usage": "Caption / hint / status microcopy: footnotes, link hints, status lines. Same 14pt floor as body; it reads quieter through colour, not size."
    },
    "Font.stRowHelper": {
      "size": 14,
      "usage": "A settings row's short grey line under its name (#3385). Held at the 14pt floor by founder decision (2026-10-02) rather than the mockup's 13px; kept as its own token so the row line has one owner."
    },
    "Font.obDisplay": {"size": 22, "weight": "heavy", "design": "rounded", "usage": "Onboarding step headline."},
    "Font.obSubheading": {"size": 14, "weight": "semibold", "usage": "Onboarding subheading and button text."},
    "Font.obBody": {"size": 14, "weight": "regular", "usage": "Onboarding body copy."},
    "Font.obCaption": {"size": 12, "weight": "regular", "usage": "Onboarding caption."},
    "Font.obCaptionSmall": {"size": 11, "weight": "regular", "usage": "Onboarding small caption."},
    "Font.obLabel": {"size": 13, "weight": "medium", "usage": "Onboarding label."},
    "Font.firstRunHero": {"size": 64, "weight": "heavy", "design": "rounded", "usage": "Setup big number (the speed card)."},
    "Font.firstRunDisplay": {"size": 28, "weight": "heavy", "design": "rounded", "usage": "Setup screen title."},
    "Font.firstRunTitle": {"size": 20, "weight": "heavy", "design": "rounded", "usage": "Setup card title and film caption title."},
    "Font.firstRunSay": {"size": 17, "weight": "semibold", "usage": "Setup practice sentence the person reads aloud."},
    "Font.firstRunBody": {"size": 15, "weight": "regular", "usage": "Setup reading copy under a title."},
    "Font.firstRunLabel": {"size": 15, "weight": "semibold", "usage": "Setup card name, option name and button text."},
    "Font.firstRunCaption": {"size": 13, "weight": "regular", "usage": "Setup card detail lines, hints and film caption subtitle."},
    "Font.firstRunEyebrow": {"size": 11, "weight": "semibold", "usage": "Setup uppercase eyebrow and badge (RECOMMENDED)."}
  },
  "layout": {
    "SettingsLayout.sectionRadius": {"value": 14, "usage": "Corner radius of a settings card."},
    "SettingsLayout.rowPaddingH": {"value": 14, "usage": "Horizontal padding inside a settings row."},
    "SettingsLayout.rowPaddingV": {"value": 12, "usage": "Vertical padding inside a settings row."},
    "SettingsLayout.sectionSpacing": {"value": 18, "usage": "Gap between settings cards."},
    "SettingsLayout.contentTop": {
      "value": 18, "usage": "Gap above the first content card.",
      "note": "Gap between the top bar and the first content card (the page-header card), so the bar reads as chrome and the header as the first content object."
    },
    "SettingsLayout.contentH": {"value": 24, "usage": "Page side margin."},
    "SettingsLayout.contentBottom": {"value": 32, "usage": "Page bottom margin."},
    "SettingsLayout.windowCardRadius": {
      "value": 18, "usage": "Corner radius of the two window frame cards.",
      "note": "Two-card window frame (#1296): the sidebar card and content card are each inset from the window edge by `windowFrameInset` and separated from one another by the same value, so the spacing reads uniform on all sides. Their corner radius is a touch larger than the inner setting cards so the frame cards clearly contain the content cards rather than competing with them."
    },
    "SettingsLayout.windowFrameInset": {"value": 14, "usage": "Inset of the frame cards from the window edge and from each other."},
    "SettingsPR1Layout.rowPaddingV": {
      "value": 10, "usage": "Dictation Settings dense row padding.",
      "note": "#3385: density belongs to Dictation Settings, not every shared consumer."
    },
    "SettingsPR1Layout.headingGap": {"value": 8, "usage": "Dictation Settings dense heading gap."},
    "DesignRadius.xs": {"value": 4, "usage": "Smallest radius."},
    "DesignRadius.sm": {"value": 6, "usage": "Small radius."},
    "DesignRadius.md": {"value": 8, "usage": "Default small surface (the most-used radius)."},
    "DesignRadius.lg": {"value": 10, "usage": "Medium-large radius."},
    "DesignRadius.xl": {"value": 12, "usage": "Large radius."},
    "DesignRadius.xxl": {"value": 16, "usage": "Largest scale radius."},
    "DesignSpacing.xxs": {"value": 2, "usage": "Hairline gaps."},
    "DesignSpacing.xs": {"value": 4, "usage": "Tight gaps inside a control."},
    "DesignSpacing.sm": {"value": 6, "usage": "Icon-to-label gaps."},
    "DesignSpacing.md": {"value": 8, "usage": "Default stack gap (the most-used spacing)."},
    "DesignSpacing.lg": {"value": 10, "usage": "Gap between related controls."},
    "DesignSpacing.xl": {"value": 12, "usage": "Gap between groups inside a card."},
    "DesignSpacing.xxl": {"value": 16, "usage": "Gap between unrelated blocks."},
    "DesignSpacing.xxxl": {"value": 24, "usage": "Page-level separation."}
  },
  "motion": {
    "DesignMotion.quick": {"curve": "easeInOut", "duration": 0.15, "usage": "Small state changes."},
    "DesignMotion.brisk": {"curve": "easeInOut", "duration": 0.25, "usage": "Short transitions."},
    "DesignMotion.standard": {"curve": "easeInOut", "duration": 0.3, "usage": "Default transition (the most-used duration)."},
    "DesignMotion.gentle": {"curve": "easeInOut", "duration": 0.35, "usage": "Larger panels appearing or moving."},
    "DesignMotion.firstRunScreenIn": {"curve": "timingCurve", "points": [0.22, 1, 0.36, 1], "duration": 0.32, "usage": "Setup screen entering (slide and fade).", "note": "The approved mockup's --ease-out, cubic-bezier(.22,1,.36,1): fast start, long settle."},
    "DesignMotion.firstRunRise": {"curve": "timingCurve", "points": [0.22, 1, 0.36, 1], "duration": 0.4, "usage": "Setup card, caption or check rising into place.", "note": "The approved mockup (the founder's source of truth, 2026-11-12) rises rows and cards with obRise 0.4s on cubic-bezier(.22,1,.36,1)."}
  }
}
```

## Colors

- **Light is light and airy; dark is night-comfort.** Dark is not a straight invert: low-chroma violet-neutral surfaces, off-white text capped below pure white, a desaturated lavender accent and muted status colors (#1047).
- **Two accent tokens (founder, 2026-07-03).** `stAccent` (lavender in dark) is for text and outlines only. A filled selected surface that carries white text uses `stAccentSolid`.
- **Status colors are semantic.** Use `stSuccess`, `stWarning`, `stError`, never raw `.red`, `.green` or `.orange`.
- **One control fill.** Every field, picker box and segmented track uses `stInputBg` with the `stInputBorder` hairline, so a typable field never looks like a label.
- **No default blue.** macOS settings use the brand accent purple, never the system blue.
- Onboarding uses the `ob*` family, which mirrors the Settings values.
- The first-run Setup window (#4528) uses the `firstRun*` family on top of `ob*` surfaces and accent: its type scale (11, 13, 15, 17, 20, 28, 64) and its contrast-raised quiet, success and error text come from the founder-approved Setup mockup. Meetings setup and other `ob*` screens keep their values.
- The closing film's picture of a Mac desktop (wallpaper, menu bar, Dock, traffic lights, a Slack sidebar, a misheard word) uses the `firstRunFilm*` group, copied from the approved Setup mockup. Film scenes only: no other screen uses these colors.

The founder reasons recorded with the palette and the type scale live in the values block under `reasons`, so the generator can repeat them in the Swift file.

## Typography

- SF Pro (system) only in the app. Plus Jakarta Sans is for the website and marketing.
- **14pt is the floor for every piece of Settings text (founder directive 2026-07-03).** Hierarchy is built UP from 14 with weight and the title size bump, never down with a smaller size.
- One small type scale, four roles, used across every Settings page: `stSectionHeader` (the uppercased eyebrow), `stRowTitle` (the lead line of a section), `stBody` (the reading copy), `stHelper` (captions, hints, status). `stRowLabel` and `stRowHelper` serve control rows.
- **Hierarchy comes from SIZE + WEIGHT, not colour.** Titles and body share the primary color, so a page never has a bright paragraph shouting over a dim title. Only helper text steps down to a quieter color.

## Layout and spacing

- The main window is two floating frame cards (sidebar and content) on a darker canvas, each inset `SettingsLayout.windowFrameInset` (14) from the window and from each other.
- A Settings page is `SettingsContentView` with `contentH` (24) side margins, `contentTop` (18) and `contentBottom` (32).
- Cards are separated by `sectionSpacing` (18). Rows pad `rowPaddingH` (14) by `rowPaddingV` (12), or 10 in the denser Dictation Settings.
- The minimum window width is 750pt. A settings row drops its control below its title when the row is too narrow (#3007).

## Corner sizes

Approved radii today, with their one owner each:

| Radius | Owner | Used for |
|---|---|---|
| 18 | `SettingsLayout.windowCardRadius` | The two window frame cards |
| 14 | `SettingsLayout.sectionRadius` | Settings cards |
| 10 | `BrandedSegmentedPicker` track | Choice bars |
| 9 | `SettingsHover.rowRadius` | Hover and selection pill on rows |
| 9 | `SettingsActionButton` rounded rectangle | Wizard buttons |
| 7 | `BrandedSegmentedPicker` segment | Selected choice segment |
| capsule | `SettingsActionButton`, status chips | Buttons and badges |

For any other surface use the `DesignRadius` scale (4, 6, 8, 10, 12, 16) in the values block. Other radii in the code are hand-typed and are being moved onto these owners (#4506 Phase 2). Do not add a new radius.

## Depth

- **Shadows are rare and soft.** The toggle knob uses a 15% black shadow; focus and selection use an accent-tinted shadow. No dramatic or black-heavy shadows.
- **No blur materials in Settings.** Surfaces are solid tokens.
- **Hover is a faint tint, never a jump.** Rows use `SettingsHover.rowTint` (accent at 6%), selected rows a white veil (10%), cards `SettingsHover.cardTint` (accent at 5%). Hover color is never suppressed by Reduce Motion; only the fade is.

## Gradients and the rainbow

- The rainbow spectrum (red, orange, gold, lime, spring, cyan, blue, royal, violet) is the brand signature. In the app it is reserved for the logo mark and the recording pill and HUD, never for reading surfaces.
- **Never put a rainbow or warm-to-cool gradient on text** (founder, 2026-06-18: "rainbow font just never looks good"). For emphasis use solid accent or weight.
- `Color.obRainbow` in `OnboardingDesignTokens.swift` is the app's rainbow gradient.

## Icons

- **SF Symbols only.** No custom icon files and no emoji as icons.
- **One symbol per meaning.** Use the symbol the app already uses for that meaning (the most-used meanings today):

| Meaning | Symbol |
|---|---|
| Warning | `exclamationmark.triangle` (`.fill` on a colored badge) |
| Close or dismiss | `xmark` (`xmark.circle.fill` inside a field) |
| Done or success | `checkmark.circle.fill` (`checkmark` inline) |
| Search | `magnifyingglass` |
| Retry or refresh | `arrow.clockwise` |
| Open a web page | `arrow.up.right` |
| Language | `globe` |
| Go deeper | `chevron.right` |
| AI polish | `sparkles` |
| Microphone | `mic` (`mic.slash` when muted or missing) |
| Add | `plus` |
| Copy | `doc.on.doc` |
| Export or share | `square.and.arrow.up`; import `square.and.arrow.down` |
| Help | `questionmark.circle`; more information `info.circle` |
| Delete | `trash` |

- A row's leading icon sits in `SettingsRowIcon`, which holds every glyph to one width so titles share a left edge.
- Decorative glyphs beside a label are hidden from VoiceOver (`.accessibilityHidden(true)`).

## Brand art

Each drawing has one owner file. Never redraw it elsewhere.

| Art | Owner |
|---|---|
| Logo mark (rainbow waveform) | `Sources/EnviousWisprAppKit/Views/Settings/WisprLogoMark.swift` (mirrors `website/public/favicon.svg`) |
| Rainbow lips icon | `Sources/EnviousWisprAppKit/App/Brand/RainbowLipsIcon.swift` |
| Rainbow lips (onboarding) | `Sources/EnviousWisprAppKit/Views/Onboarding/RainbowLipsView.swift` |
| Spectrum wheel | `Sources/EnviousWisprAppKit/App/Brand/SpectrumWheelIcon.swift` |
| Level meter | `Sources/EnviousWisprAppKit/App/Overlay/Views/RainbowLevelMeter.swift` |
| Chime waveform | `Sources/EnviousWisprAppKit/Views/Settings/RecordingChimeWaveform.swift` |

## Motion

- **One hover curve:** `SettingsHover.animation` (ease out, 0.12 s). Everything in the window fades at that speed.
- Other transitions use the `DesignMotion` scale (ease in-out 0.15, 0.25, 0.3, 0.35 s; 0.3 s is the default). The Setup window adds two entries on the approved mockup's curve, cubic-bezier(0.22, 1, 0.36, 1) (a `timingCurve` token with its points in the values block): `firstRunScreenIn` (0.32 s) and `firstRunRise` (0.4 s). Springs are used for physical movement, such as the switch knob.
- **Respect Reduce Motion.** Gate every animation on `accessibilityReduceMotion`; the state still changes, without the movement.

## Sound

- Recording chimes come in start and stop pairs, one pair per sound style (for example `softHush_start.wav` and `softHush_stop.wav`). A new sound style adds both files.
- Sound is optional feedback; nothing important is conveyed by sound alone.

## Approved parts

Use these. All live in `Sources/EnviousWisprAppKit/Views/Settings/SettingsComponents.swift` unless another file is named.

| Part | Use for | Never instead |
|---|---|---|
| `SettingsContentView` | The body of every Settings page | `Form`, a bare `ScrollView` |
| `BrandedSection` | A titled card of rows | Your own rounded rectangle card |
| `BrandedPanel` | A card with icon, header, description and footnote | A new header card |
| `BrandedRow` | One row inside a card, with its divider | Hand-padded `HStack`s |
| `SettingsRow` | A setting: icon, title, short grey line, `?` help, control | Your own row layout |
| `SettingsRowIcon` | The leading icon of a row | A bare `Image` |
| `SettingsSectionHeading` | An eyebrow above a group | Your own uppercased `Text` |
| `SettingsInfoButton` | The `?` help bubble | Hover-only tooltips |
| `SettingsHelpText`, `SettingsHelpArticleLink` | Help copy and a link to a help article | Custom links |
| `SettingsTabStrip` | Tabs across the top of a page | `TabView`, `Picker(.segmented)` |
| `BrandedSegmentedPicker` | A choice between 2-4 options | `Picker(.segmented)` |
| `BrandedToggleStyle` | Every on/off switch | `.toggleStyle(.switch)` |
| `BrandedSlider` | A slider with value badge and Low/High labels | A bare `Slider` |
| `SettingsActionButton` | Every Settings button (filled, outlined, quiet, destructive) | `.bordered`, `.borderedProminent`, `.plain` buttons |
| `SettingsSheetCloseButton` | The close X on a sheet | A second worded Cancel |
| `.settingsFieldChrome(focused:)` | Every text field on a Settings surface | `.textFieldStyle(.roundedBorder)` |
| `SettingsSummaryCard` | A summary with status and choices | A new summary card |
| `EngineCard` | An engine or model choice | A new choice card |
| `ProviderStatusChip` | A provider's status | Your own badge |
| `InsetNotice` | A quiet note inside a card | A new notice view |
| `WrappingHStack` | Chips or tags that wrap | Your own flow layout |
| `.settingsHoverRow(...)` (`SettingsHover.swift`) | Hover on a row or card | Your own `onHover` tint |
| `OnboardingButtonStyle` (`OnboardingDesignTokens.swift`) | The onboarding primary button | A new onboarding button |

A control must answer on the whole area it paints (`code-conventions.md` FACT: view-patterns).

## Do's and don'ts

- **Do** reuse the parts above and the tokens in the values block.
- **Do** check every screen in light and dark, at the 750pt minimum window width.
- **Don't** hand-type a color, corner size or font size.
- **Don't** use Apple's default control looks (grey bordered buttons, blue segmented pickers, rounded-border fields). The founder reviewed them side by side on 2026-11-11 and kept ours.
- **Don't** add the generic "AI look": gradient text, purple-to-blue hero washes, emoji as icons, identical cards with one shadow everywhere.
- **Don't** change how an approved part looks while building a feature. Ask first.
