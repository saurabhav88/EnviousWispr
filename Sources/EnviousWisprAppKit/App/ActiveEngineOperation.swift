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
  static func live(
    asrManager: any ASRManagerInterface, whisperKitBackend: WhisperKitBackend
  ) -> ActiveEngineOperation {
    ActiveEngineOperation(
      isLoaded: {
        asrManager.activeBackendType == .whisperKit
          ? await whisperKitBackend.isReady : asrManager.isModelLoaded
      },
      load: {
        if asrManager.activeBackendType == .whisperKit {
          try await whisperKitBackend.prepare()
        } else {
          try await asrManager.loadModel()
        }
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
