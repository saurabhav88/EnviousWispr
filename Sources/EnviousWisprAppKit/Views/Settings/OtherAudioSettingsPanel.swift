import CoreAudio
import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

/// #1413: what happens to everything else your Mac is playing while you
/// dictate. One four-way choice, off by default; a change applies to the next
/// take. Lives on the Microphone page above Microphone readiness (founder,
/// 2026-09-16: it is about the take's audio, not about the start/stop sounds).
///
/// Renders as one row of the shared Microphone card (`AudioSettingsView`),
/// not its own card, but stays self-contained: owns the availability note, the
/// adapter probe at choice time and the default-output listener that keeps the
/// note honest when the user switches speakers with the page open (a
/// read/observe, not a desktop effect; released with the row).
struct OtherAudioSettingsPanel: View {
  @Environment(SettingsManager.self) private var settings
  /// The other-audio hold answers "can the current speakers carry this mode"
  /// and probes the pause-anything route at choice time.
  @Environment(DictationRuntime.self) private var dictationRuntime
  @State private var unavailableNote: String?
  @State private var outputListener: AudioObjectPropertyListenerBlock?
  /// Left indent for the footnote/note lines below the row, so they align
  /// under the label rather than the icon. See `AudioSettingsView.rowIndent`.
  let rowIndent: CGFloat

  var body: some View {
    @Bindable var settings = settings
    VStack(alignment: .leading, spacing: 8) {
      SettingsControlRow(
        icon: "speaker.wave.2.fill",
        title: "Media during dictation",
        description: Self.footnote(for: settings.otherAudioWhileDictating)
      ) {
        BrandedSegmentedPicker(
          options: [
            ("Continue", "play.fill", OtherAudioWhileDictating.nothing),
            ("Lower", "speaker.wave.1", OtherAudioWhileDictating.turnDown),
            ("Mute", "speaker.slash", OtherAudioWhileDictating.mute),
            ("Pause", "pause.circle", OtherAudioWhileDictating.pauseMusic),
          ],
          selection: $settings.otherAudioWhileDictating
        )
        .fixedSize(horizontal: true, vertical: false)
      }
      if let unavailableNote {
        Text(unavailableNote)
          .settingsReadingCopy()
          .padding(.leading, rowIndent)
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
    .onAppear { startOutputListener() }
    .onDisappear { stopOutputListener() }
  }

  // MARK: - Copy

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

  // MARK: - Availability

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
