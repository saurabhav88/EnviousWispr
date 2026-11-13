import EnviousWisprAppKitTestSupport
import EnviousWisprCore
@preconcurrency import FluidAudio
import Foundation
import Testing

@testable import EnviousWisprASR
import EnviousWisprAudio
import EnviousWisprLLM
@testable import EnviousWisprAppKit
@testable import EnviousWisprPipeline
@testable import EnviousWisprStorage

/// Class: `.productOutcome`: when these fail, Transcribe again with cannot turn a real spoken
/// file into new words on the installed models, so the user's entry can never be refreshed.
/// Real models, read only and never downloaded; skipped when the model is not installed (a skip
/// is not a pass). Each run goes through the real decoder, the real identity reader, the chosen
/// model on its own copy, the real deterministic cleanup chain and the real History command.
@MainActor
@Suite("Transcribe again with on real models (#3147 PR3)", .serialized, .tags(.productOutcome))
struct TranscriptRetranscriptionRealBoundaryTests {

  nonisolated static let repoRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()  // App
    .deletingLastPathComponent()  // EnviousWisprTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // repo root

  nonisolated static var clip: URL {
    repoRoot.appending(path: "scripts/freeze-suite/clips/normal-speech.wav")
  }

  /// What the committed clip says (`WhisperProductionWiringRealBoundaryTests.expectedWords`).
  nonisolated static let expectedWords =
    "the quick brown fox jumps over the lazy dog while the morning sun rises slowly above the quiet hills"

  nonisolated static var ultraDirectory: URL {
    ParakeetInstallLocation.directory(for: .ultra, dataDirectory: StorageRoot.live.dataDirectory)
  }

  nonisolated static var ultraIsInstalled: Bool {
    AsrModels.modelsExist(at: ultraDirectory, version: .ultra)
  }

  nonisolated static var whisperModel: URL {
    StorageRoot.live.dataDirectory.appending(
      path: "Models/whisper-gguf/whisper-large-v3-turbo-Q8_0.gguf")
  }

  nonisolated static var whisperIsInstalled: Bool {
    let size =
      (try? FileManager.default.attributesOfItem(atPath: whisperModel.path)[.size]) as? NSNumber
    return size?.int64Value == 886_381_760
  }

  nonisolated static func words(_ text: String) -> [String] {
    text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
  }

  /// Records what the real copies actually loaded, then forwards.
  @MainActor
  final class RecordingEngines: ImportedASREngines {
    let inner: ImportedEngineCopies
    var loadedParakeet: [ParakeetModelSelection] = []
    var loads: [ImportedASRSelection] = []
    init(_ inner: ImportedEngineCopies) { self.inner = inner }
    func load(_ selection: ImportedASRSelection) async throws {
      loads.append(selection)
      try await inner.load(selection)
      if let loaded = inner.loadedParakeetSelection { loadedParakeet.append(loaded) }
    }
    func transcribe(_ samples: [Float], language: String?) async throws -> EnviousWisprCore.ASRResult {
      try await inner.transcribe(samples, language: language)
    }
    func unload() async { await inner.unload() }
  }

  private func run(selection: ImportedASRSelection, whisperEngine: LiveMeetingWhisperEngine)
    async throws -> (
      outcome: ImportedRetranscriptionOutcome, row: Transcript?, engines: RecordingEngines,
      lease: EngineLease
    )
  {
    let dir = TestTemporaryDirectory.url
      .appendingPathComponent("ew-3147-retranscribe-real-\(UUID().uuidString)", isDirectory: true)
    let history = TranscriptCoordinator(store: TranscriptStore(directory: dir))
    let identity = try await ImportedSourceFingerprint.read(url: Self.clip)
    let row = Transcript(
      text: "words from an older transcription", duration: 5, importedFileName: "normal-speech.wav",
      sourceBookmark: Data([1]), sourceFingerprint: identity.fingerprint,
      importAttemptID: UUID())
    try await history.saveAndShow(row)
    let resolved = ResolvedImportedSource(
      rowID: row.id, reference: ImportedSourceReference(row), url: Self.clip, identity: identity)
    let sources = TranscriptRetranscriptionTests.FakeSources { _ in .available(resolved) }

    let lease = EngineLease()
    let engines = RecordingEngines(
      ImportedEngineCopies(
        parakeet: .init(
          offlineModeAdmission: ASRManager(
            engineMutationScope: .alwaysAllowedForTesting,
            parakeetSelection: ParakeetSelectionProvider()),
          isModelSourceUsable: { true }, isInstallAdmitted: { _ in true },
          modelUseGate: MeetingModelUseGate()),
        whisper: .live(
          engine: whisperEngine, admittedModelPath: { Self.whisperModel.path },
          isDeliveryEnabled: { true })))
    // The real deterministic chain with no polisher: what an import gets with polish off.
    let runner = FileImportRunner(
      keychainManager: KeychainManager(), localPolishers: .llamaForTests)
    let transcriber = ImportedFileTranscriber(
      admission: .live(lease: lease, as: .fileImport), engines: engines,
      cleanup: .init(
        freeze: { backend in
          let settings = RecordingSettingsSnapshot(
            backendType: backend, backendSupportsLanguageDetection: backend == .whisper,
            languageMode: .locked("en"), wordCorrectionEnabled: false,
            fillerRemovalEnabled: false, emojiFormatterEnabled: false,
            spokenPunctuationEnabled: false, spokenPunctuationStartWords: nil,
            spokenPunctuationEnglishPeriodWord: nil, llmProvider: LLMProvider.none.rawValue,
            llmModel: "", egOneSize: nil, s1Control: nil, englishSpelling: nil,
            casualModeEnabled: false)
          runner.freeze(settings: settings, vocabulary: nil, cloudModelList: nil)
          return .init(
            settings: settings,
            configuration: FileImportCoordinator.RunConfiguration(
              polishIsCloud: false, localPolishModel: nil, polishProvider: .none,
              ollamaModel: nil, polishModel: "", backendType: backend))
        },
        prepareLocalPolish: { _ in true },
        processParts: { parts, language, onOutcome in
          try await runner.process(parts: parts, engineLanguage: language, onOutcome: onOutcome)
        },
        release: { runner.releaseCheckerSelections() }))
    let owner = TranscriptRetranscription(
      history: history, sources: sources, transcriber: transcriber, installedModels: { [] })
    let outcome = await owner.startConfirmed(rowID: row.id, selection: selection)
    return (outcome, history.currentRow(id: row.id), engines, lease)
  }

  @Test(
    "the installed Parakeet Ultra transcribes a real file again and replaces the entry",
    .enabled(if: TranscriptRetranscriptionRealBoundaryTests.ultraIsInstalled),
    .tags(.realBoundary), .timeLimit(.minutes(3)), .realBoundaryRun)
  func parakeetUltra() async throws {
    let selection = ParakeetModelSelection(
      model: .ultra, revision: nil, directory: Self.ultraDirectory, cacheOnly: true,
      displayBytes: 1, repairable: false, generation: 0)
    let whisperEngine = LiveMeetingWhisperEngine(driver: LiveWhisperExecutorDriver())
    let result = try await run(
      selection: .parakeet(
        selection, identity: ASRModelIdentity(name: "parakeet-ultra", revision: nil, variant: nil)),
      whisperEngine: whisperEngine)
    #expect(result.outcome == .replaced)
    #expect(result.engines.loadedParakeet == [selection], "the chosen model was the one loaded")
    let row = try #require(result.row)
    #expect(row.backendType == .parakeet)
    let heard = Self.words(row.text)
    #expect(heard.count >= 15, "real words, not an empty decode: \(row.text)")
    #expect(heard.contains("fox") && heard.contains("hills"), "\(row.text)")
    #expect(row.processedText != nil, "the deterministic cleanup ran")
    #expect(result.lease.currentHolder == nil, "the engine is free afterwards")
    #expect(await whisperEngine.isLoaded == false)
  }

  @Test(
    "the installed Whisper transcribes a real file again and replaces the entry",
    .enabled(if: TranscriptRetranscriptionRealBoundaryTests.whisperIsInstalled),
    .tags(.realBoundary), .timeLimit(.minutes(3)), .realBoundaryRun)
  func whisperTurbo() async throws {
    let whisperEngine = LiveMeetingWhisperEngine(driver: LiveWhisperExecutorDriver())
    let result = try await run(
      selection: .whisper(
        modelFile: Self.whisperModel,
        identity: ASRModelIdentity(name: "whisper-large-v3-turbo", revision: nil, variant: "Q8_0")),
      whisperEngine: whisperEngine)
    #expect(result.outcome == .replaced)
    let row = try #require(result.row)
    #expect(row.backendType == .whisper)
    #expect(Self.words(row.text) == Self.words(Self.expectedWords), "\(row.text)")
    #expect(row.processedText != nil, "the deterministic cleanup ran")
    #expect(result.lease.currentHolder == nil, "the engine is free afterwards")
    #expect(await whisperEngine.isLoaded == false, "the copy was freed")
  }
}
