import Foundation

/// Copy home for the Dictation Settings rows (#3385): each row's short grey
/// line and, where the row owns it, its full "?" explanation. The full
/// explanations are today's sentences, moved behind "?" unchanged; only the
/// short lines are new. Dynamic explanations stay with the view that chooses
/// them (`OtherAudioSettingsPanel.footnote(for:)`).
enum DictationSettingsCopy {
  enum Microphone {
    static let sectionHeading = LocalizedStringResource(
      "INPUT & BEHAVIOR",
      comment: "Microphone settings: section heading above the microphone rows, shown in capitals."
    )

    static let inputDeviceTitle = LocalizedStringResource(
      "Input device", comment: "Microphone settings: row title.")
    static let inputDeviceShort = LocalizedStringResource(
      "Choose the microphone used for recording.",
      comment: "Microphone settings: short line under the Input device row title.")
    static let inputDeviceHelp = LocalizedStringResource(
      "Select which microphone to use for recording. \"Auto\" follows the input device selected in macOS. If that device turns out not to be a real microphone, recording uses an available microphone instead.",
      comment:
        "Microphone settings: explains the input device choice. Auto is the name of the first option."
    )

    static let mediaTitle = LocalizedStringResource(
      "Media during dictation",
      comment:
        "Microphone settings, media during dictation: row title for what happens to music and other audio."
    )
    static let mediaShort = LocalizedStringResource(
      "What music and video do while you dictate.",
      comment: "Microphone settings: short line under the Media during dictation row title.")

    static let readinessTitle = LocalizedStringResource(
      "Microphone readiness", comment: "Microphone settings: row title.")
    static let readinessShort = LocalizedStringResource(
      "How long the mic stays ready after recording.",
      comment: "Microphone settings: short line under the Microphone readiness row title.")
    static let readinessHelp = LocalizedStringResource(
      "Keep the microphone engine active for a short time after dictation so the next recording starts instantly and captures your first words.",
      comment: "Microphone settings: explains microphone readiness.")
  }
}
