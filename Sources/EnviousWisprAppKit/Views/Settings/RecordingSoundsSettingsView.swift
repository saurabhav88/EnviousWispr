import CoreAudio
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
  // #1413: the other-audio hold answers "can the current speakers carry this
  // mode" and raises the players' consent prompt at choice time.
  @Environment(DictationRuntime.self) private var dictationRuntime
  @State private var activePreviewTask: Task<Void, Never>?
  @State private var unavailableNote: String?
  /// #1413: the default-output listener that keeps the availability note honest
  /// when the user switches speakers with the page open. A read/observe, not a
  /// desktop effect; released with the page.
  @State private var outputListener: AudioObjectPropertyListenerBlock?

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

      // #1413: what happens to everything else your Mac is playing while you
      // dictate. Off by default; a change applies to the next take.
      BrandedPanel(icon: "speaker.wave.2.fill", header: "Other Audio While You Dictate") {
        VStack(alignment: .leading, spacing: 8) {
          BrandedSegmentedPicker(
            options: [
              ("Nothing", nil, OtherAudioWhileDictating.nothing),
              ("Turn down", "speaker.wave.1", OtherAudioWhileDictating.turnDown),
              ("Mute", "speaker.slash", OtherAudioWhileDictating.mute),
              ("Pause music", "pause.circle", OtherAudioWhileDictating.pauseMusic),
            ],
            selection: $settings.otherAudioWhileDictating
          )
          Text(Self.footnote(for: settings.otherAudioWhileDictating))
            .settingsReadingCopy()
          if let unavailableNote {
            Text(unavailableNote).settingsReadingCopy()
          }
        }
      }
      .onChange(of: settings.otherAudioWhileDictating, initial: true) { _, mode in
        unavailableNote = nil
        refreshAvailability(mode)
        if mode == .pauseMusic {
          // The probe answers off the main actor; the note lands when it does,
          // and only for the choice still selected.
          dictationRuntime.otherAudioHold.preflightConsent { adapterAnswers in
            guard settings.otherAudioWhileDictating == .pauseMusic else { return }
            unavailableNote = adapterAnswers ? nil : Self.pauseAnythingUnavailableNote
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
    .onAppear {
      startOutputListener()
    }
    .onDisappear {
      // This is a plain Task in @State, not a `.task {}` modifier, so SwiftUI
      // does NOT auto-cancel it when the page goes away: leaving Sounds
      // mid-preview would otherwise let the delayed stop cue fire later,
      // after a real recording that started and finished entirely during the
      // 550ms wait, on a page nobody is looking at anymore (Codex code-diff
      // review r7, #1618).
      activePreviewTask?.cancel()
      stopOutputListener()
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
    .accessibilityValue(isSelected ? "Selected" : "")
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
  }
}

// MARK: - Catalog copy

extension RecordingSoundsSettingsView {
  /// One line per choice, in the user's words. No dashes (GR-NO-DASHES).
  static func footnote(for mode: OtherAudioWhileDictating) -> String {
    switch mode {
    case .nothing:
      return "Music and other audio keep playing as they are."
    case .turnDown:
      return
        "Lowers what plays through your current speakers or headphones to about half while you dictate, then puts it back. If you change the volume during a take, your new level stays."
    case .mute:
      return
        "Silences your current speakers or headphones while you dictate, including calls and spoken feedback, then puts the volume back. If you change the volume during a take, your new level stays."
    case .pauseMusic:
      return
        "Pauses whatever is playing (music, a video, a podcast), then resumes it when you stop. If you switch to something else during a take, what we paused stays paused."
    }
  }

  /// Shown under `Pause music` when the system route cannot answer on this Mac
  /// (a macOS update closed it): only the two scriptable players remain.
  static let pauseAnythingUnavailableNote =
    "On this Mac only Music and Spotify can be paused. macOS may ask for permission the first time; a take that needs permission is not paused."

  private static var defaultOutputAddress: AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
  }

  private func startOutputListener() {
    guard outputListener == nil else { return }
    let refresh: @MainActor @Sendable () -> Void = {
      refreshAvailability(settings.otherAudioWhileDictating)
    }
    let listener: AudioObjectPropertyListenerBlock = { _, _ in
      Task { @MainActor in refresh() }
    }
    var address = Self.defaultOutputAddress
    if AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listener) == noErr
    {
      outputListener = listener
    }
    refresh()
  }

  private func stopOutputListener() {
    guard let listener = outputListener else { return }
    var address = Self.defaultOutputAddress
    _ = AudioObjectRemovePropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listener)
    outputListener = nil
  }

  private func refreshAvailability(_ mode: OtherAudioWhileDictating) {
    // Pause music's note comes from the adapter probe, not the output device;
    // an output change must not clear it.
    guard mode != .pauseMusic else { return }
    guard !dictationRuntime.otherAudioHold.isModeAvailable(mode) else {
      unavailableNote = nil
      return
    }
    switch mode {
    case .turnDown:
      unavailableNote = "Turn down is not available on your current speakers or headphones."
    case .mute:
      unavailableNote = "Mute is not available on your current speakers or headphones."
    case .nothing, .pauseMusic:
      unavailableNote = nil
    }
  }
}

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
