# Screen Atlas Inventory

One section per picture in `atlas.json`, named by its id (`## <id>`); the pictures are `pictures/<id>-light.png` and `pictures/<id>-dark.png`. Exact on-screen wording is quoted. Read `README.md` first. Written from the pictures and the Settings Map; refresh a section when its picture changes.

# Settings pages

Each picture is the whole page, top to bottom, at the 820pt window (a 578pt page area, without the sidebar; see `hand-window-dictation` for the frame). Built by `SettingsMapRenderingTests` fixtures with isolated stores, so sample data is fixed. Searchable names come from the Settings Map (`reference/settings-map.json`).

## page-aiPolish-egOne
**AI Polish > EG-1 on this Mac.** Turns AI Polish on and picks the polish model. In this picture EG-1 runs on this Mac and you pick its size.
- **Top to bottom:** Enable AI Polish row, MODEL ("Changes apply to the next recording") with the EG-1 summary card, "EG-1 · choose a size" ("This Mac: 64 GB memory") with three size cards, WHY USE EG-1 help text.
- **Controls:** Enable AI Polish: switch (on). Size cards: EG-1 ("Best quality", badge "Best for this Mac", selected), EG-1 Mini ("Fast all-rounder"), EG-1 Micro ("Smallest and fastest"), each "Not downloaded".
- **Buttons:** Change (outlined, up/down chevrons), Download (filled, on EG-1), Download (outlined, on EG-1 Mini and EG-1 Micro).
- **Parts:** BrandedSection, BrandedToggleStyle, SettingsSectionHeading, SettingsSummaryCard, EngineCard, SettingsHelpText.
- **Fixture state:** EG-1 chosen with a "Recommended" badge, "Not installed", no size downloaded.

## page-aiPolish-off
**AI Polish > not set up.** The AI Polish page with polish switched off.
- **Top to bottom:** one card, Enable AI Polish ("Fixes grammar, punctuation and formatting"), then empty page.
- **Controls:** Enable AI Polish: switch (off).
- **Buttons:** none.
- **Parts:** BrandedSection, BrandedToggleStyle.
- **Fixture state:** AI Polish off, so the model sections are hidden.

## page-aiPolish-openAI-savedKey
**AI Polish > OpenAI with a saved key.** AI Polish set to the OpenAI cloud model, with an API key already saved.
- **Top to bottom:** Enable AI Polish row, MODEL ("Changes apply to the next recording") with the OpenAI "Cloud" summary card, "OPENAI · only for this model" card with OpenAI API Key and Model rows, WHY USE OPENAI help text.
- **Controls:** Enable AI Polish: switch (on). OpenAI API Key: secure field (dots) with eye toggle. Model: dropdown (disabled until the key is saved) with a refresh icon button.
- **Buttons:** Change (outlined, chevrons), Save (quiet, disabled), Clear (destructive), links "Get your free API key at platform.openai.com" and "OpenAI rate limits by tier".
- **Parts:** BrandedSection, BrandedToggleStyle, SettingsSectionHeading, SettingsSummaryCard, SettingsRow, SettingsRowIcon, .settingsFieldChrome, SettingsHelpText, SettingsHelpArticleLink.
- **Fixture state:** saved key, status "Not checked", no models listed yet.

## page-appSettings-appearance
**App Settings > Appearance.** Sets the app's theme, interface language, Dock icon and menu bar update alert.
- **Top to bottom:** tab strip (Appearance, Permissions, Privacy, Licenses; Appearance selected), APPEARANCE.
- **Controls:** Theme: choice bar (System, Light, Dark; System selected). Language: dropdown "System default". Show app in Dock: switch (on). Update alert in menu bar: switch (on).
- **Buttons:** none besides the ? help buttons.
- **Parts:** SettingsTabStrip, SettingsSectionHeading, BrandedSection, SettingsRow, SettingsRowIcon, SettingsInfoButton, BrandedSegmentedPicker, BrandedToggleStyle.

## page-appSettings-licenses
**App Settings > Licenses.** Shows the app's open source license and third-party notices.
- **Top to bottom:** tab strip (Licenses selected), ABOUT.
- **Controls:** rows "EnviousWispr · GPLv3" ("Open source under the GNU GPL version 3.") and "Third-Party Notices" ("Licenses for the tools EnviousWispr uses.").
- **Buttons:** View license (outlined), View notices (outlined).
- **Parts:** SettingsTabStrip, SettingsSectionHeading, BrandedSection, SettingsRow, SettingsRowIcon, SettingsInfoButton.

## page-appSettings-permissions
**App Settings > Permissions.** Shows whether the app may use the microphone and Accessibility.
- **Top to bottom:** tab strip (Permissions selected), PERMISSIONS.
- **Controls:** Microphone ("Needed to record your voice.") and Accessibility ("Needed to paste text into other apps."), each with a green "Allowed" status chip.
- **Buttons:** none besides the ? help buttons.
- **Parts:** SettingsTabStrip, SettingsSectionHeading, BrandedSection, SettingsRow, SettingsRowIcon, SettingsInfoButton.
- **Fixture state:** both permissions allowed.

## page-appSettings-privacy
**App Settings > Privacy.** Controls usage metrics and crash reports and explains what is collected.
- **Top to bottom:** tab strip (Privacy selected), PRIVACY.
- **Controls:** Share usage metrics: switch (on). Send crash reports: switch (on). What we collect: text row ("Never your audio, text, history, snippets, dictionary or API keys...").
- **Buttons:** See details (quiet, with outward arrow).
- **Parts:** SettingsTabStrip, SettingsSectionHeading, BrandedSection, SettingsRow, SettingsRowIcon, SettingsInfoButton, BrandedToggleStyle.

## page-diagnostics
**Diagnostics.** Developer tools (Debug builds only): debug switches, log files, system logging and benchmarks.
- **Top to bottom:** DEBUG MODE, PILL PREVIEW, LOG FILES, OSLOG, PERFORMANCE.
- **Controls:** Enable debug mode: switch (off). Use tuned on-device adapter (PoC): switch (on). Save dictation audio for debugging: switch (off). Pill review mode: switch (off). Log path text. "Model status:" with value "Unloaded". Rows have no icons and no ? buttons.
- **Buttons:** stock macOS buttons (grey fill, not the Settings button part): Open Log Directory, Copy Log Path, Open Console.app, Run ASR Benchmark, Run Pipeline Benchmark; Clear Logs in red text.
- **Parts:** SettingsSectionHeading, BrandedSection, BrandedRow, BrandedToggleStyle.
- **Fixture state:** adapter note says "EW_AFM_ADAPTER_PATH not set".

## page-dictation-chimes
**Dictation > Chimes.** Turns recording chimes on and picks which chime plays.
- **Top to bottom:** two-row tab strip (Engine, Microphone, Live Preview, Recording Pill / Chimes, Clipboard; Chimes selected), RECORDING CHIMES, caption "Hear this chime without changing your choice.", two-column chime grid.
- **Controls:** Play recording chimes: switch (on). Chime cards with waveform: Dust Mote, Velvet Hush, Muted Confirm, Whisper Tick, Round Pebble, Paper Tap, Soft Hush, Low Nod, Cloud Pop, Velvet Tap, Satin Shift, Air Glint. Whisper Tick is selected with an "IN USE" badge.
- **Buttons:** round filled play button on each chime card.
- **Parts:** SettingsTabStrip, SettingsSectionHeading, SettingsRow, SettingsRowIcon, SettingsInfoButton, BrandedToggleStyle.

## page-dictation-clipboard
**Dictation > Clipboard.** Sets how dictation uses and restores the clipboard.
- **Top to bottom:** tab strip (Clipboard selected), CLIPBOARD ("Changes apply to the next recording"), QUICK ADD.
- **Controls:** Auto-copy to clipboard: switch (on). Restore clipboard after paste: switch (on). Hide dictations from clipboard manager apps: switch (off). Smart insertion: switch (on). Read selections through the clipboard: switch (on).
- **Buttons:** none besides the ? help buttons.
- **Parts:** SettingsTabStrip, SettingsSectionHeading, BrandedSection, SettingsRow, SettingsRowIcon, SettingsInfoButton, BrandedToggleStyle.

## page-dictation-engine
**Dictation > Engine.** Picks the transcription engine and sets language and text cleanup options.
- **Top to bottom:** tab strip (Engine selected), TRANSCRIPTION ENGINE ("Changes apply to the next recording") with the "Fast Parakeet v3" summary card, FAST · PARAKEET V3, APPLIES TO BOTH ENGINES.
- **Controls:** Auto-detect language: switch (off). English: language row. Faster Transcription: switch (off). Stop recording on silence: off. Remove filler words (um, uh, hmm...): on. Convert spoken emoji (e.g. "thumbs up emoji" → 👍): on. Spoken punctuation: off. Casual mode: off. Unload model after: dropdown "Never".
- **Buttons:** Change (outlined, engine card), Change (small quiet, English row), Reset suggestions (link), refresh icon.
- **Parts:** SettingsTabStrip, SettingsSectionHeading, SettingsSummaryCard, BrandedSection, SettingsRow, SettingsRowIcon, SettingsInfoButton, BrandedToggleStyle.
- **Fixture state:** "Checking model status...".

## page-dictation-livePreview
**Dictation > Live Preview.** Shows words on screen while you speak and picks the preview engine and languages.
- **Top to bottom:** tab strip (Live Preview selected), LIVE PREVIEW ("Runs on this Mac. Nothing you say is sent anywhere."), PREVIEW ENGINE, LANGUAGES ("1 of 2 installed on this Mac").
- **Controls:** Show words while you speak: switch (on) with green "Ready" status; dropdown "English / you picked this". Engine summary card: Apple ("Uses language packs supplied by macOS.", "Ready"), Universal ("This version of EnviousWispr cannot run that preview engine."). Install new languages: row with chevron.
- **Buttons:** Change (outlined), Compare engines (link, outward arrow).
- **Parts:** SettingsTabStrip, SettingsSectionHeading, BrandedSection, SettingsRow, SettingsRowIcon, SettingsInfoButton, BrandedToggleStyle, SettingsSummaryCard.
- **Fixture state:** Universal engine unavailable in this build.

## page-dictation-microphone
**Dictation > Microphone.** Picks the microphone and sets what media does and how long the mic stays ready.
- **Top to bottom:** tab strip (Microphone selected), INPUT & BEHAVIOR (with mic icon, "Changes apply to the next recording").
- **Controls:** Input device: dropdown "Choose a microphone / Auto". Media during dictation: choice bar (Continue, Lower, Mute, Pause; Continue selected). Microphone readiness: choice bar (Off, 10 sec, 30 sec, 60 sec, Always; 30 sec selected). Using a Bluetooth microphone?: text row.
- **Buttons:** Learn more (outlined, chevron).
- **Parts:** SettingsTabStrip, SettingsSectionHeading, BrandedSection, SettingsRow, SettingsRowIcon, SettingsInfoButton, BrandedSegmentedPicker.

## page-dictation-pill
**Dictation > Recording Pill.** Sets where the floating recording pill sits and what it shows.
- **Top to bottom:** tab strip (Recording Pill selected), RECORDING PILL.
- **Controls:** Position on screen: choice bar (Top, Bottom; Top selected). Style: three picture cards, Capsule, Level Rail, Reading Well (Reading Well selected with check mark).
- **Buttons:** Configure Live Preview (link).
- **Parts:** SettingsTabStrip, SettingsSectionHeading, BrandedSection, SettingsRow, SettingsRowIcon, SettingsInfoButton, BrandedSegmentedPicker.

## page-dictionary-learnFrom
**Dictionary > Learn From.** Lets the app learn new words from your corrections and your Contacts.
- **Top to bottom:** LEARN FROM... (with icon) and intro line, Self-Learning Dictionary card, Import from Contacts card.
- **Controls:** Self-Learning Dictionary ("Beta" tag): switch (on, dimmed). Keep in sync on launch: switch (off).
- **Buttons:** Learn more (link, outward arrow), Import (outlined).
- **Parts:** SettingsSectionHeading, BrandedToggleStyle.
- **Fixture state:** only the tab content is shown; "Not available on this version of macOS yet" and "Learn-only: This polish choice doesn't use learned words yet."

## page-dictionary-quickAdd
**Dictionary > Quick Add.** Explains how to add a highlighted word to the dictionary from any app.
- **Top to bottom:** numbered step cards 1 Highlight a word, 2 Trigger Quick Add, 3 Choose and save, then info cards Keyboard shortcut ("^⇧ W. Change it under Keybinds.") and Menu bar.
- **Controls:** none.
- **Buttons:** none.
- **Parts:** none of the approved parts are clearly recognisable.
- **Fixture state:** only the tab content is shown, without the Dictionary header or side list.

## page-dictionary-vocabularyPacks
**Dictionary > Vocabulary Packs.** Turns on ready-made word lists for a field.
- **Top to bottom:** VOCABULARY PACKS (with icon) and intro line, five pack cards.
- **Controls:** pack cards with switch (all off): Tech (76 fixes), Medical (87 fixes), Legal (32 fixes), Brands (106 fixes), Names (90 fixes).
- **Buttons:** See all (outlined) on each card.
- **Parts:** SettingsSectionHeading, BrandedToggleStyle.
- **Fixture state:** only the tab content is shown.

## page-dictionary-yourWords-withWords
**Dictionary > Your Words (with words).** Lists, searches and edits the words you added to the dictionary.
- **Top to bottom:** DICTIONARY with Enable Dictionary switch, intro line, side list (Your Words selected, Vocabulary Packs, Learn from..., Quick Add), "Switching from another dictation app?" card, 13 WORDS card with toolbar, category chips and word list.
- **Controls:** Enable Dictionary: switch (on). Search field "Search by word, mish..." (truncated). Category chips: All categories (selected), General, Person, Brand, Acronym, Domain, Auto-learned. Word list rows (word plus category).
- **Buttons:** Add word (filled), Import (outlined), Export your words (outlined), Mass edit (outlined), Edit (outlined) per row, chevron on the switching card.
- **Parts:** SettingsSectionHeading, SettingsInfoButton, BrandedToggleStyle, WrappingHStack, .settingsFieldChrome.
- **Fixture state:** 13 sample words (API, ChatGPT, Claude, CLI, EG-1, Envious, Envious Labs, EnviousWispr, GitHub, iOS, macOS, OpenAI, VS Code).

## page-keybinds
**Keybinds.** Sets the recording mode and the keyboard shortcuts.
- **Top to bottom:** RECORDING, SHORTCUTS.
- **Controls:** Recording mode: choice bar (Push to Talk, Toggle; Push to Talk selected). Shortcut fields: Start / stop recording ("Right ⌥"), Cancel recording ("Escape"), Add selected word to Dictionary ("^⇧ W"), Paste last dictation ("^⌘ V"), Copy last dictation ("^⌘ C"). Escape Recovery: switch (on).
- **Buttons:** Change (quiet, inside each shortcut field).
- **Parts:** SettingsSectionHeading, BrandedSection, SettingsRow, SettingsRowIcon, SettingsInfoButton, BrandedSegmentedPicker, BrandedToggleStyle.

## page-meetings-callApps
**EnviousMeet > Call Apps.** Chooses which call apps EnviousMeet watches for calls.
- **Top to bottom:** "EnviousMeet" title with BETA badge, two-row tab strip (General, Models, Summaries, Call Apps / Permissions; Call Apps selected), Notice calls in card, footnote "EnviousMeet checks for calls on your Mac and never sends this anywhere."
- **Controls:** Notice calls in: list of apps with switches (all on): Zoom, Microsoft Teams, FaceTime, Slack, Meetings in a browser.
- **Buttons:** none besides the ? help button.
- **Parts:** SettingsTabStrip, BrandedSection, SettingsRow, SettingsRowIcon, SettingsInfoButton, BrandedToggleStyle.

## page-meetings-general
**EnviousMeet > General.** Sets what happens when a call starts and how meetings are recorded.
- **Top to bottom:** EnviousMeet title with BETA badge, tab strip (General selected), settings card, recording notes text, recording laws notice, footer text.
- **Controls:** When a call starts: choice bar (Off, Ask, Start by itself; Ask selected). Record only my voice: switch (off). Turn off dictation during meetings: switch (off). Leave my voice out when I'm muted: switch (on). Name meetings from my calendar: switch (off).
- **Buttons:** Show recordings (link).
- **Parts:** SettingsTabStrip, BrandedSection, SettingsRow, SettingsRowIcon, SettingsInfoButton, BrandedSegmentedPicker, BrandedToggleStyle, InsetNotice.

## page-meetings-models
**EnviousMeet > Models.** Picks the engines and languages for meeting Live Preview, transcripts and speaker labels.
- **Top to bottom:** EnviousMeet title, tab strip (Models selected), LIVE PREVIEW, TRANSCRIPT ENGINE, TRANSCRIPT LANGUAGE, SPEAKER LABELS.
- **Controls:** Choose an engine: engine cards Apple (dimmed, "Not on this Mac. Needs macOS 26.") and Universal (Whisper Small, 270 MB, 100 languages, Apple GPU). Transcript engine summary card: Parakeet. Auto-detect language: switch (on). Transcript language: "Auto".
- **Buttons:** Keep current Live Preview engine (link), Change (outlined), Download (stock macOS button, grey fill, twice), Change (stock, disabled).
- **Parts:** SettingsTabStrip, SettingsSectionHeading, EngineCard, SettingsSummaryCard, BrandedSection, SettingsRow, SettingsRowIcon, SettingsInfoButton, BrandedToggleStyle.
- **Fixture state:** engine chooser open, "Checking" statuses, Whisper Large v3 Turbo and Speaker labels ("Needs a download") not downloaded.

## page-meetings-permissions
**EnviousMeet > Permissions.** Shows and fixes the permissions EnviousMeet needs.
- **Top to bottom:** EnviousMeet title, tab strip (Permissions selected), one permissions card.
- **Controls:** Microphone ("Allowed"), Call sound permission, Calendar ("Not asked yet. Turn on Name meetings from my calendar to ask."), Accessibility ("Not allowed. EnviousMeet can't notice calls until you allow it.").
- **Buttons:** Open System Settings and Allow Accessibility (stock macOS buttons, grey fill, not the Settings button part).
- **Parts:** SettingsTabStrip, BrandedSection, SettingsRow, SettingsRowIcon, SettingsInfoButton.
- **Fixture state:** Accessibility not allowed, Calendar not asked.

## page-meetings-summaries
**EnviousMeet > Summaries.** Turns meeting summaries on and picks the engine that writes them.
- **Top to bottom:** EnviousMeet title, tab strip (Summaries selected), Write a summary card, summary engine card.
- **Controls:** Write a summary when a meeting ends: switch (on). Engine cards with radio circles: EG-1 (On this Mac), Apple Intelligence (On this Mac), Ollama (Your own setup), OpenAI (Cloud), Google Gemini (Cloud), Claude (Cloud).
- **Buttons:** Keep current summary engine (link).
- **Parts:** SettingsTabStrip, BrandedSection, SettingsRow, SettingsRowIcon, SettingsInfoButton, BrandedToggleStyle, EngineCard.
- **Fixture state:** "No summary engine chosen", engine chooser open.

## page-snippets
**Snippets.** Saves text you paste often and inserts it when you say a keyword and trigger.
- **Top to bottom:** "Switching from another dictation app?" card, "Paste the text you type over and over, by voice" card with Keyword row, YOUR SNIPPETS ("6 snippets") with toolbar and list.
- **Controls:** Keyword: field "backslash". Search snippets: field. Snippet list rows with "Example" tag and chevron: my email, my phone, my address, my calendar, my signature, my intro.
- **Buttons:** Import (outlined), Export (outlined), Add snippet (filled), chevron on the switching card.
- **Parts:** BrandedPanel, SettingsSectionHeading, SettingsInfoButton, .settingsFieldChrome.
- **Fixture state:** six example snippets.

## page-transcribeFile
**Transcribe a File.** Uploads an audio or video file to transcribe and polish it.
- **Top to bottom:** step bar (1 Upload, 2 Transcription, 3 Polish, 4 Review, 5 Working, 6 Done; Upload selected), "Transcribe a File" header card, dashed drop zone, four feature tiles (Your voice stays here, Two transcription engines, Six ways to polish, Original kept), footer band "Secure. Private. Local."
- **Controls:** drop zone with "or drag and drop here" and Supported formats chips: m4a, mp3, wav, aiff, caf, mp4, mov, flac.
- **Buttons:** Choose a file (filled).
- **Parts:** BrandedPanel, WrappingHStack.
- **Fixture state:** empty, no file chosen.

# Recording pill

The pill floats over other apps while you dictate. Three designs exist; the user picks one in Dictation > Recording Pill, where they are named Capsule, Level Rail and Reading Well (code names `.classic`, `.levelRail`, `.readingWell`). Swift: `RecordingOverlayView` (`App/Overlay/Views/RecordingOverlayView.swift`), chrome `OverlayCapsuleBackground`. Fixture for every pill picture: level 0.4, 2:07 elapsed. Only Reading Well can show words (`RecordingPillDesign.canHoldWords`).

## pill-classic-rest
**Capsule, recording.** Dark capsule, 185pt frame: rainbow lips (they move with your voice) on the left, the clock in monospaced white on the right, a faint rainbow line along the bottom edge.

## pill-classic-locked
**Capsule, locked (hands-free).** The clock disappears and the lips grow to twice their size in a small round capsule.

## pill-classic-notice
**Capsule, with a notice.** The capsule grows to carry a short white sentence under the lips and clock. Sample: "Secure Input is on, so some keyboard features are paused".

## pill-readingWell-rest
**Reading Well, recording.** A 400pt rounded panel: clock on the left, a dotted rainbow level rail, "LISTENING" on the right. Light panel in light mode, dark in dark mode.

## pill-readingWell-locked
**Reading Well, locked (hands-free).** Same panel; "LISTENING" is replaced by a grey "HANDS-FREE" chip with a dot.

## pill-readingWell-words
**Reading Well, with words.** The panel grows downward and shows the words as you speak, in regular text under the clock row. Sample: "Let's move the design review to Thursday afternoon and invite the whole team."

## pill-readingWell-waiting
**Reading Well, words on, none yet.** The panel before the first words arrive.

## pill-readingWell-notice
**Reading Well, with a notice.** The notice sentence sits in a second line under the clock row.

## pill-levelRail-rest
**Level Rail, recording.** A wide dark capsule: clock on the left, a dotted rainbow level rail with a purple end mark, no lips.

## pill-levelRail-locked
**Level Rail, locked.** Adds a quiet "Hands-free" tag on the right.

## pill-levelRail-notice
**Level Rail, with a notice.** The capsule grows to carry the notice sentence under the clock and rail.

# Pill notices

Short messages that take the pill's place after or around a recording. Built from the app's own catalog (`PillCatalog`, `App/Overlay/PillCatalog.swift`), so size and wording are what users see. Leaf views live in `App/Overlay/Views/`. Other reasons reuse one of these looks with different words (`DictationNarrator` owns the sentences).

## notice-processing-transcribing
**Transcribing.** Dark capsule, spinning rainbow wheel, "Transcribing...". `PolishingOverlayView`.

## notice-processing-polishing
**Polishing.** Same look, "Polishing...". Shown while AI Polish runs.

## notice-clipboard-fallback
**Copied to clipboard.** Rainbow wheel, "Copied. Press ⌘V to paste". Shown when the text could not be pasted.

## notice-accessibility-toast
**Accessibility needed.** Orange shield icon, "Auto-paste needs Accessibility", orange "Grant" button. `AccessibilityToastView`.

## notice-warning-polish-failed
**Warning.** Orange warning triangle, "Pasted without AI polish." `NotificationOverlayView` (warning style).

## notice-error-capture
**Error.** Red x circle, "Audio capture error. Try again." `NotificationOverlayView` (error style).

## notice-advisory-zero-signal
**Advisory.** Muted microphone icon and a three-line explanation ("Audio isn't capturing. Your lid may be closed, ..."). `NotificationOverlayView` (multiline).

## notice-interruption-device-removed
**Interrupted.** Red lips and orange "Microphone disconnected." on the dark capsule with a red edge. `DistressCapsuleBackground`.

## notice-caching-model
**Preparing a model.** Rainbow wheel, "Getting dictation ready...", subtitle "Parakeet is warming up after a restart". `ColdStartNoticeView` (spinner).

## notice-engine-ready
**Engine ready.** Green check, "Ready, press to dictate" (the app writes it with a dash). `ColdStartNoticeView` (ready).

## notice-recovering
**Recovering last recording.** Grey spinner, "Recovering your last recording...", subtitle "Anything saved lands in History", "Discard" button. `RecoveryNoticeView`.

## notice-recovery-succeeded
**Recovery succeeded.** Green check, "Recovered your last recording", subtitle "Saved to History".

## notice-bluetooth
**Bluetooth microphone.** A tall card (light in light mode, dark in dark mode): title "Bluetooth mic detected", three tips with round icons, a filled purple "Got it" button and an "Adjust settings" link, close X top right, rainbow line on the bottom edge.

## notice-escape-recovery
**Escape Recovery.** "Dictation cancelled" with an "Undo" capsule button and a short countdown line along the bottom left. `CorrectionLearnedPillView` family.

## notice-import-status
**Import status.** Arrows icon, "Importing your words now. Check progress on the Dictionary page." `ImportStatusOverlayView`.

## notice-correction-learned
**Word learned.** "Added “Tuist” to Dictionary" with an "Undo" capsule button and the countdown line. `CorrectionLearnedPillView`.

## notice-language-chip
**Language chip.** Globe icon, "Detected Spanish. Lock it?", a filled blue "Lock" button and a quiet "Dismiss" button. `LanguageChipView`.

# Logos

Use the files in `logos/`; never redraw a mark. Each SVG names its Swift owner.

## logo-lips
**Rainbow lips, at rest.** 9 upper and 9 lower rounded bars in the rainbow, mirrored colors. The pill's mark. SVG: `logos/lips.svg`. Swift: `RainbowLipsIcon`.

## logo-lips-open
**Rainbow lips, speaking.** The same bars stretched apart as at audio level 0.4. SVG: `logos/lips-open.svg`.

## logo-logo-mark
**Logo mark.** The rainbow waveform mark in the Settings sidebar (the website favicon adds a glow; the app does not). SVG: `logos/logo-mark.svg`. Swift: `WisprLogoMark`.

## logo-envious-meet
**EnviousMeet mark.** Apple's two-people-with-sound-waves symbol (`person.2.wave.2`, semibold) filled with the rainbow gradient. Picture only. Swift: `MeetingRainbowLogo`.

## logo-menu-bar-idle
**Menu bar icon, idle.** The lips bars in one dark tone; macOS turns it light in a dark menu bar. 22pt. SVG: `logos/menu-bar-idle.svg`. Swift: `MenuBarIconAnimator`.

## logo-menu-bar-recording
**Menu bar icon, recording.** The lips bars in full rainbow. SVG: `logos/menu-bar-recording.svg`.

# Parts sheets

Every approved part on one sheet, from `DesignPartsSheets` (`Tests/EnviousWisprTests/Design/DesignPartsSheets.swift`).

## parts-structure
**Cards, rows, headings.** Section heading with icon; titled card (BrandedSection) with a settings row (icon, title, "?" help, short grey line, switch), a row with icon and help button, help text and a "Read the help article" link; a panel (BrandedPanel) with an inset notice; status chips Ready, Needs setup, Not available, Error and a headline chip; a row with the hover modifier at rest.

## parts-controls
**Tabs, choices, switches, fields, buttons.** Tab strip (Engine selected, underline), choice bars (Casual, Neutral, Formal; Always, Continue), switches on, off, self-disabled and parent-disabled, a slider with value badge and Low/High labels, a text field and a focused field (2pt accent border); buttons filled "Download", outlined "Test", quiet "Back", destructive "Delete", each enabled, self-disabled and parent-disabled; wizard pair "Back" and large "Continue →"; outlined "Preview" with a play glyph; decorative button; close X; onboarding "Onboarding continue". Known: outlined capsule buttons show slightly flattened side edges (open founder item, #4506 plan §14).

## parts-cards
**Summary and engine cards.** A summary card (bolt icon tile, "Fast Parakeet v3", description, "Change" button, "Ready" status) and two engine cards: "Fast" selected (accent border, check badge) and "All Languages" not selected, each with Model and Runs on facts.

# Hand photos

Taken from the running dev app because the photo test cannot set these screens up. Refresh by hand.

## hand-window-dictation
**Full window, Dictation Settings > Engine.** The main window as users see it (1512 x 863 pt here). Manual photo, refresh by hand (2026-11-12, v2.6.0).
- **Title bar:** traffic lights, the EnviousWispr name with the small rainbow mark in the middle, and on the right a gift button (What's New menu, `WhatsNewMenuView`), a bug button on a light purple tile (Send Feedback, `FeedbackToolbarButton`) and a filled purple "Record" button with a microphone glyph.
- **Sidebar card (left):** logo mark, "EnviousWispr" with a "v2.6.0" tag, a "Search settings" field, then History, RECORD (Dictation Settings, Keybinds, Transcribe a File, EnviousMeet with a BETA tag), PROCESS (AI Polish, Dictionary, Snippets), SYSTEM (App Settings, Diagnostics). The selected row is a filled purple pill with white text.
- **Content card (right):** the Settings page (`page-dictation-engine`), on the page background, inset from the window edge like the sidebar card.
- **Swift:** `UnifiedWindowView` (`Views/Settings/SettingsView.swift`); the sidebar is a `ScrollView` of button rows. Frame: `SettingsLayout.windowFrameInset` and `windowCardRadius`.

## hand-history
**History.** The default page: past dictations. Manual photo, refresh by hand (2026-11-12). Dictation text is blurred for privacy.
- **Layout:** the window frame with the sidebar (History selected), a middle column and a detail area.
- **Middle column:** "Search history" field with the item count, a filter bar A / D / T / M (All, Dictation, Transcribe a File, Meetings), a status card (Engine, model name and state; AI Polish, model), then dictation cards newest first. Each card: date and time in monospaced type, the text, and tags (Dictation, the polish model such as eg-1, the engine such as Parakeet). "Delete all history" (destructive link with trash glyph) at the bottom.
- **Detail area:** with nothing selected, a microphone glyph, "Ready to Transcribe", "Press the record button to start dictating." and the record keybind.
- **Swift:** `SettingsSection` drives History; the photo test cannot stage it (it needs saved records and many services).

## hand-menu-bar-menu
**Menu bar menu.** The menu from the lips icon in the macOS menu bar. Manual photo, refresh by hand (2026-11-12). It follows the macOS appearance, so only a dark photo exists. The last dictation preview line is blurred for privacy.
- **Items top to bottom:** engine and polish model (greyed, e.g. "Parakeet Ultra — EG-1"), "Version: 2.6.0" (greyed); Open EnviousWispr; Start Recording, Transcribe a File..., Start Meeting Recording; Add to Dictionary (^⇧W), Paste Last Dictation (^⌘V) with the last dictation's first words under it; Microphone ›, Appearance ›; Help Center, Check for Updates...; Quit EnviousWispr (⌘Q).
- **Swift:** `MenuBarController`.
