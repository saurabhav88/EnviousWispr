import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

/// Optional recording start/stop sound settings: a master toggle, an ordered
/// picker of sound pairings (tap a card anywhere to select it), and one
/// Preview control for the currently selected pairing.
struct RecordingSoundsSettingsView: View {
  @Environment(SettingsManager.self) private var settings
  // #1342 (Codex code-diff review r6): preview must not be tappable while a
  // recording is in flight — an open Settings window during dictation would
  // otherwise let a user inject an unbounded number of tones into someone
  // else's active transcript, unlike the feature's own bounded start/stop
  // cues. Reuses the existing dictation-activity signal already injected
  // into other Settings pages (DiagnosticsSettingsView) rather than adding
  // new state.
  @Environment(LiveRecordingState.self) private var liveRecordingState
  @State private var activePreviewTask: Task<Void, Never>?

  private let columns = [GridItem(.adaptive(minimum: 210, maximum: .infinity), spacing: 12)]

  var body: some View {
    @Bindable var settings = settings

    SettingsContentView {
      // Its own card, unchanged from before Preview existed — nesting the
      // Preview row inside this same card read as one control bleeding into
      // another (founder direction, 2026-07-17).
      BrandedSection(header: "Sounds") {
        BrandedRow(showDivider: false) {
          HStack(alignment: .top, spacing: 11) {
            SettingsRowIcon(systemName: "bell.and.waveform")
            VStack(alignment: .leading, spacing: 4) {
              Toggle(isOn: $settings.playRecordingSounds) {
                Text("Play recording sounds").settingsRowLabel()
              }
              .toggleStyle(BrandedToggleStyle())
              Text(
                "Plays a short sound when recording starts and stops. People nearby may hear it."
              )
              .settingsReadingCopy()
            }
          }
        }
      }

      // A second, separate card for Preview — its own visual home, not a row
      // tucked inside the toggle's card.
      BrandedSection {
        BrandedRow(showDivider: false) {
          HStack(alignment: .center, spacing: 11) {
            SettingsRowIcon(systemName: "play.circle.fill")
            VStack(alignment: .leading, spacing: 4) {
              Text("Preview").settingsRowLabel()
              Text("Selected: \(displayName(for: settings.recordingSoundPairing))")
                .settingsReadingCopy()
            }
            Spacer()
            // This one genuinely disables while a recording runs, and the
            // system prominent style renders grey on a settings page, so the
            // enabled and disabled states were the same pixels on the only
            // control in the row.
            SettingsActionButton(
              title: "Preview",
              isEnabled: !liveRecordingState.isDictationActive,
              emphasis: .filled,
              systemImage: "play.fill",
              action: startPreview
            )
            .accessibilityLabel("Preview \(displayName(for: settings.recordingSoundPairing))")
            .help(
              liveRecordingState.isDictationActive
                ? "Preview is unavailable while a recording is in progress."
                : "")
          }
        }
      }

      // Each card is ONE full-surface Button: tapping anywhere on it, edge to
      // edge, selects that pairing. Preview lives outside the grid (above)
      // instead of inside each card, deliberately — a card that has to
      // support two different tap behaviors (select vs. preview) kept
      // reintroducing dead zones and focus/gesture-priority bugs across three
      // rounds of review (Codex code-diff reviews r5/r6, #1618). One surface,
      // one behavior, removes that whole class of bug (founder direction,
      // 2026-07-17).
      LazyVGrid(columns: columns, spacing: 12) {
        ForEach(RecordingSoundPairing.allCases, id: \.self) { pairing in
          RecordingSoundPairingCard(
            pairing: pairing,
            isSelected: settings.recordingSoundPairing == pairing
          ) {
            settings.recordingSoundPairing = pairing
          }
        }
      }
    }
    .onDisappear {
      // This is a plain Task in @State, not a `.task {}` modifier, so SwiftUI
      // does NOT auto-cancel it when the page goes away: leaving Sounds
      // mid-preview would otherwise let the delayed stop cue fire later,
      // after a real recording that started and finished entirely during the
      // 550ms wait, on a page nobody is looking at anymore (Codex code-diff
      // review r7, #1618).
      activePreviewTask?.cancel()
    }
    .onChange(of: liveRecordingState.isDictationActive) { _, isActive in
      // Closes the window rather than racing it: cancel the pending preview
      // the MOMENT a real recording starts, so a real session that starts
      // AND finishes entirely inside the 550ms delay can never leave a stale
      // preview stop cue armed (Codex code-diff review r2).
      if isActive {
        activePreviewTask?.cancel()
      }
    }
  }

  private func startPreview() {
    let pairing = settings.recordingSoundPairing
    activePreviewTask?.cancel()
    activePreviewTask = Task { @MainActor in
      // `.cancel()` only sets a flag; it does not stop this closure from
      // starting. Dictation can start (or the page can disappear) in the gap
      // between task creation and this first line running, so without this
      // check the start cue could still play into a just-started real
      // recording (Codex code-diff review r12, #1618).
      guard !Task.isCancelled, !liveRecordingState.isDictationActive else { return }
      guard RecordingSoundCue.play(pairing: pairing, moment: .start) else { return }
      do {
        try await Task.sleep(for: .milliseconds(550))
      } catch {
        return  // cancelled mid-wait; do not play a stop half for a start that may be stale
      }
      // Re-check immediately before firing stop, belt-and-suspenders
      // alongside the .onChange cancellation above: a real recording may
      // have started during the 550ms wait (the global hotkey works while
      // Settings is open). Firing the preview's stop cue into a live
      // recording would falsely signal that real dictation just stopped
      // (council finding, 2026-07-17; both GPT-5.6 and Gemini-3.1
      // independently caught this race). Reads the LIVE environment value
      // here, not a render-time snapshot.
      //
      // Codex code-diff review r9 additionally flagged that SwiftUI can
      // coalesce a real recording that starts AND fully finishes within this
      // same wait, so neither guard above observes it, and the stop cue
      // plays a moment after a real (already-finished) recording rather than
      // during one. Explicitly NOT defended further (rejected a 25ms poll
      // loop that would have run for the life of every preview): the
      // consequence is one extra soft click after a recording that already
      // ended cleanly, on an optional, off-by-default limb — founder called
      // this disproportionate machinery for the residual risk, 2026-07-17.
      guard !Task.isCancelled, !liveRecordingState.isDictationActive else { return }
      RecordingSoundCue.play(pairing: pairing, moment: .stop)
    }
  }
}

// MARK: - Pairing card

/// One selectable sound pairing: name, one-line description, selection ring.
/// The entire card is a single `Button` — no second interactive region
/// inside it (see `RecordingSoundsSettingsView` for why Preview lives
/// outside the grid instead).
private struct RecordingSoundPairingCard: View {
  let pairing: RecordingSoundPairing
  let isSelected: Bool
  let onSelect: () -> Void

  var body: some View {
    Button(action: onSelect) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(displayName(for: pairing))
            .font(.stRowTitle)
            .foregroundStyle(isSelected ? .stAccent : .stTextPrimary)
          Spacer()
          if isSelected {
            Image(systemName: "checkmark.circle.fill")
              .font(.system(size: 16, weight: .semibold))
              .foregroundStyle(Color.white, Color.stAccent)
          }
        }
        Text(description(for: pairing))
          .settingsReadingCopy()
          .frame(maxWidth: .infinity, minHeight: 20, alignment: .topLeading)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(14)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(Color.stSectionBg)
    .clipShape(RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius))
    .overlay(
      RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius)
        .strokeBorder(isSelected ? Color.stAccent : Color.stDivider, lineWidth: isSelected ? 2 : 1)
    )
    // Safe to hang off the card rather than the label here: the comment above
    // this type records that the ENTIRE card is one `Button` with no second
    // interactive region inside it, so the card's bounds and the hit region are
    // already the same rectangle.
    .settingsHoverCard(cornerRadius: SettingsLayout.sectionRadius, isSelected: isSelected)
    .animation(.easeInOut(duration: 0.15), value: isSelected)
    .accessibilityLabel(displayName(for: pairing))
    .accessibilityValue(isSelected ? SettingsCopy.selectedValue : "")
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
  }
}

private func displayName(for pairing: RecordingSoundPairing) -> String {
  switch pairing {
  case .dustMote:
    return String(
      localized: "Dust Mote",
      comment:
        "Sounds settings: a recording sound's name. A playful name; translate its feel, or keep it."
    )
  case .velvetHush:
    return String(
      localized: "Velvet Hush",
      comment:
        "Sounds settings: a recording sound's name. A playful name; translate its feel, or keep it."
    )
  case .mutedConfirm:
    return String(
      localized: "Muted Confirm",
      comment:
        "Sounds settings: a recording sound's name. A playful name; translate its feel, or keep it."
    )
  case .whisperTick:
    return String(
      localized: "Whisper Tick",
      comment:
        "Sounds settings: a recording sound's name. A playful name; translate its feel, or keep it."
    )
  case .roundPebble:
    return String(
      localized: "Round Pebble",
      comment:
        "Sounds settings: a recording sound's name. A playful name; translate its feel, or keep it."
    )
  case .paperTap:
    return String(
      localized: "Paper Tap",
      comment:
        "Sounds settings: a recording sound's name. A playful name; translate its feel, or keep it."
    )
  case .softHush:
    return String(
      localized: "Soft Hush",
      comment:
        "Sounds settings: a recording sound's name. A playful name; translate its feel, or keep it."
    )
  case .lowNod:
    return String(
      localized: "Low Nod",
      comment:
        "Sounds settings: a recording sound's name. A playful name; translate its feel, or keep it."
    )
  case .cloudPop:
    return String(
      localized: "Cloud Pop",
      comment:
        "Sounds settings: a recording sound's name. A playful name; translate its feel, or keep it."
    )
  case .velvetTap:
    return String(
      localized: "Velvet Tap",
      comment:
        "Sounds settings: a recording sound's name. A playful name; translate its feel, or keep it."
    )
  case .satinShift:
    return String(
      localized: "Satin Shift",
      comment:
        "Sounds settings: a recording sound's name. A playful name; translate its feel, or keep it."
    )
  case .airGlint:
    return String(
      localized: "Air Glint",
      comment:
        "Sounds settings: a recording sound's name. A playful name; translate its feel, or keep it."
    )
  }
}

private func description(for pairing: RecordingSoundPairing) -> String {
  switch pairing {
  case .dustMote:
    return String(
      localized: "Soft filtered air, no tone.",
      comment: "Sounds settings: describes how a recording sound sounds.")
  case .velvetHush:
    return String(
      localized: "Two close tones, gentle warmth.",
      comment: "Sounds settings: describes how a recording sound sounds.")
  case .mutedConfirm:
    return String(
      localized: "Same pitch both ways, plain.",
      comment: "Sounds settings: describes how a recording sound sounds.")
  case .whisperTick:
    return String(
      localized: "Barely-there tick.",
      comment: "Sounds settings: describes how a recording sound sounds.")
  case .roundPebble:
    return String(
      localized: "Rounded, no edge.",
      comment: "Sounds settings: describes how a recording sound sounds.")
  case .paperTap:
    return String(
      localized: "Soft paper-like tap.",
      comment: "Sounds settings: describes how a recording sound sounds.")
  case .softHush:
    return String(
      localized: "Slow fade, like a breath.",
      comment: "Sounds settings: describes how a recording sound sounds.")
  case .lowNod:
    return String(
      localized: "Low, warm, unhurried.",
      comment: "Sounds settings: describes how a recording sound sounds.")
  case .cloudPop:
    return String(
      localized: "Tiny filtered-air pop.",
      comment: "Sounds settings: describes how a recording sound sounds.")
  case .velvetTap:
    return String(
      localized: "Muted, compact tap.",
      comment: "Sounds settings: describes how a recording sound sounds.")
  case .satinShift:
    return String(
      localized: "Smooth two-tone shift.",
      comment: "Sounds settings: describes how a recording sound sounds.")
  case .airGlint:
    return String(
      localized: "Clean, airy glint.",
      comment: "Sounds settings: describes how a recording sound sounds.")
  }
}
