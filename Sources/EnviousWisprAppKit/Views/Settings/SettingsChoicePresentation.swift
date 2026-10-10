import EnviousWisprCore
import Foundation

/// One option of a settings picker: its stored value, its name, its icon and its Settings Map
/// identity (#3482). The picker renders the list and the map's coverage test reads the same list,
/// so the two can never disagree about which options exist.
struct SettingsChoice<Value: Hashable & Sendable>: Sendable {
  let value: Value
  let label: LocalizedStringResource
  var icon: String? = nil
  let mapID: SettingsMapID

  /// The shape `BrandedSegmentedPicker` takes.
  var pickerOption: (label: String, systemImage: String?, value: Value) {
    (String(localized: label), icon, value)
  }
}

/// The settings pickers whose options were written inline at the picker before #3482, in the
/// order each picker shows them.
enum SettingsChoicePresentation {
  static let micReadiness: [SettingsChoice<WarmEnginePolicy>] = [
    SettingsChoice(
      value: .off, label: SettingsItemCopy.Microphone.readinessOff, mapID: .micReadinessOff),
    SettingsChoice(
      value: .seconds10, label: SettingsItemCopy.Microphone.readiness10s, mapID: .micReadiness10s),
    SettingsChoice(
      value: .seconds30, label: SettingsItemCopy.Microphone.readiness30s, mapID: .micReadiness30s),
    SettingsChoice(
      value: .seconds60, label: SettingsItemCopy.Microphone.readiness60s, mapID: .micReadiness60s),
    SettingsChoice(
      value: .always, label: SettingsItemCopy.Microphone.readinessAlways,
      mapID: .micReadinessAlways),
  ]

  static let mediaDuringDictation: [SettingsChoice<OtherAudioWhileDictating>] = [
    SettingsChoice(
      value: .nothing, label: SettingsItemCopy.Microphone.mediaContinue, icon: "play.fill",
      mapID: .mediaDuringDictationContinue),
    SettingsChoice(
      value: .turnDown, label: SettingsItemCopy.Microphone.mediaLower, icon: "speaker.wave.1",
      mapID: .mediaDuringDictationLower),
    SettingsChoice(
      value: .mute, label: SettingsItemCopy.Microphone.mediaMute, icon: "speaker.slash",
      mapID: .mediaDuringDictationMute),
    SettingsChoice(
      value: .pauseMusic, label: SettingsItemCopy.Microphone.mediaPause, icon: "pause.circle",
      mapID: .mediaDuringDictationPause),
  ]

  static let pillPosition: [SettingsChoice<OverlayPillPosition>] = [
    SettingsChoice(value: .top, label: SettingsItemCopy.Pill.top, mapID: .pillPositionTop),
    SettingsChoice(value: .bottom, label: SettingsItemCopy.Pill.bottom, mapID: .pillPositionBottom),
  ]

  static let recordingMode: [SettingsChoice<RecordingMode>] = [
    SettingsChoice(
      value: .pushToTalk, label: SettingsItemCopy.Keybinds.pushToTalk,
      mapID: .recordingModePushToTalk),
    SettingsChoice(
      value: .toggle, label: SettingsItemCopy.Keybinds.toggle, mapID: .recordingModeToggle),
  ]
}
