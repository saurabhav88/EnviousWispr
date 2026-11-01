import EnviousWisprCore
import Foundation

/// The Engine page's two transcription engines, in the order their cards show them. The cards
/// and the selected-engine summary render this list, and the Settings Map (#3482) derives its
/// engine choices from it, so they can never disagree about an engine's name, model or specs.
///
/// Model names stay verbatim product names. `ASRBackendType.displayName` is not the shipped
/// model name for Whisper, so the cards never read it.
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

  /// #3792: how long transcription takes after the user stops speaking, for a short, medium and
  /// long recording, and where those numbers come from. The card shows the three values in one
  /// row; the row's help explains the lengths and names the source.
  struct TranscribeTimes: Sendable {
    /// Seconds for a short, medium and long recording.
    let short: Double
    let medium: Double
    let long: Double
    /// The sentence naming the source of these numbers, shown after `timesHelpIntro`.
    let source: LocalizedStringResource

    /// The three times as shown, in the order of `timeCaptions`.
    var values: [String] { [short, medium, long].map(EngineChoicePresentation.seconds) }

    /// The row's help: what the three lengths mean, then where these numbers come from.
    var help: String {
      String(localized: EngineChoicePresentation.timesHelpIntro) + " " + String(localized: source)
    }
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
    let times: TranscribeTimes
  }

  /// The canonical list the Settings Map derives its engine choices from. It reads only each
  /// choice's id, title and tagline, so it never depends on which Parakeet model this Mac runs.
  static let choices: [Choice] = [fast, allLanguages]

  /// #3546: the list the cards render, naming the Parakeet model this Mac presents (the
  /// serving model, or the pending one; `ModelDeliveryHome.parakeetModelLabel`).
  static func choices(parakeetModel: String) -> [Choice] {
    [fast(parakeetModel: parakeetModel), allLanguages]
  }

  /// The presentation for a backend. Exhaustive, so a new backend must be given a card here.
  static func choice(for backend: ASRBackendType, parakeetModel: String) -> Choice {
    switch backend {
    case .parakeet: fast(parakeetModel: parakeetModel)
    case .whisper: allLanguages
    }
  }

  /// #3546: the shipped Parakeet model, for the canonical list only. Screens name the model
  /// the Mac presents through `choices(parakeetModel:)`.
  private static let fastModelName = ParakeetModel.ultra.displayName
  private static let allLanguagesModelName = "Whisper Large v3 Turbo"

  static let modelLabel = LocalizedStringResource(
    "Model", comment: "Speech engine settings, engine card: a row label in the card's spec table.")
  static let languagesLabel = LocalizedStringResource(
    "Languages",
    comment: "Speech engine settings, engine card: a row label in the card's spec table.")
  static let runsOnLabel = LocalizedStringResource(
    "Runs on", comment: "Speech engine settings, engine card: a row label in the card's spec table."
  )
  static let downloadSizeLabel = LocalizedStringResource(
    "Download size",
    comment: "Speech engine settings, engine card: a row label in the card's spec table.")
  /// The Runs on value for engines on the graphics processor (All Languages, and #4320
  /// EnviousMeet's Universal live engine).
  static let appleGPU = LocalizedStringResource(
    "Apple GPU",
    comment: "Speech engine settings, engine card: the chip it runs on, the graphics processor.")
  static let transcribeTimeLabel = LocalizedStringResource(
    "Transcribe time",
    comment: "Speech engine settings, engine card: a row label in the card's spec table.")

  /// #3792: the captions under the three transcribe times, in the order of `TranscribeTimes`.
  static let timeCaptions: [LocalizedStringResource] = [
    LocalizedStringResource(
      "short",
      comment:
        "Speech engine settings, engine card: caption under the transcribe time of a short recording (under 5 seconds)."
    ),
    LocalizedStringResource(
      "medium",
      comment:
        "Speech engine settings, engine card: caption under the transcribe time of a medium recording (about 30 seconds)."
    ),
    LocalizedStringResource(
      "long",
      comment:
        "Speech engine settings, engine card: caption under the transcribe time of a long recording (about 5 minutes)."
    ),
  ]

  /// #3792: the first part of the Transcribe time help, shared by both cards. The times are
  /// transcription only (the decode after the user stops), never record to paste.
  static let timesHelpIntro = LocalizedStringResource(
    "Typical transcription time after you stop speaking. This does not include AI polish or pasting. Short means under 5 seconds of speech, medium about 30 seconds, long about 5 minutes.",
    comment:
      "Speech engine settings, engine card: help beside Transcribe time, explaining the three times."
  )

  /// #3792: a time in seconds as the card shows it ("0.1 s", "1 s"). The number follows the
  /// Mac's region (a comma in Germany), so it is formatted here and only the unit is translated.
  static func seconds(_ value: Double) -> String {
    let number = value.formatted(.number.precision(.fractionLength(0...1)))
    return String(
      localized: "\(number) s",
      comment: "Speech engine settings, engine card: a time in seconds. %@ is the number.")
  }

  /// #3792: shipped download sizes, each the `totalBytes` of its delivery manifest
  /// (`parakeet-delivery-manifest.json`, `parakeet-v3-retired-manifest.json`,
  /// `whisper-delivery-manifest.json`). A test pins each to its manifest.
  static let parakeetUltraDownloadBytes: Int64 = 632_314_500
  static let whisperDownloadBytes: Int64 = 886_381_760
  /// #4320: the Universal preview engine (whisper-small), the `totalBytes` of
  /// `whisper-preview-delivery-manifest.json`; shown on EnviousMeet's Universal live card. A test
  /// pins it to the manifest.
  static let whisperPreviewDownloadBytes: Int64 = 269_751_136

  /// The Fast card's download size follows the model the card names (#3546): v3 when the Mac
  /// presents v3, otherwise Ultra, the shipped model.
  static func fastDownloadBytes(parakeetModel: String) -> Int64 {
    parakeetModel == ParakeetModel.v3.displayName
      ? ParakeetModel.v3ShippedBytes : parakeetUltraDownloadBytes
  }

  /// Whole decimal megabytes, rounded: 632 MB, 483 MB, 886 MB. `ByteCountFormatter`'s file
  /// style shows one decimal (632.3 MB), which the founder did not choose.
  static func downloadSize(bytes: Int64) -> LocalizedStringResource {
    let megabytes = Int((Double(bytes) / 1_000_000).rounded())
    return LocalizedStringResource(
      "\(megabytes) MB",
      comment: "Speech engine settings, engine card: a model's download size in megabytes.")
  }

  // Every value is grounded: Parakeet's 25-language support is confirmed by the NVIDIA model
  // card AND a live in-app test (French/Spanish/German, 2026-07-03). Transcribe times (#3792,
  // measured 2026-10-15) are the median warm `asr_seconds` of successful `dictation.completed`
  // takes by `recording_seconds` (short under 5 s, medium 20 to 45 s, long 3 to 7 min): Fast
  // from 60 days of production telemetry across all users' Macs (0.127, 0.245, 1.059 s; base M1
  // Macs 0.213, 0.368, 2.21 s); All Languages from the founder's M5 Max dev build until the
  // transcribe.cpp engine reaches users. The "Runs on" values are read from the
  // actual compute-unit config: Parakeet loads `.cpuAndNeuralEngine` (FluidAudio
  // AsrModels.defaultConfiguration); Whisper runs on transcribe.cpp's Metal (GPU) backend
  // (#3735; the retired WhisperKit also avoided the Neural Engine, #879). Both run entirely
  // on-device. Copy advertises Parakeet's 25 European languages, not just English (founder,
  // 2026-07-03).
  static let fast = fast(parakeetModel: fastModelName)

  static func fast(parakeetModel: String) -> Choice {
    Choice(
      backend: .parakeet,
      mapID: .transcriptionEngineFast,
      icon: "bolt.fill",
      title: LocalizedStringResource(
        "Fast", comment: "Speech engine settings, engine card: the fast engine's name."),
      tagline: LocalizedStringResource(
        "Pick this for everyday English and European dictation.",
        comment: "Speech engine settings, engine card: when to pick the fast engine."),
      model: parakeetModel,
      summary: DictationSettingsCopy.Engine.fastSummary,
      specs: [
        Spec(label: modelLabel, value: .verbatim(parakeetModel)),
        Spec(
          label: downloadSizeLabel,
          value: .localized(downloadSize(bytes: fastDownloadBytes(parakeetModel: parakeetModel)))),
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
      ],
      times: TranscribeTimes(
        short: 0.1, medium: 0.3, long: 1,
        source: LocalizedStringResource(
          "Typical times for people using EnviousWispr. On the oldest supported Macs (M1), about \(seconds(0.2)), \(seconds(0.4)) and \(seconds(2)).",
          comment:
            "Speech engine settings, Fast engine card: where its transcribe times come from. M1 is Apple's chip name. Each %@ is a time such as 0.2 s."
        )))
  }

  static let allLanguages = Choice(
    backend: .whisper,
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
      Spec(label: downloadSizeLabel, value: .localized(downloadSize(bytes: whisperDownloadBytes))),
      Spec(
        label: languagesLabel,
        value: .localized(
          LocalizedStringResource(
            "99+ languages",
            comment: "Speech engine settings, engine card: how many languages it covers."))),
      Spec(
        label: runsOnLabel,
        value: .localized(appleGPU)),
    ],
    times: TranscribeTimes(
      // Short and medium: medians of 24 and 18 dev takes. Long: median of three in-app takes of
      // about 4.5 minutes on the dev build (2026-10-15; `asr_seconds` 2.96, 3.07 and 3.25 s,
      // which include Auto language detection).
      short: 0.6, medium: 0.8, long: 3,
      source: LocalizedStringResource(
        "Measured on a MacBook Pro with M5 Max. Older Macs take longer.",
        comment:
          "Speech engine settings, All Languages engine card: where its transcribe times come from. M5 Max is Apple's chip name."
      )))
}
