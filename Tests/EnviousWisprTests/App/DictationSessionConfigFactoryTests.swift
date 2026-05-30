@preconcurrency import AVFoundation
import EnviousWisprASR
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprPipeline
import EnviousWisprServices
import EnviousWisprStorage
import Testing

@testable import EnviousWisprAppKit

/// Unit tests for `DictationSessionConfigFactory.make(...)` (PR5 of epic #763).
///
/// The factory body is lifted verbatim from `the former root state(triggerSource:)`,
/// so end-to-end behavior is exercised by existing the former root state toggleRecording tests
/// and the runtime UAT. These tests pin three deterministic data-transformation
/// invariants: trigger-source passthrough, LLM-model resolution per provider,
/// and settings passthrough on the parakeet-idle path (the common case).
///
/// Pipeline-state branching (whisperKit `.ready` etc.) is covered end-to-end by
/// `HeartPathIntegrationTests` after this PR rewires `toggleRecording` through
/// the factory.
@MainActor
@Suite("DictationSessionConfigFactory — make()")
struct DictationSessionConfigFactoryTests {

  // MARK: - Trigger source passthrough

  @Test("trigger source flows through to the config")
  func triggerSourcePassthrough() async throws {
    let harness = try Harness.make(backend: .parakeet)

    for source in TriggerSource.allCases {
      let config = DictationSessionConfigFactory.make(
        asrManager: harness.asrManager,
        kernelDriver: harness.kernelDriver,
        whisperKitKernelDriver: harness.whisperKitKernelDriver,
        settings: harness.settings,
        triggerSource: source
      )
      #expect(config.triggerSource == source, "triggerSource=\(source) must pass through")
    }
  }

  // MARK: - LLM model resolution

  @Test("appleIntelligence resolves to apple-intelligence literal")
  func llmModelAppleIntelligence() async throws {
    let harness = try Harness.make(backend: .parakeet)
    harness.settings.llmProvider = .appleIntelligence
    harness.settings.llmModel = "should-be-ignored-for-AI"
    let config = harness.makeConfig()
    #expect(config.llmModel == "apple-intelligence")
  }

  @Test("ollama resolves to settings.ollamaModel")
  func llmModelOllama() async throws {
    let harness = try Harness.make(backend: .parakeet)
    harness.settings.llmProvider = .ollama
    harness.settings.ollamaModel = "llama3:8b"
    harness.settings.llmModel = "should-be-ignored-for-ollama"
    let config = harness.makeConfig()
    #expect(config.llmModel == "llama3:8b")
  }

  @Test("default branch resolves to settings.llmModel")
  func llmModelDefaultBranch() async throws {
    let harness = try Harness.make(backend: .parakeet)
    harness.settings.llmProvider = .none
    harness.settings.llmModel = "claude-sonnet-4-5"
    let config = harness.makeConfig()
    #expect(config.llmModel == "claude-sonnet-4-5")
  }

  // MARK: - Active-pipeline idle path

  @Test("autoPasteToActiveApp is true when parakeet pipeline is idle")
  func autoPasteOnIdleParakeet() async throws {
    let harness = try Harness.make(backend: .parakeet)
    let config = harness.makeConfig()
    #expect(config.autoPasteToActiveApp == true)
  }

  @Test("autoPasteToActiveApp is true when whisperKit pipeline is idle")
  func autoPasteOnIdleWhisperKit() async throws {
    // Pins the happy path of the WhisperKit branch: when
    // `asrManager.activeBackendType == .whisperKit`, the factory must produce
    // `autoPasteToActiveApp == true` while `whisperKitKernelDriver.state == .idle`.
    //
    // Note on coverage limits (Codex r2 finding): both pipelines start `.idle`
    // at construction, so this test would not catch a hypothetical regression
    // where the factory mistakenly reads `pipeline.state` instead of
    // `whisperKitKernelDriver.state`. That mismatch is, however, already prevented
    // by the type system: `WhisperKitPipelineState` includes cases (`.ready`,
    // `.startingUp`) that `PipelineState` does not, so swapping the operand of
    // the WhisperKit `switch` is a compile error. Driving a pipeline to a non-
    // idle state in unit tests would require booting real audio capture / ASR
    // (the only public mutator is `startRecording(config:)`); the runtime UAT
    // covers that path.
    let harness = try Harness.make(backend: .whisperKit)
    let config = harness.makeConfig()
    #expect(config.autoPasteToActiveApp == true)
  }

  // MARK: - Settings field passthrough

  @Test("settings fields pass through unchanged")
  func settingsPassthrough() async throws {
    let harness = try Harness.make(backend: .parakeet)
    harness.settings.autoCopyToClipboard = false
    harness.settings.restoreClipboardAfterPaste = true
    harness.settings.vadAutoStop = true
    harness.settings.vadSilenceTimeout = 2.5
    harness.settings.vadSensitivity = 0.7
    harness.settings.vadEnergyGate = true
    harness.settings.languageMode = .locked("en")
    harness.settings.useStreamingASR = false
    harness.settings.useExtendedThinking = true

    let config = harness.makeConfig()
    #expect(config.autoCopyToClipboard == false)
    #expect(config.restoreClipboardAfterPaste == true)
    #expect(config.vadAutoStop == true)
    #expect(config.vadSilenceTimeout == 2.5)
    #expect(config.vadSensitivity == 0.7)
    #expect(config.vadEnergyGate == true)
    #expect(config.languageMode == .locked("en"))
    #expect(config.useStreamingASR == false)
    #expect(config.useExtendedThinking == true)
  }
}

// MARK: - Test harness

@MainActor
private struct Harness {
  let asrManager: FactoryFakeASRManager
  let kernelDriver: KernelDictationDriver
  let whisperKitKernelDriver: KernelDictationDriver
  let settings: SettingsManager

  static func make(backend: ASRBackendType) throws -> Harness {
    let asr = FactoryFakeASRManager(backend: backend)
    // Reuse the existing test fixture path — a tiny WAV is enough to satisfy
    // FixtureAudioCapture's init. The factory never drives capture; pipelines
    // are constructed only to satisfy the factory parameter list and remain
    // in `.idle` state for the duration of these tests.
    let fixture = try SyntheticAudioFixture.make(
      fileName: "factory-harness.wav",
      pattern: .toneBurst
    )
    let audio = try FixtureAudioCapture(fixtureURL: fixture.url)
    let store = TranscriptStore()
    let pipeline = DictationRuntimeFixtures.makeParakeetDriver(
      audioCapture: audio, asrManager: asr, store: store)
    let whisperKitKernelDriver = DictationRuntimeFixtures.makeWhisperKitPipeline(
      audioCapture: audio, store: store)
    let settings = SettingsManager()
    return Harness(
      asrManager: asr,
      kernelDriver: pipeline,
      whisperKitKernelDriver: whisperKitKernelDriver,
      settings: settings
    )
  }

  func makeConfig(triggerSource: TriggerSource = .programmatic) -> DictationSessionConfig {
    DictationSessionConfigFactory.make(
      asrManager: asrManager,
      kernelDriver: kernelDriver,
      whisperKitKernelDriver: whisperKitKernelDriver,
      settings: settings,
      triggerSource: triggerSource
    )
  }
}

// MARK: - Fakes

/// Minimal `ASRManagerInterface` for factory unit tests. The factory only reads
/// `activeBackendType`; everything else traps to make accidental use loud.
@MainActor
private final class FactoryFakeASRManager: ASRManagerInterface {
  var activeBackendType: ASRBackendType
  init(backend: ASRBackendType) { self.activeBackendType = backend }

  var isModelLoaded: Bool { true }
  var isStreaming: Bool { false }
  var downloadProgress: Double { 1 }
  var downloadPhase: String { "ready" }
  var downloadDetail: String { "" }
  var activeBackendSupportsStreaming: Bool { false }
  var onServiceInterrupted: (() -> Void)?
  var loadProgressTickReporter: (@MainActor @Sendable (Date?, String) -> Void)?

  func loadModel() async throws { fatalError("not used in DictationSessionConfigFactoryTests") }
  func loadModelSilently() async { fatalError("not used in DictationSessionConfigFactoryTests") }
  func unloadModel() async { fatalError("not used in DictationSessionConfigFactoryTests") }
  func setInitialBackendType(_: ASRBackendType) { fatalError("not used") }
  func switchBackend(to _: ASRBackendType) async { fatalError("not used") }
  func transcribe(audioSamples _: [Float], options _: TranscriptionOptions) async throws
    -> ASRResult
  {
    fatalError("not used")
  }
  func startStreaming(options _: TranscriptionOptions) async throws { fatalError("not used") }
  func feedAudio(_: AVAudioPCMBuffer) async throws { fatalError("not used") }
  func finalizeStreaming() async throws -> ASRResult { fatalError("not used") }
  func cancelStreaming() async { fatalError("not used") }
  func noteTranscriptionComplete(policy _: ModelUnloadPolicy) { fatalError("not used") }
  func cancelIdleTimer() { fatalError("not used") }
  func cancelInFlightLoad() { fatalError("not used") }
}
