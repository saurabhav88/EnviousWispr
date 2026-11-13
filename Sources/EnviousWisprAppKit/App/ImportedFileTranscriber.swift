import EnviousWisprASR
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprPipeline
import Foundation

/// #3147 PR3: one imported file transcribed again with the engine and model the user chose
/// (Transcribe again with), then cleaned by the file-import cleanup policy with settings frozen
/// for THAT engine. It produces the new content; `TranscriptRetranscription` decides whether it
/// may replace the row.
///
/// **It never touches the shared dictation engine or any global setting.** The chosen model runs
/// on a copy only this job uses (`ImportedASREngines`), so the model that runs is the selection
/// itself, never whatever dictation happens to serve; nothing is switched, and nothing is
/// downloaded (a model that is not installed now fails the run). The import wizard's
/// `choose`/`start` are not used: they read the shared engine selection and save a NEW row.
///
/// **One engine claim, released only after the physical work exits.** The claim is the same
/// `.fileImport` lease the wizard takes, so a dictation, a crash replay or a wizard run cannot
/// start while this one decodes or cleans, and an engine switch defers until it ends. The claim
/// goes back only after the engine copy has unloaded (its native call drained) and the cleanup
/// returned, on every exit, cancellation included, and exactly once.
@MainActor
final class ImportedFileTranscriber {

  /// Why a run produced no content. Every one leaves the History row as it was.
  enum Failure: Error, Equatable, Sendable {
    /// Another workload holds the engine.
    case busy
    /// The file read now is not the one identified before the run.
    case sourceChanged
    /// The chosen model is not installed or not usable now. Nothing is downloaded.
    case modelUnavailable
    /// The engine heard no words.
    case noSpeech
    case failed
    case cancelled
  }

  /// What a run froze when it claimed the engine: the cleanup settings for the chosen engine,
  /// and the run configuration derived from them.
  struct FrozenRun: Sendable, Equatable {
    let settings: RecordingSettingsSnapshot
    let configuration: FileImportCoordinator.RunConfiguration
  }

  /// The file-import cleanup primitives, wired to the same owners the wizard uses.
  struct Cleanup {
    /// Freezes the file-cleanup settings for `backend` (an explicit-backend freeze, so the
    /// language lock and the spelling follow the CHOSEN engine, never the global one), freezes
    /// the cleanup runner with them, and returns the run configuration. Called once, under the
    /// claim.
    let freeze: @MainActor (ASRBackendType) -> FrozenRun
    /// Readies the bundled local polisher the configuration names, and holds it for this run.
    /// False refuses the cleanup; the transcription still stands.
    let prepareLocalPolish: @MainActor (FileImportCoordinator.RunConfiguration) async -> Bool
    /// Runs the pieces through the frozen chain in order (`FileImportRunner.process(parts:)`).
    let processParts: FileImportCoordinator.ProcessParts
    /// After the physical work: releases the polisher hold and the cleanup's cached selections.
    let release: @MainActor () -> Void
  }

  private let admission: EngineAdmissionAccess
  private let engines: any ImportedASREngines
  private let decode: @Sendable (URL) async throws -> AudioFileDecoder.Decoded
  private let readIdentity: @Sendable (URL) async throws -> ImportedSourceIdentity
  private let cleanup: Cleanup
  private let captureASRFailure: @MainActor (any Error, ASRBackendType) -> Void

  /// The run holding the engine now, so the settings gates that defer tearing down a polisher
  /// or an Ollama model in use can see it (the wizard's `pinnedLocalPolishModel` twins). Nil
  /// once the claim is released.
  private(set) var heldRun: FrozenRun?
  /// Whether a run physically holds the engine claim (claim to release, which outlasts Cancel).
  private(set) var isEngineHeld = false

  init(
    admission: EngineAdmissionAccess,
    engines: any ImportedASREngines,
    cleanup: Cleanup,
    decode: @escaping @Sendable (URL) async throws -> AudioFileDecoder.Decoded = {
      try await AudioFileDecoder.decode(url: $0)
    },
    readIdentity: @escaping @Sendable (URL) async throws -> ImportedSourceIdentity = {
      try await ImportedSourceFingerprint.read(url: $0)
    },
    captureASRFailure: @escaping @MainActor (any Error, ASRBackendType) -> Void = { _, _ in }
  ) {
    self.admission = admission
    self.engines = engines
    self.cleanup = cleanup
    self.decode = decode
    self.readIdentity = readIdentity
    self.captureASRFailure = captureASRFailure
  }

  /// Transcribes the file at `url`, which must still be the file `identity` names, with
  /// `selection`, and cleans the words. The returned `Transcript` carries only the new
  /// transcription's fields (words, cleaned document, language, engine, polish credit); it has
  /// no turns, so no old speaker range can index the new words.
  func transcribe(
    url: URL, identity: ImportedSourceIdentity, selection: ImportedASRSelection
  ) async -> Result<Transcript, Failure> {
    if Task.isCancelled { return .failure(.cancelled) }
    let token: EngineLease.Token
    switch admission.claim() {
    case .granted(let granted): token = granted
    case .refused: return .failure(.busy)
    }
    isEngineHeld = true
    var froze = false
    let outcome = await runHoldingClaim(
      url: url, identity: identity, selection: selection, froze: &froze)
    // Every path of the run has unloaded the engine copy and returned from the cleanup by now.
    // The guards clear BEFORE the release retries run (the wizard's order): a deferred Ollama
    // eviction or classifier release retried while this job still read as holding the engine
    // would only defer again.
    heldRun = nil
    isEngineHeld = false
    admission.release(token)
    if froze { cleanup.release() }
    return outcome
  }

  private func runHoldingClaim(
    url: URL, identity: ImportedSourceIdentity, selection: ImportedASRSelection,
    froze: inout Bool
  ) async -> Result<Transcript, Failure> {
    let backend = selection.backendType
    let frozen = cleanup.freeze(backend)
    froze = true
    heldRun = frozen

    var decoded: AudioFileDecoder.Decoded?
    do {
      decoded = try await decode(url)
    } catch {
      return .failure(Task.isCancelled ? .cancelled : .failed)
    }
    if Task.isCancelled { return .failure(.cancelled) }
    // The words must come from the identified file: read its identity after the decode, so a
    // file replaced since History looked it up is refused rather than transcribed.
    guard let after = try? await readIdentity(url), after == identity else {
      return .failure(Task.isCancelled ? .cancelled : .sourceChanged)
    }
    if Task.isCancelled { return .failure(.cancelled) }

    var language: String?
    if case .locked(let code) = frozen.settings.languageMode { language = code }
    let asr: ASRResult
    do {
      try await engines.load(selection)
      if Task.isCancelled { throw CancellationError() }
      asr = try await engines.transcribe(decoded?.samples ?? [], language: language)
    } catch {
      decoded = nil
      // Drains any native call still running, frees the copy and ends its model hold.
      await engines.unload()
      if Task.isCancelled || error is CancellationError { return .failure(.cancelled) }
      if error is ImportedModelUnavailable { return .failure(.modelUnavailable) }
      captureASRFailure(error, backend)
      return .failure(.failed)
    }
    decoded = nil
    await engines.unload()
    if Task.isCancelled { return .failure(.cancelled) }
    guard !asr.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return .failure(.noSpeech)
    }
    return await clean(asr, backend: backend, configuration: frozen.configuration)
  }

  /// The wizard's cleanup policy (`FileImportCoordinator.polishAll`), applied to a document with
  /// no turns: the raw words are the floor, a refused polisher keeps them uncleaned, a part that
  /// could not be cleaned keeps its words, and a cancelled run produces nothing.
  private func clean(
    _ asr: ASRResult, backend: ASRBackendType,
    configuration: FileImportCoordinator.RunConfiguration
  ) async -> Result<Transcript, Failure> {
    let raw = asr.text
    let base = Transcript(
      text: raw, language: asr.language, processingTime: asr.processingTime,
      backendType: backend)
    let cut = FileImportDocumentMath.cleanupPieces(
      turns: nil, rawText: raw,
      maximumWords: FileImportDocumentMath.partCeiling(configuration))
    guard !cut.pieces.isEmpty else {
      return .success(
        base.withImportResult(
          raw, wasPolished: false, llmProvider: configuration.polishProvider.rawValue,
          llmModel: configuration.polishModel))
    }
    let polisherReady = await cleanup.prepareLocalPolish(configuration)
    if Task.isCancelled { return .failure(.cancelled) }
    // The wizard keeps the transcription and refuses only the cleanup.
    guard polisherReady else { return .success(base) }

    var parts: [FileImportCoordinator.Part] = []
    do {
      try await cleanup.processParts(cut.pieces, asr.language) { index, outcome in
        guard !Task.isCancelled, index == parts.count, cut.pieces.indices.contains(index)
        else { return false }
        parts.append(
          FileImportCoordinator.Part(
            id: index, text: outcome.displayText, isUnpolished: outcome.isUnpolished,
            wasPolished: outcome.polishedText != nil,
            polishWasAttempted: outcome.wasPolishAttempted, cloudSetup: outcome.cloudSetup))
        return true
      }
    } catch {
      // The processor could not finish its roster: accepted parts stand, the rest stay raw.
    }
    if Task.isCancelled { return .failure(.cancelled) }
    for index in parts.count..<cut.pieces.count {
      parts.append(
        FileImportCoordinator.Part(
          id: index, text: cut.pieces[index], isUnpolished: true, wasPolished: false))
    }
    return .success(
      base.withImportResult(
        FileImportDocumentMath.joinedDocument(parts),
        wasPolished: parts.contains(where: \.wasPolished),
        llmProvider: configuration.polishProvider.rawValue, llmModel: configuration.polishModel))
  }
}

extension ImportedASRSelection {
  var backendType: ASRBackendType {
    switch self {
    case .parakeet: .parakeet
    case .whisper: .whisper
    }
  }
}

/// The chosen model is not installed, not admitted or not readable now. Nothing is downloaded.
struct ImportedModelUnavailable: Error, Equatable {}

/// The speech engine a Transcribe again with run uses: a copy of the chosen model only this run
/// loads, held against model removal from `load` until `unload`.
@MainActor
protocol ImportedASREngines: AnyObject {
  /// Loads exactly `selection` from what is installed now; throws `ImportedModelUnavailable`
  /// when it is not installed or usable. The caller always calls `unload()` afterwards.
  func load(_ selection: ImportedASRSelection) async throws
  /// Transcribes 16 kHz mono samples on the loaded copy.
  func transcribe(_ samples: [Float], language: String?) async throws -> ASRResult
  /// Waits for any native call still running, frees the copy and ends the model hold.
  /// Repeatable.
  func unload() async
}

/// The production `ImportedASREngines`: the chosen Parakeet on its own backend (the meeting
/// engine's own-copy primitive, cache-only), or the chosen Whisper on its own executor session
/// (`MeetingWhisperEngine`). Neither publishes a load as dictation's, reads the selected
/// engine, or downloads.
///
/// **Model removal.** A Parakeet copy holds the delivery controller's install-use gate for its
/// install directory from before the load until after the unload, so a Remove or replacement
/// of that install waits for the run (the meeting engine's contract, `MeetingModelUseGate`).
/// A Whisper copy is freed by Remove itself: the composition closes the engine this type is
/// given (`MeetingWhisperEngine.closeForRemoval()`) before the model file goes, which makes a
/// running decode end as a failure that keeps the old row.
@MainActor
final class ImportedEngineCopies: ImportedASREngines {
  struct Parakeet {
    /// The process-wide offline-mode owner a cache-only load is admitted through.
    let offlineModeAdmission: ASRManager
    /// False while model delivery is off: an installed model may not be read.
    let isModelSourceUsable: @MainActor () -> Bool
    /// Whether the install in this directory is the admitted one now.
    let isInstallAdmitted: @MainActor (URL) async -> Bool
    let modelUseGate: MeetingModelUseGate
    var makeBackend: () -> any MeetingSpeechBackend = { ParakeetBackend() }
  }

  struct Whisper {
    /// The admitted model file now, or nil when none is admitted.
    let admittedModelPath: @MainActor () async -> String?
    let isDeliveryEnabled: @MainActor () -> Bool
    let load: @MainActor (_ modelPath: String) async throws -> Void
    let transcribe: @MainActor (_ samples: [Float], _ language: String?) async throws -> ASRResult
    let unload: @MainActor () async -> Void

    /// Bound to an engine instance the composition also closes on Remove.
    static func live(
      engine: LiveMeetingWhisperEngine, admittedModelPath: @escaping @MainActor () async -> String?,
      isDeliveryEnabled: @escaping @MainActor () -> Bool
    ) -> Whisper {
      Whisper(
        admittedModelPath: admittedModelPath, isDeliveryEnabled: isDeliveryEnabled,
        load: { try await engine.load(modelPath: $0) },
        transcribe: { try await engine.transcribe(samples: $0, language: $1) },
        unload: { await engine.unload() })
    }
  }

  private enum Loaded { case parakeet, whisper }

  /// Bounded so an offline mode that keeps changing hands fails the run instead of spinning.
  static let maxContentionAttempts = 3

  private let parakeet: Parakeet
  private let whisper: Whisper
  private let parakeetEngine: MeetingParakeetEngine
  private var attempted: Loaded?
  private var heldUseKey: String?

  init(parakeet: Parakeet, whisper: Whisper) {
    self.parakeet = parakeet
    self.whisper = whisper
    self.parakeetEngine = MeetingParakeetEngine(
      offlineModeAdmission: parakeet.offlineModeAdmission, makeBackend: parakeet.makeBackend,
      isModelSourceUsable: parakeet.isModelSourceUsable)
  }

  /// The Parakeet selection the copy holds now (nil when none), for tests and receipts.
  var loadedParakeetSelection: ParakeetModelSelection? { parakeetEngine.loadedSelection }

  func load(_ selection: ImportedASRSelection) async throws {
    switch selection {
    case .parakeet(let request, _):
      attempted = .parakeet
      guard request.cacheOnly else { throw ImportedModelUnavailable() }
      let key = MeetingModelUseGate.key(forInstallDirectory: request.directory)
      try await parakeet.modelUseGate.beginUse(key)
      heldUseKey = key
      // Asked under the hold: no Remove or replacement can start on this install after this.
      guard await parakeet.isInstallAdmitted(request.directory) else {
        throw ImportedModelUnavailable()
      }
      try await loadParakeet(request)
    case .whisper(let file, _):
      attempted = .whisper
      guard whisper.isDeliveryEnabled(), let path = await whisper.admittedModelPath(),
        URL(fileURLWithPath: path).standardizedFileURL == file.standardizedFileURL
      else { throw ImportedModelUnavailable() }
      try await whisper.load(path)
    }
  }

  private func loadParakeet(_ request: ParakeetModelSelection) async throws {
    for attempt in 1...Self.maxContentionAttempts {
      do {
        try await parakeetEngine.load(selection: request)
        return
      } catch MeetingParakeetEngine.EngineError.notCacheOnly {
        throw ImportedModelUnavailable()
      } catch MeetingParakeetEngine.EngineError.modelSourceUnavailable {
        throw ImportedModelUnavailable()
      } catch
        where MeetingParakeetEngine.isTemporaryContention(error)
        && attempt < Self.maxContentionAttempts
      {
        try await parakeetEngine.waitUntilOfflineModeAvailable()
      }
    }
  }

  func transcribe(_ samples: [Float], language: String?) async throws -> ASRResult {
    switch attempted {
    case .parakeet: return try await parakeetEngine.transcribe(samples: samples, language: language)
    case .whisper: return try await whisper.transcribe(samples, language)
    case nil: throw ImportedModelUnavailable()
    }
  }

  func unload() async {
    switch attempted {
    case .parakeet: await parakeetEngine.unload()
    case .whisper: await whisper.unload()
    case nil: break
    }
    attempted = nil
    // The hold ends only after the copy is gone.
    if let key = heldUseKey {
      heldUseKey = nil
      await parakeet.modelUseGate.endUse(key)
    }
  }
}
