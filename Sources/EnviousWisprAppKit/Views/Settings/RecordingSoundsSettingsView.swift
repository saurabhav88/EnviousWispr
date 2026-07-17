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
  // Shared across every card in the grid (#1618, Codex code-diff review r6):
  // each card previously owned its own preview task, so previewing card B
  // while card A's delayed stop was still pending only cancelled A's task
  // from WITHIN card A — B never knew A existed, producing an interleaved
  // A-start/B-start/A-stop/B-stop sequence instead of a clean switch. One
  // shared slot, passed down by binding, means starting any card's preview
  // always cancels whatever the grid's previous preview was, regardless of
  // which card it belonged to.
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
      }

      LazyVGrid(columns: columns, spacing: 12) {
        ForEach(RecordingSoundPairing.allCases, id: \.self) { pairing in
          RecordingSoundPairingCard(
            pairing: pairing,
            isSelected: settings.recordingSoundPairing == pairing,
            previewDisabled: liveRecordingState.isDictationActive,
            activePreviewTask: $activePreviewTask
          ) {
            settings.recordingSoundPairing = pairing
          }
        }
      }
    }
    .onDisappear {
      // A card's own .onChange (below) only guards the race while that card is
      // still on screen. This is a plain Task in @State, not a `.task {}`
      // modifier, so SwiftUI does NOT auto-cancel it when the page goes away:
      // leaving Sounds mid-preview would otherwise let the delayed stop cue
      // fire later, after a real recording that started and finished entirely
      // during the 550ms wait, on a page nobody is looking at anymore (Codex
      // code-diff review r7, #1618). Page-level, not per-card: a card
      // scrolling out of the lazy grid must not cancel an in-progress preview.
      activePreviewTask?.cancel()
    }
  }
}

// MARK: - Pairing card

/// One selectable sound pairing with a name, one-line description, and one
/// Preview control. Selection and Preview are two REAL, independent,
/// non-overlapping `Button`s stacked vertically — never nested inside one
/// another (SwiftUI buttons must not nest, Grounded Review r3, #1342), and
/// never geometrically overlapping (a wider, single interactive region
/// covering both was tried and reverted twice: once because a plain gesture
/// cannot be assumed to lose priority to a nested Button, Codex code-diff
/// review r5, and once because a custom Text+gesture control loses keyboard
/// focusability and reintroduces cross-card preview bleed, Codex code-diff
/// review r6). Both risks are structurally impossible when the two controls
/// are real, disjoint Buttons: there is no shared touch point for gesture
/// priority to arbitrate, and each keeps native focus/VoiceOver for free.
/// The trade-off, accepted: the outer card's padding margin and the small
/// gap between the two buttons are not part of either button's hit area.
private struct RecordingSoundPairingCard: View {
  // Own environment read (not just the parent's snapshotted `previewDisabled`
  // below): the delayed stop half inside the Preview action needs the LIVE
  // value at the moment it fires, a Bool captured at tap time would be stale
  // for that later check (#1618 plan §3, Codex grounded review r1).
  @Environment(LiveRecordingState.self) private var liveRecordingState

  let pairing: RecordingSoundPairing
  let isSelected: Bool
  let previewDisabled: Bool
  // Shared across the whole grid via binding (Codex code-diff review r6),
  // not a per-card @State: starting ANY card's preview must cancel whatever
  // the grid's previous preview was, even if it belonged to a different
  // card, or switching cards mid-preview produces two interleaved,
  // overlapping start/stop sequences instead of a clean handoff.
  @Binding var activePreviewTask: Task<Void, Never>?
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(name)
      .accessibilityValue(isSelected ? "Selected" : "")
      .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)

      Button("Preview", action: startPreview)
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
        activePreviewTask?.cancel()
      }
    }
  }

  private func startPreview() {
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
