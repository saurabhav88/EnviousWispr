import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import Foundation

/// #879 — the press-on-cold-engine policy, factored off `RecordingStarter` so
/// the start-path home stays within its method/line ceilings (mirrors
/// `ASREngineReadiness+ColdStartCohort.swift`, which deliberately lives off
/// `RecordingStarter` for the same reason).
///
/// When the user presses while the active engine is not yet ready (fresh
/// install, or first launch after a macOS update wiped the compiled-model
/// cache), `RecordingStarter` does NOT mint a recording session — no audio is
/// captured, so none is silently discarded. It hands off here to: show the
/// honest cold-boot pill, record the blocked-press telemetry, kick the shared
/// single-flighted warm-up, and announce "Ready" when the warm-up finishes so
/// the user knows to press again. Recording never auto-starts at T+warmup
/// (privacy: never begin listening on the user's behalf).
@MainActor
enum ColdPressGuard {
  /// #959 — resolve a press on a not-ready engine. Returns `true` for a
  /// warm-respawn (the resident model was reaped while idle AND the user keeps it
  /// resident, `.never`): consumes the marker, records the branch, and the caller
  /// FALLS THROUGH to the normal start so the press records (~0.2s re-warm under
  /// the kernel watchdog, overlay morphed to recording). Returns `false` for a
  /// genuine cold press: shows the #879 pill (no session) and the caller returns.
  /// Keeps the decision off `RecordingStarter` (same ceiling rationale as `handle`).
  static func resolveNotReadyPress(
    overlay: RecordingOverlayPanel,
    active: KernelDictationDriver,
    backendTag: String,
    readiness: ASREngineReadiness,
    modelUnloadPolicy: ModelUnloadPolicy
  ) -> Bool {
    if active.residentModelLostWhileIdle && modelUnloadPolicy == .never {
      active.residentModelLostWhileIdle = false
      TelemetryService.shared.serviceRespawnStarted(asrBackend: backendTag)
      return true
    }
    handle(overlay: overlay, active: active, backendTag: backendTag, readiness: readiness)
    return false
  }

  static func handle(
    overlay: RecordingOverlayPanel,
    active: KernelDictationDriver,
    backendTag: String,
    readiness: ASREngineReadiness
  ) {
    overlay.show(intent: .cachingModel(engineLabel: active.engineDisplayName))
    TelemetryService.shared.coldStartPressBlocked(
      asrBackend: backendTag, warmupInFlight: readiness == .warming)
    Task { [overlay, active] in
      await active.ensureEngineWarm(reason: .coldPress)
      // Announce READY only if the warm-up actually reached ready. A failed
      // warm-up leaves the engine not-ready; the next press re-shows the
      // caching pill. The user saw a `.cachingModel` pill on this path, so the
      // READY pill is expected — never a launch-time surprise toast.
      guard active.engineReadiness == .ready else { return }
      overlay.show(intent: .engineReady)
    }
    Task {
      await AppLogger.shared.log(
        "COLD-START [RecordingStarter] press blocked — engine not ready "
          + "(readinessAtPTT=\(readiness.coldStartCohortToken)) backend=\(backendTag)",
        level: .info, category: "Pipeline"
      )
    }
  }
}
