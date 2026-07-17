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

        BrandedRow(showDivider: false) {
          HStack(spacing: 8) {
            Text("Selected: \(displayName(for: settings.recordingSoundPairing))")
              .settingsReadingCopy()
            Spacer()
            Button("Preview", action: startPreview)
              .buttonStyle(.bordered)
              .controlSize(.small)
              .foregroundStyle(.stAccent)
              .accessibilityLabel("Preview \(displayName(for: settings.recordingSoundPairing))")
              .disabled(liveRecordingState.isDictationActive)
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
    .animation(.easeInOut(duration: 0.15), value: isSelected)
    .accessibilityLabel(displayName(for: pairing))
    .accessibilityValue(isSelected ? "Selected" : "")
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
  }
}

// MARK: - Catalog copy

private func displayName(for pairing: RecordingSoundPairing) -> String {
  switch pairing {
  case .dustMote: return "Dust Mote"
  case .velvetHush: return "Velvet Hush"
  case .mutedConfirm: return "Muted Confirm"
  case .whisperTick: return "Whisper Tick"
  case .roundPebble: return "Round Pebble"
  case .paperTap: return "Paper Tap"
  case .softHush: return "Soft Hush"
  case .lowNod: return "Low Nod"
  case .cloudPop: return "Cloud Pop"
  case .velvetTap: return "Velvet Tap"
  case .satinShift: return "Satin Shift"
  case .airGlint: return "Air Glint"
  }
}

private func description(for pairing: RecordingSoundPairing) -> String {
  switch pairing {
  case .dustMote: return "Soft filtered air, no tone."
  case .velvetHush: return "Two close tones, gentle warmth."
  case .mutedConfirm: return "Same pitch both ways, plain."
  case .whisperTick: return "Barely-there tick."
  case .roundPebble: return "Rounded, no edge."
  case .paperTap: return "Soft paper-like tap."
  case .softHush: return "Slow fade, like a breath."
  case .lowNod: return "Low, warm, unhurried."
  case .cloudPop: return "Tiny filtered-air pop."
  case .velvetTap: return "Muted, compact tap."
  case .satinShift: return "Smooth two-tone shift."
  case .airGlint: return "Clean, airy glint."
  }
}
