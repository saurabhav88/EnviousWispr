import EnviousWisprCore
import EnviousWisprPipeline

/// Telemetry Bible Phase 2 (#1171) — the single, atomic snapshot of ASR-engine
/// selection, readiness, and switch lifecycle. Published by `EngineCoordinator`;
/// every consumer (the cold-press pill, the record-start gate, `BackendMetadata`,
/// Settings, telemetry) reads THIS, never the raw sources, so no consumer ever
/// sees a torn mix of "selected from here, active from there". A `Sendable`
/// value: copied out by readers, recomputed on each coordinator poke.
struct EngineStatus: Sendable {

  /// Where the user-selected → active reconciliation currently sits.
  enum SwitchPhase: Sendable, Equatable {
    case idle
    case switching
    /// A warm/load of the just-switched engine failed; `reason` is a stable
    /// non-PII token. The user's choice is still honored (active == selected);
    /// the next press re-attempts via the cold-press path.
    case failed(reason: String)
  }

  /// Why a divergent switch (selected != active) is not applying right now. nil
  /// when converged or mid-switch. Raw values match the `change_blocked` reason
  /// dimension so the existing telemetry stays continuous.
  enum BlockedReason: String, Sendable {
    case pipelineActive = "pipeline_active"
    case recovery
    case notInstalled = "not_installed"
    case loading
  }

  /// The engine the user picked (read live from `settings.selectedBackend`).
  let selected: ASRBackendType
  /// The engine actually loaded/active in the ASR manager.
  let active: ASRBackendType
  let selectedReadiness: ASREngineReadiness
  let activeReadiness: ASREngineReadiness
  /// Per-engine pipeline activity (recording/transcribing/polishing) — drives
  /// status display without the consumer reading either driver directly.
  let parakeetActive: Bool
  let whisperKitActive: Bool
  let switchPhase: SwitchPhase
  /// Whether the SELECTED engine's model is on disk (Parakeet is always true;
  /// WhisperKit is true only once downloaded).
  let selectedInstalled: Bool
  let blockedReason: BlockedReason?

  /// The selected engine differs from the active one — a switch is owed.
  var isDiverged: Bool { selected != active }

  /// Whether the active engine's model is resident. Exposed as a plain `Bool`
  /// so `BackendMetadata` can render "Loaded"/"Unloaded" without importing the
  /// Pipeline-layer readiness type.
  var activeModelLoaded: Bool { activeReadiness == .ready }
}
