import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

/// Optional recording start/stop sound settings: a master toggle, an ordered
/// picker of sound pairings (tap a card anywhere to select it), and one
/// Preview control for the currently selected pairing.
///
/// #3385 (Chimes tab): the page itself is `RecordingChimesContent`; this view
/// supplies the live state and owns the one preview task. Every card now has
/// its own Preview button, which plays THAT card's pairing without selecting
/// it; there is no separate Preview control.
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

  var body: some View {
    @Bindable var settings = settings

    RecordingChimesContent(
      playsChimes: $settings.playRecordingSounds,
      selected: settings.recordingSoundPairing,
      isDictationActive: liveRecordingState.isDictationActive,
      onSelect: { pairing in settings.recordingSoundPairing = pairing },
      onPreview: { pairing in startPreview(pairing: pairing) }
    )
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

  /// Plays the clicked card's pairing; never reads or writes the selection. The
  /// sequence and its two guards live in `RecordingChimePreview`.
  private func startPreview(pairing: RecordingSoundPairing) {
    activePreviewTask = RecordingChimePreview.start(
      pairing: pairing,
      replacing: activePreviewTask,
      isDictationActive: { liveRecordingState.isDictationActive })
  }
}

// MARK: - Pairing card

// #3385: the card moved to `RecordingChimesContent.swift` (`RecordingChimeCard`);
// the names and descriptions stay here.

/// The twelve pairings' names and descriptions, in `RecordingSoundPairing` order.
enum RecordingChimeCatalog {
  static func name(for pairing: RecordingSoundPairing) -> String {
    displayName(for: pairing)
  }

  static func description(for pairing: RecordingSoundPairing) -> String {
    pairingDescription(for: pairing)
  }
}

func displayNameResource(for pairing: RecordingSoundPairing) -> LocalizedStringResource {
  switch pairing {
  case .dustMote:
    return LocalizedStringResource("Dust Mote",
      comment:
        "Chimes settings: a recording chime's name. A playful name; translate its feel, or keep it."
    )
  case .velvetHush:
    return LocalizedStringResource("Velvet Hush",
      comment:
        "Chimes settings: a recording chime's name. A playful name; translate its feel, or keep it."
    )
  case .mutedConfirm:
    return LocalizedStringResource("Muted Confirm",
      comment:
        "Chimes settings: a recording chime's name. A playful name; translate its feel, or keep it."
    )
  case .whisperTick:
    return LocalizedStringResource("Whisper Tick",
      comment:
        "Chimes settings: a recording chime's name. A playful name; translate its feel, or keep it."
    )
  case .roundPebble:
    return LocalizedStringResource("Round Pebble",
      comment:
        "Chimes settings: a recording chime's name. A playful name; translate its feel, or keep it."
    )
  case .paperTap:
    return LocalizedStringResource("Paper Tap",
      comment:
        "Chimes settings: a recording chime's name. A playful name; translate its feel, or keep it."
    )
  case .softHush:
    return LocalizedStringResource("Soft Hush",
      comment:
        "Chimes settings: a recording chime's name. A playful name; translate its feel, or keep it."
    )
  case .lowNod:
    return LocalizedStringResource("Low Nod",
      comment:
        "Chimes settings: a recording chime's name. A playful name; translate its feel, or keep it."
    )
  case .cloudPop:
    return LocalizedStringResource("Cloud Pop",
      comment:
        "Chimes settings: a recording chime's name. A playful name; translate its feel, or keep it."
    )
  case .velvetTap:
    return LocalizedStringResource("Velvet Tap",
      comment:
        "Chimes settings: a recording chime's name. A playful name; translate its feel, or keep it."
    )
  case .satinShift:
    return LocalizedStringResource("Satin Shift",
      comment:
        "Chimes settings: a recording chime's name. A playful name; translate its feel, or keep it."
    )
  case .airGlint:
    return LocalizedStringResource("Air Glint",
      comment:
        "Chimes settings: a recording chime's name. A playful name; translate its feel, or keep it."
    )
  }
}

private func displayName(for pairing: RecordingSoundPairing) -> String {
  String(localized: displayNameResource(for: pairing))
}

private func pairingDescription(for pairing: RecordingSoundPairing) -> String {
  switch pairing {
  case .dustMote:
    return String(
      localized: "Soft filtered air, no tone.",
      comment: "Chimes settings: describes how a recording chime sounds.")
  case .velvetHush:
    return String(
      localized: "Two close tones, gentle warmth.",
      comment: "Chimes settings: describes how a recording chime sounds.")
  case .mutedConfirm:
    return String(
      localized: "Same pitch both ways, plain.",
      comment: "Chimes settings: describes how a recording chime sounds.")
  case .whisperTick:
    return String(
      localized: "Barely-there tick.",
      comment: "Chimes settings: describes how a recording chime sounds.")
  case .roundPebble:
    return String(
      localized: "Rounded, no edge.",
      comment: "Chimes settings: describes how a recording chime sounds.")
  case .paperTap:
    return String(
      localized: "Soft paper-like tap.",
      comment: "Chimes settings: describes how a recording chime sounds.")
  case .softHush:
    return String(
      localized: "Slow fade, like a breath.",
      comment: "Chimes settings: describes how a recording chime sounds.")
  case .lowNod:
    return String(
      localized: "Low, warm, unhurried.",
      comment: "Chimes settings: describes how a recording chime sounds.")
  case .cloudPop:
    return String(
      localized: "Tiny filtered-air pop.",
      comment: "Chimes settings: describes how a recording chime sounds.")
  case .velvetTap:
    return String(
      localized: "Muted, compact tap.",
      comment: "Chimes settings: describes how a recording chime sounds.")
  case .satinShift:
    return String(
      localized: "Smooth two-tone shift.",
      comment: "Chimes settings: describes how a recording chime sounds.")
  case .airGlint:
    return String(
      localized: "Clean, airy glint.",
      comment: "Chimes settings: describes how a recording chime sounds.")
  }
}
