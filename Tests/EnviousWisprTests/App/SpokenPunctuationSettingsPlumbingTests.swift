import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprLLM
@testable import EnviousWisprPipeline
@testable import EnviousWisprServices

/// #2450: the spoken-punctuation setting as ONE value, carried from the settings store to both pipeline
/// drivers, the recovery snapshot, the file-import snapshot and the cleanup step.
///
/// **Product Outcome.** When these fail the setting a user chose never reaches the step that applies
/// it, or a recovered or imported recording replays under different start words than the ones in force
/// when it was made. Nothing here proves routing: no non-English punctuation is applied in this change
/// (that is the routing chunk), so the start words are carried and observed, not yet used.
@MainActor
@Suite("Spoken punctuation plumbing (#2450)", .tags(.productOutcome))
struct SpokenPunctuationSettingsPlumbingTests {

  private static let allDefaults = ["de": "Setze", "fr": "Insère", "es": "Pon", "it": "Metti"]

  private static func freshSettings() -> SettingsManager {
    SettingsManager(defaults: TestDefaults.suite("SP-2450-\(UUID().uuidString)")!)
  }

  private func makeSync() -> (
    PipelineSettingsSync, SettingsManager, KernelDictationDriver, KernelDictationDriver
  ) {
    let audio = RouterTestAudioCapture()
    let asr = RouterTestASRManager()
    let store = DictationRuntimeFixtures.tempStore()
    let parakeet = DictationRuntimeFixtures.makeParakeetDriver(
      audioCapture: audio, asrManager: asr, store: store)
    let whisperKit = DictationRuntimeFixtures.makeWhisperKitPipeline(
      audioCapture: audio, store: store)
    let settings = Self.freshSettings()
    let sync = PipelineSettingsSync(
      kernelDriver: parakeet,
      whisperKitKernelDriver: whisperKit,
      audioCapture: audio,
      asrManager: asr,
      hotkeyService: HotkeyService(effects: RecordingDesktopHotkeyEffects()),
      ollamaRemotenessLookup: { _ in nil })
    return (sync, settings, parakeet, whisperKit)
  }

  private func snapshot(
    enabled: Bool?, words: [String: String]?
  ) -> RecordingSettingsSnapshot {
    RecordingSettingsSnapshot(
      backendType: .parakeet,
      backendSupportsLanguageDetection: false,
      languageMode: .auto,
      wordCorrectionEnabled: false,
      fillerRemovalEnabled: false,
      emojiFormatterEnabled: false,
      spokenPunctuationEnabled: enabled,
      spokenPunctuationStartWords: words,
      llmProvider: "none",
      llmModel: "none",
      s1Control: nil,
      englishSpelling: nil)
  }

  // MARK: - Settings store to both drivers

  @Test("Initial sync hands both drivers the whole value")
  func initialSyncCarriesTheWholeValue() {
    let (sync, settings, parakeet, whisperKit) = makeSync()
    settings.spokenPunctuation.enabled = true
    settings.commitSpokenPunctuationStartWord("Diktiere", language: "de")
    sync.applyInitialSettings(settings)

    let expected = SpokenPunctuationSettings(enabled: true, startWordOverrides: ["de": "Diktiere"])
    #expect(parakeet.spokenPunctuation == expected)
    #expect(whisperKit.spokenPunctuation == expected)
  }

  @Test("A live change to either half reaches both drivers")
  func liveChangesReachBothDrivers() {
    let (sync, settings, parakeet, whisperKit) = makeSync()
    sync.applyInitialSettings(settings)
    #expect(parakeet.spokenPunctuation == SpokenPunctuationSettings.off)

    settings.spokenPunctuation.enabled = true
    sync.handleSettingChanged(.spokenPunctuation, settings: settings)
    #expect(
      parakeet.spokenPunctuation
        == SpokenPunctuationSettings(enabled: true, startWordOverrides: [:]))
    #expect(whisperKit.spokenPunctuation == parakeet.spokenPunctuation)

    settings.commitSpokenPunctuationStartWord("Schreibe", language: "de")
    sync.handleSettingChanged(.spokenPunctuation, settings: settings)
    let expected = SpokenPunctuationSettings(enabled: true, startWordOverrides: ["de": "Schreibe"])
    #expect(parakeet.spokenPunctuation == expected)
    #expect(whisperKit.spokenPunctuation == expected)
  }

  // MARK: - The cleanup step reads one snapshot of the value

  @Test("The step passes the enabled flag of the value in force to the unchanged English hook")
  func stepPassesEnabledToTheEnglishHook() async throws {
    final class Seen: @unchecked Sendable {
      private let lock = NSLock()
      private var flags: [Bool] = []
      func add(_ flag: Bool) { lock.withLock { flags.append(flag) } }
      var all: [Bool] { lock.withLock { flags } }
    }
    let seen = Seen()
    let step = InverseTextNormalizationStep(requestWork: { request in
      seen.add(request.spokenPunctuation.enabled)
      return ITNWorkResult(text: request.input, punctuationRulesFired: nil)
    })
    let context = TextProcessingContext(text: "hello world", language: nil)

    step.spokenPunctuation = SpokenPunctuationSettings(
      enabled: true, startWordOverrides: ["de": "Diktiere"])
    _ = try await step.process(context)
    step.spokenPunctuation = SpokenPunctuationSettings(
      enabled: false, startWordOverrides: ["de": "Diktiere"])
    _ = try await step.process(context)

    #expect(seen.all == [true, false])
  }

  @Test("A step built in isolation defaults to off with nothing customised")
  func stepDefaultsToOff() {
    #expect(InverseTextNormalizationStep().spokenPunctuation == SpokenPunctuationSettings.off)
  }

  // MARK: - The snapshot reads back as the same value

  @Test("A snapshot reads back its switch and its recorded words; absent means off and none")
  func snapshotReadsBack() {
    let recorded = snapshot(enabled: true, words: Self.allDefaults)
    #expect(recorded.spokenPunctuationSettings.enabled == true)
    #expect(recorded.spokenPunctuationSettings.startWordOverrides == Self.allDefaults)

    let legacy = snapshot(enabled: nil, words: nil)
    #expect(legacy.spokenPunctuationSettings == SpokenPunctuationSettings.off)

    let switchOnly = snapshot(enabled: true, words: nil)
    #expect(
      switchOnly.spokenPunctuationSettings
        == SpokenPunctuationSettings(enabled: true, startWordOverrides: [:]))
  }

  @Test("A snapshot read-back drops an invalid recorded word and keeps the rest")
  func snapshotReadBackRevalidates() {
    let tampered = snapshot(
      enabled: true, words: ["de": "Punkt", "fr": "Diktiere", "xx": "Wort", "es": "zwei Worte"])
    #expect(tampered.spokenPunctuationSettings.startWordOverrides == ["fr": "Diktiere"])
  }

  // MARK: - Recovery

  @Test("A recovered take replays under the start words recorded with it")
  func recoveryAppliesTheRecordedValue() {
    let recorded = ["de": "Diktiere", "fr": "Insère", "es": "Pon", "it": "Metti"]
    let processor = RecoveryTextProcessor(keychainManager: KeychainManager())
    processor.applySettings(snapshot(enabled: true, words: recorded))
    #expect(
      processor.inverseTextNormalizationStep.spokenPunctuation
        == SpokenPunctuationSettings(enabled: true, startWordOverrides: recorded))
  }

  @Test("A recorded word that equals today's default is still carried")
  func recoveryKeepsADefaultEqualWord() {
    let processor = RecoveryTextProcessor(keychainManager: KeychainManager())
    processor.applySettings(snapshot(enabled: true, words: Self.allDefaults))
    #expect(
      processor.inverseTextNormalizationStep.spokenPunctuation.startWordOverrides
        == Self.allDefaults)
  }

  @Test("A spool from before start words replays off with the shipped defaults")
  func legacySpoolReplaysOff() {
    let processor = RecoveryTextProcessor(keychainManager: KeychainManager())
    // Poison first, so the nil branch is shown to WRITE the default rather than leave a fresh one.
    processor.inverseTextNormalizationStep.spokenPunctuation = SpokenPunctuationSettings(
      enabled: true, startWordOverrides: ["de": "Diktiere"])
    processor.applySettings(snapshot(enabled: nil, words: nil))
    #expect(
      processor.inverseTextNormalizationStep.spokenPunctuation == SpokenPunctuationSettings.off)
    #expect(
      SpokenPunctuationRules.effectiveStartWords(
        overrides: processor.inverseTextNormalizationStep.spokenPunctuation.startWordOverrides)
        == Self.allDefaults)
  }

  // MARK: - File import

  @Test("An import freezes the effective start words at Start")
  func importFreezeCapturesEffectiveWords() {
    let settings = Self.freshSettings()
    settings.spokenPunctuation.enabled = true
    settings.commitSpokenPunctuationStartWord("Diktiere", language: "de")

    let frozen = FileImportSettingsFreeze.snapshot(settings: settings)
    #expect(frozen.spokenPunctuationEnabled == true)
    #expect(
      frozen.spokenPunctuationStartWords
        == ["de": "Diktiere", "fr": "Insère", "es": "Pon", "it": "Metti"])
  }

  @Test("With nothing customised the import freezes all four defaults")
  func importFreezeCapturesDefaults() {
    let frozen = FileImportSettingsFreeze.snapshot(settings: Self.freshSettings())
    #expect(frozen.spokenPunctuationEnabled == false)
    #expect(frozen.spokenPunctuationStartWords == Self.allDefaults)
  }

  @Test("A frozen import is unaffected by a later settings change")
  func importFreezeIsAuthoritative() {
    let settings = Self.freshSettings()
    settings.commitSpokenPunctuationStartWord("Diktiere", language: "de")
    let frozen = FileImportSettingsFreeze.snapshot(settings: settings)
    settings.commitSpokenPunctuationStartWord("Schreibe", language: "de")
    settings.spokenPunctuation.enabled = true
    #expect(frozen.spokenPunctuationStartWords?["de"] == "Diktiere")
    #expect(frozen.spokenPunctuationEnabled == false)
  }

  @Test("The import runner applies the frozen value to the steps it builds")
  func importRunnerAppliesTheFrozenValue() {
    let recorded = ["de": "Diktiere", "fr": "Insère", "es": "Pon", "it": "Metti"]
    let runner = FileImportRunner(keychainManager: KeychainManager())
    let steps = runner.makeSteps(settings: snapshot(enabled: true, words: recorded))
    #expect(
      steps.inverseTextNormalization.spokenPunctuation
        == SpokenPunctuationSettings(enabled: true, startWordOverrides: recorded))

    let legacy = runner.makeSteps(settings: snapshot(enabled: nil, words: nil))
    #expect(legacy.inverseTextNormalization.spokenPunctuation == SpokenPunctuationSettings.off)
  }
}
