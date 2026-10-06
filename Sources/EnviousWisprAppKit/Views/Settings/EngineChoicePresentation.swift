import EnviousWisprCore
import Foundation

/// The Engine page's two transcription engines, in the order their cards show them. The cards
/// and the selected-engine summary render this list, and the Settings Map (#3482) derives its
/// engine choices from it, so they can never disagree about an engine's name, model or specs.
///
/// Model names stay verbatim product names. `ASRBackendType.displayName` is not the shipped
/// model name for WhisperKit, so the cards never read it.
enum EngineChoicePresentation {
  /// A spec-table value: translated copy, or a product name shown as written.
  enum SpecValue: Sendable {
    case localized(LocalizedStringResource)
    case verbatim(String)

    var resolved: String {
      switch self {
      case .localized(let resource): String(localized: resource)
      case .verbatim(let text): text
      }
    }
  }

  struct Spec: Sendable {
    let label: LocalizedStringResource
    let value: SpecValue
  }

  struct Choice: Sendable {
    let backend: ASRBackendType
    /// The choice's Settings Map identity (#3482).
    let mapID: SettingsMapID
    let icon: String
    let title: LocalizedStringResource
    let tagline: LocalizedStringResource
    let model: String
    /// The short line under the engine's name in the summary; owned by the Engine copy.
    let summary: LocalizedStringResource
    let specs: [Spec]
  }

  static let choices: [Choice] = [fast, allLanguages]

  /// The presentation for a backend. Exhaustive, so a new backend must be given a card here.
  static func choice(for backend: ASRBackendType) -> Choice {
    switch backend {
    case .parakeet: fast
    case .whisperKit: allLanguages
    }
  }

  private static let fastModelName = "Parakeet v3"
  private static let allLanguagesModelName = "Whisper Large v3 Turbo"

  private static let modelLabel = LocalizedStringResource(
    "Model", comment: "Speech engine settings, engine card: a row label in the card's spec table.")
  private static let languagesLabel = LocalizedStringResource(
    "Languages",
    comment: "Speech engine settings, engine card: a row label in the card's spec table.")
  private static let runsOnLabel = LocalizedStringResource(
    "Runs on", comment: "Speech engine settings, engine card: a row label in the card's spec table."
  )
  private static let transcribeTimeLabel = LocalizedStringResource(
    "Transcribe time",
    comment: "Speech engine settings, engine card: a row label in the card's spec table.")

  // Every value is grounded: Parakeet's 25-language support is confirmed by the NVIDIA model
  // card AND a live in-app test (French/Spanish/German, 2026-07-03); transcribe times come from
  // our own benchmark data (asr-landscape-2026.md). The "Runs on" values are read from the
  // actual compute-unit config: Parakeet loads `.cpuAndNeuralEngine` (FluidAudio
  // AsrModels.defaultConfiguration), WhisperKit is pinned `.cpuAndGPU` and explicitly avoids
  // the Neural Engine (WhisperKitBackend dictationComputeOptions, #879). Both run entirely
  // on-device. Copy advertises Parakeet's 25 European languages, not just English (founder,
  // 2026-07-03).
  static let fast = Choice(
    backend: .parakeet,
    mapID: .transcriptionEngineFast,
    icon: "bolt.fill",
    title: LocalizedStringResource(
      "Fast", comment: "Speech engine settings, engine card: the fast engine's name."),
    tagline: LocalizedStringResource(
      "Pick this for everyday English and European dictation.",
      comment: "Speech engine settings, engine card: when to pick the fast engine."),
    model: fastModelName,
    summary: DictationSettingsCopy.Engine.fastSummary,
    specs: [
      Spec(label: modelLabel, value: .verbatim(fastModelName)),
      Spec(
        label: languagesLabel,
        value: .localized(
          LocalizedStringResource(
            "25 European languages",
            comment: "Speech engine settings, engine card: how many languages it covers."))),
      Spec(
        label: runsOnLabel,
        value: .localized(
          LocalizedStringResource(
            "Apple Neural Engine",
            comment:
              "Speech engine settings, engine card: the chip it runs on. Use Apple's own name for the Neural Engine in your language."
          ))),
      Spec(
        label: transcribeTimeLabel,
        value: .localized(
          LocalizedStringResource(
            "Usually ~0.1s after you speak",
            comment:
              "Speech engine settings, engine card: how quickly text appears. 0.1s is a tenth of a second."
          ))),
    ])

  static let allLanguages = Choice(
    backend: .whisperKit,
    mapID: .transcriptionEngineAllLanguages,
    icon: "globe",
    title: LocalizedStringResource(
      "All Languages",
      comment: "Speech engine settings, engine card: the multilingual engine's name."),
    tagline: LocalizedStringResource(
      "Pick this for other languages or the toughest audio.",
      comment: "Speech engine settings, engine card: when to pick the multilingual engine."),
    model: allLanguagesModelName,
    summary: DictationSettingsCopy.Engine.allLanguagesSummary,
    specs: [
      Spec(label: modelLabel, value: .verbatim(allLanguagesModelName)),
      Spec(
        label: languagesLabel,
        value: .localized(
          LocalizedStringResource(
            "99+ languages",
            comment: "Speech engine settings, engine card: how many languages it covers."))),
      Spec(
        label: runsOnLabel,
        value: .localized(
          LocalizedStringResource(
            "Apple GPU",
            comment:
              "Speech engine settings, engine card: the chip it runs on, the graphics processor."))),
      Spec(
        label: transcribeTimeLabel,
        value: .localized(
          LocalizedStringResource(
            "Usually 1-2s after you speak",
            comment: "Speech engine settings, engine card: how quickly text appears, in seconds."))),
    ])
}
