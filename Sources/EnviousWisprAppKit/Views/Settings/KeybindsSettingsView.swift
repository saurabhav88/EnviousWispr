import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

/// Global hotkey configuration, laid out as a short setup flow (mockup #26):
/// pick a recording mode from two selectable cards, set the record key, then the
/// cancel key. The mode cards mirror the transcription-engine cards so the two
/// selectors read as one family; the hotkeys render as big edit buttons.
struct KeybindsSettingsView: View {
  @Environment(SettingsManager.self) private var settings
  @State private var showGlobeGuidance = false
  /// Where keyboard and VoiceOver focus must return when the guidance closes.
  @AccessibilityFocusState private var guidanceReturnFocus: Bool
  @FocusState private var recordingKeybindFocused: Bool

  /// Single dismissal path: closing the guidance ALWAYS returns focus to the
  /// control the user was operating, whichever way it was closed.
  private func dismissGlobeGuidance() {
    showGlobeGuidance = false
    recordingKeybindFocused = true
    guidanceReturnFocus = true
  }

  var body: some View {
    @Bindable var settings = settings

    SettingsContentView {
      // ── Transcribe keybind ───────────────────────────────────────────
      VStack(alignment: .leading, spacing: 10) {
        eyebrow("Transcribe Keybind")

        VStack(alignment: .leading, spacing: 16) {
          // Step 1 — recording mode as two selectable cards.
          VStack(alignment: .leading, spacing: 12) {
            stepLabel("1. Choose recording mode")

            LazyVGrid(
              columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
              spacing: 12
            ) {
              RecordingModeCard(
                icon: "hand.tap.fill",
                title: "Push to Talk",
                description: "Hold the keybind to record. Release to stop.",
                isSelected: settings.isPushToTalk
              ) {
                settings.recordingMode = .pushToTalk
              }
              RecordingModeCard(
                icon: "arrow.triangle.2.circlepath",
                title: "Toggle",
                description: "Press once to start recording. Press again to stop.",
                isSelected: !settings.isPushToTalk
              ) {
                settings.recordingMode = .toggle
              }
            }

            // Contextual tip: the multi-press gestures only exist in push-to-talk
            // mode, so it shows there and stays parity with the shipped copy.
            if settings.isPushToTalk {
              InsetNotice(
                text: "Double-press to lock it on. Triple-press to cancel."
              )
            }
          }

          Divider().overlay(Color.stDivider)

          // Step 2 — the record key as a big edit button.
          ProminentHotkeyRow(
            title: "2. Recording keybind",
            description: "This keybind starts and stops recording.",
            keyCode: $settings.toggleKeyCode,
            modifiers: $settings.toggleModifiers,
            role: .record,
            accessibilityLabel: "Recording keybind",
            onBindingAccepted: { code, _ in
              // The claim is owned by SettingsManager, not by this view: onboarding
              // has a separate completion handler and would otherwise show the same
              // explanation a second time.
              if settings.claimGlobeKeyGuidancePresentation(for: code) {
                showGlobeGuidance = true
              }
            }
          )
          // `.focusable()` is load-bearing, not belt-and-braces (#1987): the
          // keybind surface is a plain view with `onTapGesture`, deliberately not
          // a `Button`, so that a Button does not swallow the key events being
          // recorded. A non-focusable view accepts no keyboard focus, so binding
          // `@FocusState` to it alone would set a flag nothing honours and leave a
          // keyboard user stranded after the popover closed.
          .focusable()
          .focused($recordingKeybindFocused)
          .accessibilityFocused($guidanceReturnFocus)
          .popover(isPresented: $showGlobeGuidance, arrowEdge: .bottom) {
            GlobeGuidancePopover(onDismiss: dismissGlobeGuidance)
              // ONE dismissal path for both "Got it" and Escape (#1987). Relying on
              // AppKit's implicit Escape handling left focus wherever the popover
              // had taken it, which strands a keyboard or VoiceOver user: every
              // unit test still passed while the RSI persona this feature exists
              // for could be forced back to the pointer.
              .onExitCommand(perform: dismissGlobeGuidance)
          }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(SettingsCardSurface())
      }

      // ── Cancel recording ─────────────────────────────────────────────
      VStack(alignment: .leading, spacing: 10) {
        eyebrow("Cancel Recording")

        VStack(alignment: .leading, spacing: 14) {
          ProminentHotkeyRow(
            title: "Cancel keybind",
            // Conditional, because with Escape Recovery on the old sentence is
            // simply false — and a settings screen describing the opposite of
            // what the app does is worse than one saying nothing.
            // Deliberately NOT conditional on the live setting. The value
            // that decides what this key does is the one FROZEN when the
            // recording started, so a description that tracks the toggle is
            // wrong for the only reader who can see both at once: someone
            // flipping it while a recording runs.
            description:
              "Press to cancel the current recording. Escape Recovery below applies "
              + "from the next recording you start.",
            keyCode: $settings.cancelKeyCode,
            modifiers: $settings.cancelModifiers,
            role: .cancel,
            accessibilityLabel: "Cancel keybind"
          )

          Divider().opacity(0.6)

          // Founder-authored copy (plan §3.7), reproduced exactly. Three
          // constraints it keeps, each from a real finding: "your cancel
          // shortcut, Escape by default" and never a bare "Escape", because the
          // key is user-configurable; no mention of recording length, because no
          // length is refused; and "stays in History for 24 hours", never a
          // promise about a Mac that is powered off, because nothing deletes
          // files while the app is not running.
          Toggle(isOn: $settings.escapeRecoveryEnabled) {
            VStack(alignment: .leading, spacing: 4) {
              // `stRowLabel`, not `stRowTitle`: the tokens reserve the title for
              // one-per-section subjects, and this card's subject is already the
              // "Cancel Recording" eyebrow above.
              Text("Escape Recovery")
                .font(.stRowLabel)
                .foregroundStyle(.stTextPrimary)
              Text(
                """
                When you use your cancel keybind, Escape by default, EnviousWispr keeps the \
                dictation instead of discarding it. It finishes transcribing and polishing, then \
                offers to paste it. Another recording cannot start until that finishes, the same \
                as after any dictation. AI polish runs as usual, which uses your own API key when \
                configured. The audio is deleted once the text is saved; the text stays in \
                History for 24 hours unless you Keep it. The Cancel button still discards \
                immediately.
                """
              )
              // `stBody` at PRIMARY colour: the tokens define this as
              // reading-copy, and this is the disclosure a user has to actually
              // read before turning the feature on. Quieting it would be a
              // legibility choice made against the one paragraph that explains
              // what changes about their cancel key.
              .font(.stBody)
              .foregroundStyle(.stTextPrimary)
              .fixedSize(horizontal: false, vertical: true)
            }
          }
          .toggleStyle(.switch)
          .accessibilityLabel("Escape Recovery")
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(SettingsCardSurface())
      }

      // ── Quick Add (#2381) ────────────────────────────────────────────
      VStack(alignment: .leading, spacing: 10) {
        eyebrow("Add a Word")

        VStack(alignment: .leading, spacing: 14) {
          ProminentHotkeyRow(
            title: "Add-a-word keybind",
            // Says what the user DOES and what they get, in that order, and names
            // the one place it will not work rather than letting them discover it.
            // Terminals are out of scope because a highlight drawn by a terminal
            // program is not a selection anything outside it can read — a fact
            // about the terminal, not a limitation we chose, and one a user who
            // dictates into a terminal will otherwise hit and assume is a bug.
            description:
              "Select a misheard word anywhere, then press this to add it to Your Words. "
              + "Terminal windows do not share their selection, so it will not work there.",
            keyCode: $settings.quickAddKeyCode,
            modifiers: $settings.quickAddModifiers,
            role: .quickAdd,
            accessibilityLabel: "Add-a-word keybind"
          )
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(SettingsCardSurface())
      }
    }
  }

  // MARK: - Small text helpers

  /// The purple uppercase section eyebrow that sits above a card. Matches
  /// `BrandedSection`'s header treatment so this page reads with the rest.
  private func eyebrow(_ text: String) -> some View {
    Text(text.uppercased())
      .font(.stSectionHeader)
      .tracking(0.6)
      .foregroundStyle(.stAccent)
      .padding(.leading, 4)
  }

  /// A numbered step title inside the transcribe card.
  private func stepLabel(_ text: String) -> some View {
    Text(text)
      .font(.stRowTitle)
      .foregroundStyle(.stTextPrimary)
  }
}

// MARK: - Card surface

/// The standard setting-card surface (fill, radius, hairline border) as a
/// modifier so this page's hand-built cards match `BrandedSection` exactly.
private struct SettingsCardSurface: ViewModifier {
  func body(content: Content) -> some View {
    content
      .background(Color.stSectionBg)
      .clipShape(RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius))
      .overlay(
        RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius)
          .strokeBorder(Color.stDivider, lineWidth: 1)
      )
  }
}

// MARK: - Recording mode card

/// One selectable recording-mode option: a lavender icon tile, a check/radio
/// badge, a title, and a two-line description, laid out as a square card. The
/// selected card carries the accent border and a filled accent check badge.
/// Mirrors the transcription-engine cards so the two selectors read as a family.
private struct RecordingModeCard: View {
  let icon: String
  let title: String
  let description: String
  let isSelected: Bool
  let onSelect: () -> Void

  var body: some View {
    Button(action: onSelect) {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .top) {
          Image(systemName: icon)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.stAccent)
            .frame(width: 44, height: 44)
            .background(Color.stAccentLight, in: RoundedRectangle(cornerRadius: 11))
            .overlay(
              RoundedRectangle(cornerRadius: 11)
                .strokeBorder(Color.stAccent.opacity(0.28), lineWidth: 1)
            )
            .accessibilityHidden(true)
          Spacer(minLength: 8)
          if isSelected {
            Image(systemName: "checkmark.circle.fill")
              .font(.system(size: 20, weight: .semibold))
              .foregroundStyle(Color.white, Color.stAccentSolid)
          } else {
            Circle()
              .strokeBorder(Color.stDivider, lineWidth: 1.5)
              .frame(width: 20, height: 20)
          }
        }

        VStack(alignment: .leading, spacing: 4) {
          Text(title)
            .font(.stRowTitle)
            .foregroundStyle(isSelected ? .stAccent : .stTextPrimary)
          Text(description)
            .font(.stHelper)
            .foregroundStyle(.stTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .background(Color.stSectionBg)
      .clipShape(RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius))
      .overlay(
        RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius)
          .strokeBorder(
            isSelected ? Color.stAccent : Color.stDivider,
            lineWidth: isSelected ? 2 : 1)
      )
      // Inside the label, where the padding and `background` already are, so the
      // tint cannot outgrow the region the `Button` responds on.
      .settingsHoverCard(
        cornerRadius: SettingsLayout.sectionRadius, isSelected: isSelected)
    }
    .buttonStyle(.plain)
    .animation(.easeInOut(duration: 0.15), value: isSelected)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(title)
    .accessibilityValue(isSelected ? "Selected" : "")
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
  }
}

// MARK: - Prominent hotkey row

/// A hotkey control laid out as the mockup's two-column row: a title and
/// description on the left, a big edit button on the right that shows the current
/// key with a "Click to change" affordance.
private struct ProminentHotkeyRow: View {
  let title: String
  let description: String
  @Binding var keyCode: UInt16
  @Binding var modifiers: NSEvent.ModifierFlags
  /// Which shortcut this row edits. **The row derives its Reset default from this rather than being
  /// handed one**, so no call site has a default to get wrong.
  ///
  /// Three review rounds found the same defect one member at a time — a hard-coded number, then the
  /// same number surviving in a full-line comment, then in a trailing one — because a guard over
  /// source text is a DESCRIPTION of a set and the next counterexample always exists.
  ///
  /// Precisely what this buys, since "unwriteable" would be an overclaim: a literal is still
  /// writeable HERE, in the two accessors below. What is gone is a literal at each of three CALL
  /// SITES, where it applies to one row, reads as ordinary, and drifts alone. One here would apply
  /// to every row at once, which is the difference between a quiet wrong default and an obvious one.
  let role: ShortcutRole
  let accessibilityLabel: String

  private var defaultKeyCode: UInt16 { role.defaultKeyCode }
  private var defaultModifiers: NSEvent.ModifierFlags { role.defaultModifiers }
  /// #1987 — nil on rows that are not the recording keybind, so only the toggle
  /// row can ever present the Globe guidance.
  var onBindingAccepted: ((UInt16, NSEvent.ModifierFlags) -> Void)?

  var body: some View {
    HStack(alignment: .center, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.stRowTitle)
          .foregroundStyle(.stTextPrimary)
        Text(description)
          .settingsReadingCopy()
      }
      Spacer(minLength: 12)
      HotkeyRecorderView(
        keyCode: $keyCode,
        modifiers: $modifiers,
        defaultKeyCode: defaultKeyCode,
        defaultModifiers: defaultModifiers,
        label: accessibilityLabel,
        style: .prominent,
        onBindingAccepted: { code, mods in onBindingAccepted?(code, mods) }
      )
      .frame(width: 260)
    }
  }
}

// MARK: - Globe key guidance (#1987)

/// The one-time "free up the Globe key" explanation, shared by Settings and
/// onboarding so both surfaces render identical copy.
///
/// Accessibility is load-bearing here, not decoration: the persona this feature
/// exists for is an RSI user whose card demands no modals. Shipping an
/// ergonomics feature behind a pointer-only dialog would be self-defeating. So the
/// dismiss control is a real focusable `Button`, the container carries one spoken
/// label, and the decorative step numbers are hidden from VoiceOver so it reads
/// the instructions rather than the bullets.
///
/// Escape is handled EXPLICITLY by each host through `.onExitCommand`, not by
/// AppKit's default popover dismissal. The default closes the popover and leaves
/// focus wherever it had taken it, so a keyboard user is dropped nowhere; the
/// hosts route both Escape and the button through one dismissal that restores
/// focus to the keybind control.
struct GlobeGuidancePopover: View {
  let onDismiss: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(GlobeKeyCopy.title)
        .font(.stRowTitle)
        .foregroundStyle(.stTextPrimary)

      Text(GlobeKeyCopy.body)
        .settingsReadingCopy()

      VStack(alignment: .leading, spacing: 6) {
        ForEach(Array(GlobeKeyCopy.steps.enumerated()), id: \.offset) { index, step in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(index + 1).")
              .foregroundStyle(.stTextTertiary)
              .accessibilityHidden(true)
            Text(step).settingsReadingCopy()
          }
        }
      }

      Text(GlobeKeyCopy.reassurance)
        .settingsReadingCopy()

      HStack {
        Spacer()
        Button(GlobeKeyCopy.dismissButton, action: onDismiss)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(18)
    .frame(width: 340)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(GlobeKeyCopy.accessibilityLabel)
  }
}
