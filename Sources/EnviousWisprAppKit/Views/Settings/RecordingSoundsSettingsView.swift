import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

/// Optional recording start/stop sound settings: a master toggle plus an
/// ordered picker of original sound pairings, each previewable as one
/// sequence.
struct RecordingSoundsSettingsView: View {
  @Environment(SettingsManager.self) private var settings
  // #1342 (Codex code-diff review r6): previews must not be tappable while a
  // recording is in flight — an open Settings window during dictation would
  // otherwise let a user inject an unbounded number of tones into someone
  // else's active transcript, unlike the feature's own bounded start/stop
  // cues. Reuses the existing dictation-activity signal already injected
  // into other Settings pages (DiagnosticsSettingsView) rather than adding
  // new state.
  @Environment(LiveRecordingState.self) private var liveRecordingState

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
      }

      LazyVGrid(columns: columns, spacing: 12) {
        ForEach(RecordingSoundPairing.allCases, id: \.self) { pairing in
          RecordingSoundPairingCard(
            pairing: pairing,
            isSelected: settings.recordingSoundPairing == pairing,
            previewDisabled: liveRecordingState.isDictationActive
          ) {
            settings.recordingSoundPairing = pairing
          }
        }
      }
    }
  }
}

// MARK: - Pairing card

/// One selectable sound pairing with a name, one-line description, and one
/// Preview control. The WHOLE card is the selection target (a real `Button`);
/// Preview is a smaller control layered inside it, so it cannot be a second
/// `Button` (SwiftUI buttons must not nest, Grounded Review r3, #1342) and
/// its tap priority cannot rely on default gesture-resolution order between
/// an ancestor Button and a descendant control (unreliable — Codex code-diff
/// review r5: "SwiftUI buttons do not reliably consume an ancestor's tap
/// gesture"). Preview uses `.highPriorityGesture`, the documented, guaranteed
/// mechanism for "this control's tap wins over any ancestor's," instead.
private struct RecordingSoundPairingCard: View {
  // Own environment read (not just the parent's snapshotted `previewDisabled`
  // below): the delayed stop half inside the Preview action needs the LIVE
  // value at the moment it fires, a Bool captured at tap time would be stale
  // for that later check (#1618 plan §3, Codex grounded review r1).
  @Environment(LiveRecordingState.self) private var liveRecordingState
  // Retained so a real recording that starts AND finishes entirely within
  // the 550ms preview delay can still be caught: a point-in-time check alone
  // (isDictationActive read only when the delayed stop is about to fire)
  // misses that case, since the real session may have already ended by
  // then. The .onChange below cancels this the MOMENT any real recording
  // starts, closing the window instead of racing it (Codex code-diff r2).
  @State private var previewTask: Task<Void, Never>?

  let pairing: RecordingSoundPairing
  let isSelected: Bool
  let previewDisabled: Bool
  let onSelect: () -> Void

  var body: some View {
    Button(action: onSelect) {
      VStack(alignment: .leading, spacing: 10) {
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 8) {
            Text(name)
              .font(.stRowTitle)
              .foregroundStyle(isSelected ? .stAccent : .stTextPrimary)
            Spacer()
            if isSelected {
              Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.white, Color.stAccent)
            }
          }
          Text(description)
            .settingsReadingCopy()
            .frame(maxWidth: .infinity, minHeight: 20, alignment: .topLeading)
        }

        previewControl
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(name)
    .accessibilityValue(isSelected ? "Selected" : "")
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    .padding(14)
    .background(Color.stSectionBg)
    .clipShape(RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius))
    .overlay(
      RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius)
        .strokeBorder(isSelected ? Color.stAccent : Color.stDivider, lineWidth: isSelected ? 2 : 1)
    )
    .animation(.easeInOut(duration: 0.15), value: isSelected)
    .onChange(of: liveRecordingState.isDictationActive) { _, isActive in
      // Closes the window rather than racing it: cancel the pending preview
      // the MOMENT a real recording starts, so a real session that starts
      // AND finishes entirely inside the 550ms delay can never leave a
      // stale preview stop cue armed (Codex code-diff review r2).
      if isActive {
        previewTask?.cancel()
      }
    }
  }

  /// Styled to read as a small bordered button, but built from a plain
  /// `Text` + `.highPriorityGesture`, not a real `Button` — see the type's
  /// doc comment for why. `.highPriorityGesture` is what makes this reliably
  /// win over the card's own selection `Button` for taps landing here.
  private var previewControl: some View {
    Text("Preview")
      .font(.system(size: 12, weight: .medium))
      .foregroundStyle(previewDisabled ? Color.stTextTertiary : Color.stAccent)
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .background(
        RoundedRectangle(cornerRadius: 6)
          .strokeBorder(previewDisabled ? Color.stDivider : Color.stAccent.opacity(0.4))
      )
      .contentShape(Rectangle())
      .highPriorityGesture(TapGesture().onEnded(startPreview))
      .accessibilityLabel("Preview \(name)")
      .accessibilityAddTraits(.isButton)
      .accessibilityAction(.default, startPreview)
      .help(
        previewDisabled
          ? "Preview is unavailable while a recording is in progress."
          : "")
  }

  /// Shared by the mouse-driven `.highPriorityGesture` and VoiceOver's
  /// `.accessibilityAction` so the two activation paths can never drift out
  /// of sync with each other.
  private func startPreview() {
    guard !previewDisabled else { return }
    previewTask?.cancel()
    previewTask = Task { @MainActor in
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

  private var name: String {
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

  private var description: String {
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
}
