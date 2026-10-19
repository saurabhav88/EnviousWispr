import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprLLM
@testable import EnviousWisprPipeline
@testable import EnviousWisprServices

/// #3853: the output classifier is released when no consumer needs it and loaded again when one
/// does. Consumers are dictation's polish selection, Transcribe a File's effective selection, and
/// work already in flight by its FROZEN provider (a dictation's session config, a running import,
/// a crash-recovery replay). Each test switches the selection away and checks whether the shared
/// holder kept or dropped the classifier.
@MainActor
@Suite("PipelineSettingsSync output classifier demand (#3853)", .tags(.productOutcome))
struct PipelineSettingsSyncOutputClassifierDemandTests {

  private struct StubClassifier: OutputClassifierProtocol {
    func score(input: String, polished: String) async throws -> Double { 0 }
  }

  @MainActor
  private final class Fixture {
    let sync: PipelineSettingsSync
    let settings: SettingsManager
    let holder: OutputClassifierHolder
    let dictationDriver: KernelDictationDriver
    var loadRequests = 0
    var importProvider: LLMProvider?

    init() {
      let audio = RouterTestAudioCapture()
      let asr = RouterTestASRManager()
      let store = DictationRuntimeFixtures.tempStore()
      let pipeline = DictationRuntimeFixtures.makeParakeetDriver(
        audioCapture: audio, asrManager: asr, store: store)
      let whisperDriver = DictationRuntimeFixtures.makeWhisperPipeline(
        audioCapture: audio, store: store)
      settings = SettingsManager(
        defaults: TestDefaults.suite("SM-3853-classifier-\(UUID().uuidString)")!)
      holder = OutputClassifierHolder(classifier: StubClassifier())
      dictationDriver = pipeline
      var loadHook: () -> Void = {}
      var importHook: () -> LLMProvider? = { nil }
      sync = PipelineSettingsSync(
        kernelDriver: pipeline,
        whisperKernelDriver: whisperDriver,
        audioCapture: audio,
        asrManager: asr,
        hotkeyService: HotkeyService(effects: RecordingDesktopHotkeyEffects()),
        ollamaRemotenessLookup: { _ in nil },
        outputClassifierHolder: holder,
        loadOutputClassifier: { loadHook() },
        importPinnedPolishProvider: { importHook() }
      )
      sync.evictionScheduler = { _ in }
      loadHook = { [unowned self] in loadRequests += 1 }
      importHook = { [unowned self] in importProvider }
      settings.llmProvider = .appleIntelligence
      settings.fileImportLLMProvider = nil
      sync.applyInitialSettings(settings)
    }

    func switchDictation(to provider: LLMProvider) {
      settings.llmProvider = provider
      sync.handleSettingChanged(.llmProvider, settings: settings)
    }
  }

  @Test("dictation only: switching away from Apple Intelligence releases the classifier")
  func dictationSwitchAwayReleases() {
    let f = Fixture()
    f.switchDictation(to: .openAI)
    #expect(f.holder.classifier == nil)
  }

  @Test("dictation switching to Apple Intelligence asks for a load")
  func dictationSwitchToRequestsLoad() {
    let f = Fixture()
    f.switchDictation(to: .openAI)
    let before = f.loadRequests
    f.switchDictation(to: .appleIntelligence)
    #expect(f.loadRequests == before + 1)
  }

  @Test("file import only: its Apple Intelligence selection keeps the classifier")
  func fileImportSelectionKeeps() {
    let f = Fixture()
    f.settings.fileImportLLMProvider = .appleIntelligence
    f.sync.handleSettingChanged(.fileImportLLMProvider, settings: f.settings)
    f.switchDictation(to: .openAI)
    #expect(f.holder.classifier != nil)

    f.settings.fileImportLLMProvider = .openAI
    f.sync.handleSettingChanged(.fileImportLLMProvider, settings: f.settings)
    #expect(f.holder.classifier == nil)
  }

  #if DEBUG  // `contextForTesting` is a DEBUG-only seam.
    @Test("an in-flight dictation that froze Apple Intelligence blocks release until it ends")
    func inFlightDictationBlocksRelease() {
      let f = Fixture()
      f.dictationDriver.contextForTesting.config = .testDefault(llmProvider: .appleIntelligence)
      f.switchDictation(to: .openAI)
      #expect(f.holder.classifier != nil)

      f.dictationDriver.contextForTesting.config = nil
      f.sync.retryDeferredOutputClassifierRelease(settings: f.settings)
      #expect(f.holder.classifier == nil)
    }
  #endif

  @Test("a running import that froze Apple Intelligence blocks release until it ends")
  func inFlightImportBlocksRelease() {
    let f = Fixture()
    f.importProvider = .appleIntelligence
    f.switchDictation(to: .openAI)
    #expect(f.holder.classifier != nil)

    f.importProvider = nil
    f.sync.retryDeferredOutputClassifierRelease(settings: f.settings)
    #expect(f.holder.classifier == nil)
  }

  @Test("a recovery replay of an Apple Intelligence take asks for the released classifier back")
  func recoveryReplayRequestsLoad() {
    let f = Fixture()
    f.switchDictation(to: .openAI)
    let before = f.loadRequests
    f.sync.outputClassifierRecoveryStarted(provider: .appleIntelligence, settings: f.settings)
    #expect(f.loadRequests == before + 1)
  }

  @Test("a recovery replay holds a loaded classifier until the replay ends")
  func recoveryReplayBlocksRelease() {
    let f = Fixture()
    f.sync.outputClassifierRecoveryStarted(provider: .appleIntelligence, settings: f.settings)
    f.switchDictation(to: .openAI)
    #expect(f.holder.classifier != nil)

    f.sync.outputClassifierRecoveryFinished(provider: .appleIntelligence, settings: f.settings)
    #expect(f.holder.classifier == nil)
  }

  #if DEBUG  // `contextForTesting` is a DEBUG-only seam.
    @Test("work that polishes elsewhere does not hold the classifier")
    func unrelatedInFlightWorkDoesNotHold() {
      let f = Fixture()
      f.dictationDriver.contextForTesting.config = .testDefault(llmProvider: .ollama)
      f.importProvider = .egOne
      f.sync.outputClassifierRecoveryStarted(provider: .gemini, settings: f.settings)
      f.switchDictation(to: .openAI)
      #expect(f.holder.classifier == nil)
    }
  #endif
}
