import EnviousWisprASR
import EnviousWisprCore

/// The ONE door for callers that need to load or transcribe on whichever speech
/// engine is currently active, without knowing which one that is (#1386 PR-2).
///
/// It exists because "load the active engine" used to mean one thing —
/// `ASRManagerInterface.loadModel()` — and that is no longer true. Parakeet still
/// loads through the manager (in-process or its XPC helper). WhisperKit must load
/// in-process through the backend the adapter drives, behind its relocation gate:
/// the manager's XPC route would have the helper build a second WhisperKit model
/// where the gate cannot reach it, and mapping a model whose bytes may still be
/// moving is exactly what that gate prevents.
///
/// Its two callers are the ones that never went through the normal dictation
/// doors: crash recovery and the Diagnostics benchmark. Streaming deliberately
/// stays on the manager — WhisperKit does not stream through it, and the manager
/// answers `activeBackendSupportsStreaming` false for a backend it does not own.
@MainActor
struct ActiveEngineOperation {
  /// Whether the active engine already has a model resident.
  let isLoaded: () async -> Bool
  /// Load the active engine's model through that engine's own safe door.
  ///
  /// POSTCONDITION (#2207): a non-throwing return means THE ENGINE IS READY, not
  /// merely that the load call returned. It previously meant only the latter —
  /// `ASRManager.loadModel()` records readiness rather than requiring it
  /// (`ASRManager.swift:175-177`) — while both callers already assumed the
  /// stronger meaning. `ASREngineNotReadyAfterLoadError` is thrown when the
  /// engine's own readiness projection is false after the loader returns.
  let load: () async throws -> Void
  /// Batch-transcribe on the active engine.
  let transcribe:
    (_ audioSamples: [Float], _ options: TranscriptionOptions) async throws ->
      ASRResult
  /// Hard-cancel whatever the active engine holds in flight (#445 Discard).
  /// Best-effort by the same physics as the engines themselves: generation
  /// bumps + task drops land instantly; a running Core ML load/decode cannot
  /// be stopped cooperatively and finishes before the recovery gate opens.
  let hardCancel: () async -> Void

  /// The production wiring. Lives beside the type rather than in the composition
  /// root: the root names subsystems, it does not spell out their routing.
  /// WhisperKit resolves to the same in-process backend the adapter drives, so
  /// the relocation gate always runs, and the backend's single-flight makes a
  /// recovery load and an adapter warm-up ONE load rather than two models.
  /// - Parameter afterLoadForTesting: invoked ONLY when non-nil, after the
  ///   selected loader returns and before the readiness postcondition is read.
  ///   Optional-and-nil rather than a default no-op closure, so production adds
  ///   no suspension point at all.
  ///
  ///   It exists because the WhisperKit branch cannot produce the postcondition's
  ///   failure naturally: `prepare()` DELIBERATELY throws superseded when an
  ///   unload races its warm-up, precisely so it never "reports success while the
  ///   backend is actually unloaded" (`WhisperKitBackend.swift:386-392`). Without
  ///   a seam the test would either race a concurrent unload — timing-dependent,
  ///   which this repo forbids — or substitute a fake loader, which would stop
  ///   testing this factory at all.
  static func live(
    asrManager: any ASRManagerInterface, whisperKitBackend: WhisperKitBackend,
    afterLoadForTesting: (@MainActor () async -> Void)? = nil
  ) -> ActiveEngineOperation {
    let readiness: @MainActor () async -> Bool = {
      asrManager.activeBackendType == .whisperKit
        ? await whisperKitBackend.isReady : asrManager.isModelLoaded
    }
    return ActiveEngineOperation(
      isLoaded: readiness,
      load: {
        if asrManager.activeBackendType == .whisperKit {
          try await whisperKitBackend.prepare()
        } else {
          try await asrManager.loadModel()
        }
        if let afterLoadForTesting { await afterLoadForTesting() }
        // The SAME projection `isLoaded` vends, deliberately: a postcondition
        // read from a different source could disagree with what every caller
        // then consults, which would trade one false success for another.
        guard await readiness() else { throw ASREngineNotReadyAfterLoadError() }
      },
      transcribe: { samples, options in
        if asrManager.activeBackendType == .whisperKit {
          return try await whisperKitBackend.transcribe(audioSamples: samples, options: options)
        }
        return try await asrManager.transcribe(audioSamples: samples, options: options)
      },
      hardCancel: {
        // Mirrors load/transcribe's routing. WhisperKit's `unload()` supersedes
        // the in-flight load/warm-up (generation bump + task drop) so a joined
        // recovery `prepare()` aborts instead of blocking dictation until the
        // model finishes loading (Codex 2b-r2 P1). Engine switches defer while
        // recovery replays, so the routing read here is stable.
        if asrManager.activeBackendType == .whisperKit {
          await whisperKitBackend.unload()
        } else {
          asrManager.cancelInFlightLoad()
        }
      })
  }
}
