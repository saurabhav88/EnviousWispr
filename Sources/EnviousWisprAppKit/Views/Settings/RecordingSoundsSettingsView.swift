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
/// Preview control. The selection button and Preview button are SIBLINGS,
/// never nested inside one another (Grounded Review r3: SwiftUI buttons must
/// not nest).
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
    VStack(alignment: .leading, spacing: 10) {
      Button(action: onSelect) {
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
        // Without this, a plain-style button's tap target is only the
        // rendered glyphs (the text), not the full card area — the Spacer
        // and any empty space around short text becomes dead space you can
        // click without anything happening. This makes the whole rectangle
        // tappable (founder-reported, 2026-07-17).
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(name)
      .accessibilityValue(isSelected ? "Selected" : "")
      .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)

      Button("Preview") {
        previewTask?.cancel()
        previewTask = Task { @MainActor in
          guard RecordingSoundCue.play(pairing: pairing, moment: .start) else { return }
          do {
            try await Task.sleep(for: .milliseconds(550))
          } catch {
            return  // cancelled mid-wait; do not play a stop half for a start that may be stale
          }
          // Re-check immediately before firing stop, belt-and-suspenders
          // alongside the .onChange cancellation below: a real recording may
          // have started during the 550ms wait (the global hotkey works
          // while Settings is open). Firing the preview's stop cue into a
          // live recording would falsely signal that real dictation just
          // stopped (council finding, 2026-07-17; both GPT-5.6 and
          // Gemini-3.1 independently caught this race). Reads the LIVE
          // environment value here, not the render-time `previewDisabled`
          // snapshot.
          guard !Task.isCancelled, !liveRecordingState.isDictationActive else { return }
          RecordingSoundCue.play(pairing: pairing, moment: .stop)
        }
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .foregroundStyle(.stAccent)
      .accessibilityLabel("Preview \(name)")
      .disabled(previewDisabled)
      .help(
        previewDisabled
          ? "Preview is unavailable while a recording is in progress."
          : "")
    }
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
