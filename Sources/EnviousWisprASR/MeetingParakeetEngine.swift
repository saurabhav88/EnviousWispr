import EnviousWisprCore
import Foundation

/// What `MeetingParakeetEngine` needs from a speech backend. `ParakeetBackend` in production; a
/// fake in tests.
protocol MeetingSpeechBackend: Actor {
  func prepareMeeting(selection: ParakeetModelSelection) async throws
  func transcribeMeeting(samples: [Float], language: String?) async throws -> ASRResult
  func unload() async
}

extension ParakeetBackend: MeetingSpeechBackend {
  func prepareMeeting(selection: ParakeetModelSelection) async throws {
    try await prepare(selection: selection, progressCallback: nil)
  }

  func transcribeMeeting(samples: [Float], language: String?) async throws -> ASRResult {
    var options = TranscriptionOptions.default
    options.language = language
    return try await transcribe(audioSamples: samples, options: options)
  }
}

/// The Parakeet engine EnviousMeet transcribes with (#3972 §3.4, R4, R13, R17, R24).
///
/// Its OWN `ParakeetBackend` instance, never dictation's or recovery's: one backend actor shared
/// by two callers is not safe across its awaits (Codex consult r1 Q3), and a dictation must never
/// wait behind a meeting piece. It is resident only while a meeting pass runs, and it never
/// claims `EngineLease`, spends dictation's load accounting or publishes a load as dictation's
/// serving model (`ParakeetSelectionProvider` is never touched).
///
/// **Offline mode.** FluidAudio's `ModelHub.offlineMode` is process-global, so a second backend
/// does not isolate it; the existing owner (`ASRManager.admitOfflineMode`) still decides. A
/// meeting load is cache-only. When another load holds the other mode the load throws
/// `offlineModeBusy` at once (no vendor call, nothing spent); the caller waits on
/// `waitUntilOfflineModeAvailable()`, which ends on that load's release, and tries again.
///
/// **One operation at a time.** Load, transcribe and unload run strictly in order: each waits
/// for the previous one to return. An operation is an unstructured task, so a cancelled caller
/// never starts a second native call over one still running (R13); unload therefore waits for
/// an in-flight load or decode to finish before it frees the model.
@MainActor
package final class MeetingParakeetEngine {
  package enum EngineError: Error, Equatable {
    case notCacheOnly
    case notLoaded
    /// Another load holds the other offline mode; wait and retry.
    case offlineModeBusy
    /// The installed model may not be read now (model delivery is off).
    case modelSourceUnavailable
  }

  private let admission: ASRManager
  private let makeBackend: () -> any MeetingSpeechBackend
  private let isModelSourceUsable: @MainActor () -> Bool
  private var backend: (any MeetingSpeechBackend)?
  private(set) package var loadedSelection: ParakeetModelSelection?
  /// The last queued operation; the next one starts after it.
  private var tail: Task<Void, Never>?

  /// `isModelSourceUsable`: false while model delivery is off. Read in the same MainActor turn
  /// as the offline-mode admission, so a delivery switch cannot slip between the two.
  package convenience init(
    offlineModeAdmission: ASRManager, isModelSourceUsable: @escaping @MainActor () -> Bool
  ) {
    self.init(
      offlineModeAdmission: offlineModeAdmission, makeBackend: { ParakeetBackend() },
      isModelSourceUsable: isModelSourceUsable)
  }

  init(
    offlineModeAdmission: ASRManager, makeBackend: @escaping () -> any MeetingSpeechBackend,
    isModelSourceUsable: @escaping @MainActor () -> Bool = { true }
  ) {
    self.admission = offlineModeAdmission
    self.makeBackend = makeBackend
    self.isModelSourceUsable = isModelSourceUsable
  }

  package var isLoaded: Bool { loadedSelection != nil }

  /// Whether `error` means "another load holds the other offline mode": temporary, never a
  /// missing or broken model.
  package nonisolated static func isTemporaryContention(_ error: Error) -> Bool {
    (error as? EngineError) == .offlineModeBusy
  }

  /// Loads the installed model `selection` names, from the admitted cache only. A load of the
  /// selection already loaded does nothing; a different selection replaces it.
  package func load(selection: ParakeetModelSelection) async throws {
    try await serialized { try await self.loadNow(selection) }
  }

  /// Transcribes one bounded piece. `samples` are 16 kHz mono; word times are relative to the
  /// piece's first sample.
  package func transcribe(samples: [Float], language: String?) async throws -> ASRResult {
    try await serialized {
      guard let backend = self.backend else { throw EngineError.notLoaded }
      return try await backend.transcribeMeeting(samples: samples, language: language)
    }
  }

  /// Frees the model, after any operation already running has returned.
  package func unload() async {
    _ = try? await serialized { await self.unloadNow() }
  }

  /// Returns once a cache-only load would be admitted (the conflicting load released).
  /// Throws `CancellationError` when the caller is cancelled while waiting.
  package func waitUntilOfflineModeAvailable() async throws {
    try await admission.waitUntilOfflineModeAdmissible(cacheOnly: true)
  }

  private func loadNow(_ selection: ParakeetModelSelection) async throws {
    guard selection.cacheOnly else { throw EngineError.notCacheOnly }
    if loadedSelection == selection { return }
    if backend != nil { await unloadNow() }
    // No await between this check and the admission below.
    guard isModelSourceUsable() else { throw EngineError.modelSourceUnavailable }
    do {
      try admission.admitOfflineMode(cacheOnly: true)
    } catch is ParakeetOfflineModeConflictError {
      throw EngineError.offlineModeBusy
    }
    defer { admission.releaseOfflineModeAdmission() }
    let fresh = makeBackend()
    do {
      try await fresh.prepareMeeting(selection: selection)
    } catch {
      // Whatever the failed prepare built is released before this throws.
      await fresh.unload()
      throw error
    }
    backend = fresh
    loadedSelection = selection
  }

  private func unloadNow() async {
    guard let backend else { return }
    self.backend = nil
    loadedSelection = nil
    await backend.unload()
  }

  private func serialized<T: Sendable>(
    _ operation: @escaping @MainActor () async throws -> T
  ) async throws -> T {
    let previous = tail
    let task = Task { @MainActor in
      await previous?.value
      return try await operation()
    }
    tail = Task { _ = await task.result }
    return try await task.value
  }
}
