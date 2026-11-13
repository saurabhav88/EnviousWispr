import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprAppKit
@testable import EnviousWisprPipeline

extension Result where Success == Transcript, Failure == ImportedFileTranscriber.Failure {
  /// The failure, or nil on success (`Transcript` is not `Equatable`).
  var failure: ImportedFileTranscriber.Failure? {
    if case .failure(let reason) = self { return reason }
    return nil
  }
}

/// Test doubles shared by the Transcribe again with suites (#3147 PR3 lane C).
@MainActor
final class FakeImportedEngines: ImportedASREngines {
  var loads: [ImportedASRSelection] = []
  var transcribedLanguages: [String?] = []
  var unloads = 0
  var loadError: (any Error)?
  var transcribeError: (any Error)?
  var result = ASRResult(
    text: "fresh words from the file", language: "en", duration: 1, processingTime: 0.5,
    backendType: .whisper)
  /// When true, `transcribe` waits inside its "native call" until `releaseTranscribe()`,
  /// ignoring cancellation, as a running Core ML or ggml decode does.
  var holdsTranscribe = false
  var onTranscribeEntered: (@MainActor () async -> Void)?
  private(set) var isInsideTranscribe = false
  private var enteredWaiter: CheckedContinuation<Void, Never>?
  private var release: CheckedContinuation<Void, Never>?

  func load(_ selection: ImportedASRSelection) async throws {
    loads.append(selection)
    if let loadError { throw loadError }
  }

  func transcribe(_ samples: [Float], language: String?) async throws -> ASRResult {
    transcribedLanguages.append(language)
    await onTranscribeEntered?()
    if holdsTranscribe {
      isInsideTranscribe = true
      enteredWaiter?.resume()
      enteredWaiter = nil
      await withCheckedContinuation { release = $0 }
      isInsideTranscribe = false
    }
    if let transcribeError { throw transcribeError }
    return result
  }

  func unload() async { unloads += 1 }

  /// Returns once `transcribe` is inside its held native call (the subject's own signal).
  func waitUntilInsideTranscribe() async {
    if isInsideTranscribe { return }
    await withCheckedContinuation { enteredWaiter = $0 }
  }

  func releaseTranscribe() {
    release?.resume()
    release = nil
  }
}

@MainActor
final class ImportedTranscriberRig {
  let lease = EngineLease()
  let engines = FakeImportedEngines()
  var frozenBackends: [ASRBackendType] = []
  var releases = 0
  var polisherReady = true
  var processedParts: [[String]] = []
  /// Per part: the polished words, or nil for a part whose polish failed.
  var polish: (Int, String) -> String? = { index, piece in "Polished \(index): \(piece)" }
  var processThrowsAfter: Int?
  var identityNow = ImportedSourceIdentity(byteCount: 10, durationMs: 1000, digest: "aa")
  var languageMode: LanguageMode = .auto
  var installed: [ImportedASRChoice] = []

  static let identity = ImportedSourceIdentity(byteCount: 10, durationMs: 1000, digest: "aa")
  static let parakeetChoice = ImportedASRSelection.parakeet(
    ParakeetModelSelection(
      model: .ultra, revision: "r1", directory: URL(fileURLWithPath: "/tmp/ultra"),
      cacheOnly: true, displayBytes: 1, repairable: false, generation: 1),
    identity: ASRModelIdentity(name: "parakeet-ultra", revision: "r1", variant: nil))
  static let whisperChoice = ImportedASRSelection.whisper(
    modelFile: URL(fileURLWithPath: "/tmp/whisper-large-v3-turbo-Q8_0.gguf"),
    identity: ASRModelIdentity(name: "whisper-large-v3-turbo", revision: nil, variant: "Q8_0"))

  func snapshot(_ backend: ASRBackendType) -> RecordingSettingsSnapshot {
    RecordingSettingsSnapshot(
      backendType: backend, backendSupportsLanguageDetection: backend == .whisper,
      languageMode: languageMode, wordCorrectionEnabled: true, fillerRemovalEnabled: false,
      emojiFormatterEnabled: false, spokenPunctuationEnabled: false,
      spokenPunctuationStartWords: nil, spokenPunctuationEnglishPeriodWord: nil,
      llmProvider: LLMProvider.egOne.rawValue, llmModel: "eg-1", egOneSize: nil,
      s1Control: nil, englishSpelling: nil, casualModeEnabled: false)
  }

  func makeTranscriber() -> ImportedFileTranscriber {
    ImportedFileTranscriber(
      admission: .live(lease: lease, as: .fileImport),
      engines: engines,
      cleanup: .init(
        freeze: { [unowned self] backend in
          frozenBackends.append(backend)
          return .init(
            settings: snapshot(backend),
            configuration: FileImportCoordinator.RunConfiguration(
              polishIsCloud: false, localPolishModel: nil, polishProvider: .egOne,
              ollamaModel: nil, polishModel: "eg-1", backendType: backend))
        },
        prepareLocalPolish: { [unowned self] _ in polisherReady },
        processParts: { [unowned self] pieces, _, onOutcome in
          processedParts.append(pieces)
          for (index, piece) in pieces.enumerated() {
            if let limit = processThrowsAfter, index >= limit {
              throw CancellationError()
            }
            let polished = polish(index, piece)
            guard
              onOutcome(
                index, FileImportRunner.PartOutcome(text: piece, polishedText: polished))
            else { return }
          }
        },
        release: { [unowned self] in releases += 1 }),
      decode: { _ in
        AudioFileDecoder.Decoded(
          samples: [Float](repeating: 0.1, count: 16_000), seconds: 1, byteCount: 10,
          codec: "PCM", sampleRate: 16_000, channelCount: 1)
      },
      readIdentity: { [identityNow] _ in identityNow })
  }

  /// True when nothing holds the shared engine any more.
  var engineIsFree: Bool { lease.currentHolder == nil }
}

/// Class: `.productOutcome`: when these fail, Transcribe again with runs a model the user did not
/// choose, cleans with the global engine's settings, loses a cleaned part's words, or leaves the
/// engine claimed so dictation stays refused.
@MainActor
@Suite("Imported file transcriber (#3147 PR3)", .tags(.productOutcome), .timeLimit(.minutes(1)))
struct ImportedFileTranscriberTests {

  @Test("the chosen engine runs, settings freeze for it, and the words are cleaned")
  func chosenEngineAndCleanup() async throws {
    let rig = ImportedTranscriberRig()
    rig.languageMode = .locked("de")
    let outcome = await rig.makeTranscriber().transcribe(
      url: URL(fileURLWithPath: "/tmp/talk.m4a"), identity: ImportedTranscriberRig.identity,
      selection: ImportedTranscriberRig.whisperChoice)
    let row = try outcome.get()
    #expect(rig.engines.loads == [ImportedTranscriberRig.whisperChoice])
    #expect(rig.frozenBackends == [.whisper], "frozen for the chosen engine, not the global one")
    #expect(rig.engines.transcribedLanguages == ["de"], "the frozen lock reaches the engine")
    #expect(row.text == "fresh words from the file")
    #expect(row.backendType == .whisper)
    #expect(row.polishedText == "Polished 0: fresh words from the file")
    #expect(row.processedText == row.polishedText)
    #expect(row.llmProvider == LLMProvider.egOne.rawValue)
    #expect(row.turns == nil, "no turn can index the new words")
    #expect(rig.engines.unloads == 1)
    #expect(rig.releases == 1)
    #expect(rig.engineIsFree)
  }

  @Test("a part whose polish failed keeps its words; a refused polisher keeps the raw words")
  func cleanupFloors() async throws {
    let words = (0..<1_400).map { "word\($0)" }.joined(separator: " ")
    let rig = ImportedTranscriberRig()
    rig.engines.result = ASRResult(
      text: words, language: nil, duration: 1, processingTime: 0.1, backendType: .parakeet)
    rig.polish = { index, piece in index == 0 ? nil : "P\(index)" }
    let row = try await rig.makeTranscriber().transcribe(
      url: URL(fileURLWithPath: "/tmp/talk.m4a"), identity: ImportedTranscriberRig.identity,
      selection: ImportedTranscriberRig.parakeetChoice
    ).get()
    let pieces = try #require(rig.processedParts.first)
    #expect(pieces.count > 1, "a long transcript is cut into parts")
    let document = try #require(row.processedText)
    #expect(document.hasPrefix(pieces[0]), "the failed part keeps its own words")
    #expect(document.contains("P1"))
    #expect(row.polishedText == document)

    let refused = ImportedTranscriberRig()
    refused.polisherReady = false
    let raw = try await refused.makeTranscriber().transcribe(
      url: URL(fileURLWithPath: "/tmp/talk.m4a"), identity: ImportedTranscriberRig.identity,
      selection: ImportedTranscriberRig.parakeetChoice
    ).get()
    #expect(raw.text == "fresh words from the file")
    #expect(raw.processedText == nil && raw.polishedText == nil)
    #expect(refused.processedParts.isEmpty)
  }

  @Test("an engine held by a dictation refuses before anything freezes or loads")
  func busyRefusesFirst() async {
    let rig = ImportedTranscriberRig()
    guard case .granted(let dictation) = rig.lease.admit(.dictation) else {
      Issue.record("the dictation claim was refused")
      return
    }
    let outcome = await rig.makeTranscriber().transcribe(
      url: URL(fileURLWithPath: "/tmp/talk.m4a"), identity: ImportedTranscriberRig.identity,
      selection: ImportedTranscriberRig.parakeetChoice)
    #expect(outcome.failure == .busy)
    #expect(rig.engines.loads.isEmpty && rig.frozenBackends.isEmpty && rig.releases == 0)
    rig.lease.release(dictation)
  }

  @Test("a file changed since History identified it is refused and nothing is transcribed")
  func changedFileRefused() async {
    let rig = ImportedTranscriberRig()
    rig.identityNow = ImportedSourceIdentity(byteCount: 11, durationMs: 1000, digest: "bb")
    let outcome = await rig.makeTranscriber().transcribe(
      url: URL(fileURLWithPath: "/tmp/talk.m4a"), identity: ImportedTranscriberRig.identity,
      selection: ImportedTranscriberRig.parakeetChoice)
    #expect(outcome.failure == .sourceChanged)
    #expect(rig.engines.loads.isEmpty)
    #expect(rig.releases == 1 && rig.engineIsFree)
  }

  @Test("a model that is not installed fails, unloads once and frees the engine")
  func missingModel() async {
    let rig = ImportedTranscriberRig()
    rig.engines.loadError = ImportedModelUnavailable()
    let outcome = await rig.makeTranscriber().transcribe(
      url: URL(fileURLWithPath: "/tmp/talk.m4a"), identity: ImportedTranscriberRig.identity,
      selection: ImportedTranscriberRig.whisperChoice)
    #expect(outcome.failure == .modelUnavailable)
    #expect(rig.engines.unloads == 1 && rig.releases == 1 && rig.engineIsFree)
    #expect(rig.processedParts.isEmpty)
  }

  @Test("Cancel during a decode waits for it, unloads and frees the engine exactly once")
  func cancelDrains() async {
    let rig = ImportedTranscriberRig()
    rig.engines.holdsTranscribe = true
    let transcriber = rig.makeTranscriber()
    let task = Task {
      await transcriber.transcribe(
        url: URL(fileURLWithPath: "/tmp/talk.m4a"), identity: ImportedTranscriberRig.identity,
        selection: ImportedTranscriberRig.parakeetChoice)
    }
    await rig.engines.waitUntilInsideTranscribe()
    task.cancel()
    #expect(transcriber.isEngineHeld, "the claim is kept while the native call runs")
    #expect(rig.engineIsFree == false)
    rig.engines.releaseTranscribe()
    let outcome = await task.value
    #expect(outcome.failure == .cancelled)
    #expect(rig.engines.unloads == 1 && rig.releases == 1)
    #expect(rig.engineIsFree && transcriber.isEngineHeld == false && transcriber.heldRun == nil)
    #expect(rig.processedParts.isEmpty, "a cancelled run cleans nothing")
  }
}

/// Class: `.productOutcome`: when these fail, Transcribe again with loads a model other than
/// the chosen one, downloads, or lets Remove delete a model while it is being read.
@MainActor
@Suite("Imported engine copies (#3147 PR3)", .tags(.productOutcome), .timeLimit(.minutes(1)))
struct ImportedEngineCopiesTests {

  actor FakeSpeechBackend: MeetingSpeechBackend {
    var prepared: [ParakeetModelSelection] = []
    var unloaded = 0
    func prepareMeeting(selection: ParakeetModelSelection) async throws {
      prepared.append(selection)
    }
    func transcribeMeeting(samples: [Float], language: String?) async throws -> ASRResult {
      ASRResult(
        text: "parakeet words", language: nil, duration: 1, processingTime: 0.1,
        backendType: .parakeet)
    }
    func unload() async { unloaded += 1 }
  }

  private func copies(
    backend: FakeSpeechBackend, gate: MeetingModelUseGate, admitted: Bool = true,
    whisperPath: String? = "/tmp/whisper-large-v3-turbo-Q8_0.gguf",
    whisperLoads: @escaping @MainActor (String) -> Void = { _ in }
  ) -> ImportedEngineCopies {
    ImportedEngineCopies(
      parakeet: .init(
        offlineModeAdmission: ASRManager(
          engineMutationScope: .alwaysAllowedForTesting,
          parakeetSelection: ParakeetSelectionProvider()),
        isModelSourceUsable: { true }, isInstallAdmitted: { _ in admitted },
        modelUseGate: gate, makeBackend: { backend }),
      whisper: .init(
        admittedModelPath: { whisperPath }, isDeliveryEnabled: { true },
        load: { whisperLoads($0) },
        transcribe: { _, _ in
          ASRResult(
            text: "whisper words", language: "en", duration: 1, processingTime: 0.1,
            backendType: .whisper)
        },
        unload: {}))
  }

  @Test("a Parakeet copy loads the chosen install and holds it against Remove until unloaded")
  func parakeetHoldsInstall() async throws {
    let gate = MeetingModelUseGate()
    let backend = FakeSpeechBackend()
    let engines = copies(backend: backend, gate: gate)
    guard case .parakeet(let selection, _) = ImportedTranscriberRig.parakeetChoice else { return }
    let key = MeetingModelUseGate.key(forInstallDirectory: selection.directory)
    try await engines.load(ImportedTranscriberRig.parakeetChoice)
    #expect(await backend.prepared == [selection])
    #expect(engines.loadedParakeetSelection == selection)
    #expect(await gate.isInUse(key))
    let words = try await engines.transcribe([0.1], language: nil)
    #expect(words.text == "parakeet words")

    let removal = Task { try await gate.beginMutation(key) }
    await gate.waitForMutationRequest()
    #expect(await gate.isInUse(key), "Remove waits while the copy is loaded")
    await engines.unload()
    try await removal.value
    #expect(await backend.unloaded == 1)
    #expect(await gate.isInUse(key) == false)
    await gate.endMutation(key)
  }

  @Test("a Parakeet install that is no longer admitted is not loaded, and its hold ends")
  func parakeetNotAdmitted() async {
    let gate = MeetingModelUseGate()
    let backend = FakeSpeechBackend()
    let engines = copies(backend: backend, gate: gate, admitted: false)
    await #expect(throws: ImportedModelUnavailable.self) {
      try await engines.load(ImportedTranscriberRig.parakeetChoice)
    }
    #expect(await backend.prepared.isEmpty)
    await engines.unload()
    guard case .parakeet(let selection, _) = ImportedTranscriberRig.parakeetChoice else { return }
    #expect(
      await gate.isInUse(MeetingModelUseGate.key(forInstallDirectory: selection.directory))
        == false)
  }

  @Test("a Whisper copy loads only the admitted file the user chose")
  func whisperLoadsOnlyTheChosenFile() async throws {
    var loaded: [String] = []
    let other = copies(
      backend: FakeSpeechBackend(), gate: MeetingModelUseGate(), whisperPath: "/tmp/other.gguf",
      whisperLoads: { loaded.append($0) })
    await #expect(throws: ImportedModelUnavailable.self) {
      try await other.load(ImportedTranscriberRig.whisperChoice)
    }
    let none = copies(
      backend: FakeSpeechBackend(), gate: MeetingModelUseGate(), whisperPath: nil,
      whisperLoads: { loaded.append($0) })
    await #expect(throws: ImportedModelUnavailable.self) {
      try await none.load(ImportedTranscriberRig.whisperChoice)
    }
    #expect(loaded.isEmpty)
    let chosen = copies(
      backend: FakeSpeechBackend(), gate: MeetingModelUseGate(),
      whisperLoads: { loaded.append($0) })
    try await chosen.load(ImportedTranscriberRig.whisperChoice)
    #expect(loaded == ["/tmp/whisper-large-v3-turbo-Q8_0.gguf"])
    #expect(try await chosen.transcribe([0.1], language: "en").text == "whisper words")
  }
}
