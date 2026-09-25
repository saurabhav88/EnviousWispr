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
  /// Shared width with the Microphone readiness row's segmented control, so
  /// the two read as the same length despite holding a different number of
  /// options. `nil` until `AudioSettingsView` has measured both (see
  /// `SegmentedControlWidthKey`).
  let matchedWidth: CGFloat?

  var body: some View {
    @Bindable var settings = settings
    VStack(alignment: .leading, spacing: 8) {
      SettingsControlRow(
        icon: "speaker.wave.2.fill",
        title: String(
          localized: "Media during dictation",
          comment:
            "Microphone settings, media during dictation: row title for what happens to music and other audio."
        ),
        description: Self.footnote(for: settings.otherAudioWhileDictating)
      ) {
        BrandedSegmentedPicker(
          options: [
            (
              String(
                localized: "otherAudio.option.continue", defaultValue: "Continue",
                comment:
                  "Microphone settings, media during dictation: option that leaves other audio playing (keeps playing, not 'go on')."
              ), "play.fill", OtherAudioWhileDictating.nothing
            ),
            (
              String(
                localized: "Lower",
                comment:
                  "Microphone settings, media during dictation: option that turns other audio down."
              ), "speaker.wave.1", OtherAudioWhileDictating.turnDown
            ),
            (
              String(
                localized: "Mute",
                comment:
                  "Microphone settings, media during dictation: option that silences other audio."),
              "speaker.slash", OtherAudioWhileDictating.mute
            ),
            (
              String(
                localized: "Pause",
                comment:
                  "Microphone settings, media during dictation: option that pauses what is playing."
              ), "pause.circle", OtherAudioWhileDictating.pauseMusic
            ),
          ],
          selection: $settings.otherAudioWhileDictating,
          comfortable: true
        )
        .matchingSegmentedWidth(matchedWidth)
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
      return String(
        localized: "Music and other audio keep playing as they are.",
        comment: "Microphone settings, media during dictation: what the Continue option does.")
    case .turnDown:
      return String(
        localized:
          "Lowers what plays through your current speakers or headphones to about half while you dictate, then puts it back. If you change the volume during a take, your new level stays.",
        comment:
          "Microphone settings, media during dictation: what the Lower option does. A take is one dictation."
      )
    case .mute:
      return String(
        localized:
          "Silences your current speakers or headphones while you dictate, including calls and spoken feedback, then puts the volume back. If you change the volume during a take, your new level stays.",
        comment:
          "Microphone settings, media during dictation: what the Mute option does. A take is one dictation."
      )
    case .pauseMusic:
      return String(
        localized:
          "Pauses whatever is playing (music, a video, a podcast), then resumes it when you stop. If you switch to something else during a take, what we paused stays paused.",
        comment:
          "Microphone settings, media during dictation: what the Pause option does. A take is one dictation."
      )
    }
  }

  /// Shown under `Pause` when the system route cannot answer on this Mac
  /// (a macOS update closed it): only the two scriptable players remain.
  static let pauseAnythingUnavailableNote = String(
    localized:
      "On this Mac only Music and Spotify can be paused. macOS may ask for permission the first time; a take that needs permission is not paused.",
    comment:
      "Microphone settings, media during dictation: note under Pause when only some players can be paused. Music and Spotify are app names."
  )

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
    // Pause's note comes from the adapter probe, not the output device; an
    // output change must not clear it.
    guard mode != .pauseMusic else { return }
    guard !dictationRuntime.otherAudioHold.isModeAvailable(mode) else {
      unavailableNote = nil
      return
    }
    switch mode {
    case .turnDown:
      unavailableNote = String(
        localized: "Lower is not available on your current speakers or headphones.",
        comment:
          "Microphone settings, media during dictation: the Lower option cannot work on this output device."
      )
    case .mute:
      unavailableNote = String(
        localized: "Mute is not available on your current speakers or headphones.",
        comment:
          "Microphone settings, media during dictation: the Mute option cannot work on this output device."
      )
    case .nothing, .pauseMusic:
      unavailableNote = nil
    }
  }
}
