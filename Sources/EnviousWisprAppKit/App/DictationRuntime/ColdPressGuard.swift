import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import Foundation

/// #879 — the press-on-cold-engine policy, factored off `RecordingStarter` so
/// the start path owns STARTING and not every policy that touches it (mirrors
/// `ASREngineReadiness+ColdStartCohort.swift`, which lives off `RecordingStarter`
/// for the same reason). The ceiling tests that once guarded that split were
/// retired (#2292 C6, #3505); keep it by review.
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
  /// #1171 — start-of-recording engine reconciliation. The user pressed while the
  /// active engine isn't the one they selected (a switch deferred while busy/
  /// recovering hasn't applied yet, or a switch is in flight). Show the SAME
  /// reactive caching pill for the SELECTED engine, then await the EngineCoordinator
  /// driving the selected engine to ready (it owns the single-flight switch + warm),
  /// and announce Ready when it lands. Mints no session — the user re-presses on the
  /// now-correct engine. Factored here (like `handle`) so `RecordingStarter`
  /// keeps owning the start path rather than the policies that surround it.
  static func reconcileSelectedBackend(
    overlay: OverlayDirector,
    selectedDriver: KernelDictationDriver,
    ensureSelectedReady: @escaping @MainActor () async -> EngineCoordinator.PressReadiness,
    confirmExplicitRetry: @escaping @MainActor () async -> Bool
  ) {
    let label = selectedDriver.engineDisplayName
    let receipt = overlay.present(.cachingModel(engineLabel: label))
    Task { [overlay] in
      // The coordinator switches to the selection AND warms it (single-flight,
      // latest-wins), returning the outcome so we show the right pill for EVERY
      // case — never leaving the misleading "getting ready" pill up when the
      // selected engine cannot actually be prepared.
      switch await ensureSelectedReady() {
      case .ready:
        overlay.present(.engineReady)
      case .notInstalled:
        overlay.present(.warning(reason: .modelNotDownloaded(engineLabel: label)))
      case .notReady:
        guard let receipt, overlay.canFollowUp(receipt) else { return }
        let needsRetry = await confirmExplicitRetry()
        if needsRetry, overlay.canFollowUp(receipt) {
          presentExplicitRetry(overlay: overlay, engineLabel: label)
        } else if overlay.isCurrent(receipt) {
          overlay.dismissCurrent(.announced)
        }
      }
    }
  }

  /// #3546 A3: a press during the in-session Ultra activation. The same wait as an engine
  /// switch (the coordinator holds the switch gate), with the upgrade's Installing pill.
  /// The upgrade presenter owns the once-only "Parakeet Ultra is ready" pill, which replaces
  /// Installing; this waiter only removes its own Installing pill if it is still showing
  /// when the switch settles (Ultra failed and v3 serves, or the Ready pill was already
  /// spent). Mints no session. Returns the waiter, so a caller can know when it settled.
  @discardableResult
  static func reconcileParakeetUpgrade(
    overlay: OverlayDirector,
    model: ASRModelAttribution?,
    isActivating: @escaping @MainActor () -> Bool,
    ensureSelectedReady: @escaping @MainActor () async -> EngineCoordinator.PressReadiness
  ) -> Task<Void, Never> {
    let receipt = overlay.present(
      .parakeetUpgrade(
        ParakeetUpgradePillModel(phase: .installing), isStillWanted: isActivating))
    TelemetryService.shared.coldStartPressBlocked(
      asrBackend: ASRBackendType.parakeet.rawValue, warmupInFlight: true,
      model: model)
    return Task { [overlay] in
      _ = await ensureSelectedReady()
      guard let receipt else { return }
      overlay.dismissIfCurrent(receipt)
    }
  }

  static func handle(
    overlay: OverlayDirector,
    active: KernelDictationDriver,
    backendTag: String,
    readiness: ASREngineReadiness,
    confirmExplicitRetry: @escaping @MainActor () async -> Bool
  ) {
    let receipt = overlay.present(.cachingModel(engineLabel: active.engineDisplayName))
    recordBlockedPress(active: active, backendTag: backendTag, readiness: readiness)
    Task { [overlay, active] in
      await active.ensureEngineWarm(reason: .coldPress)
      // Announce READY only if the warm-up actually reached ready. A failed
      // warm-up leaves the engine not-ready; the next press re-shows the
      // caching pill. The user saw a `.cachingModel` pill on this path, so the
      // READY pill is expected — never a launch-time surprise toast.
      if active.engineReadiness == .ready {
        overlay.present(.engineReady)
      } else if let receipt, overlay.canFollowUp(receipt), await confirmExplicitRetry(),
        overlay.canFollowUp(receipt)
      {
        presentExplicitRetry(overlay: overlay, engineLabel: active.engineDisplayName)
      }
    }
    Task {
      await AppLogger.shared.log(
        "COLD-START [RecordingStarter] press blocked — engine not ready "
          + "(readinessAtPTT=\(readiness.coldStartCohortToken)) backend=\(backendTag)",
        level: .info, category: "Pipeline"
      )
    }
  }

  static func presentExplicitRetry(overlay: OverlayDirector, engineLabel: String) {
    overlay.present(.warning(reason: .modelRequiresExplicitRetry(engineLabel: engineLabel)))
  }

  static func recordBlockedPress(
    active: KernelDictationDriver, backendTag: String, readiness: ASREngineReadiness
  ) {
    TelemetryService.shared.coldStartPressBlocked(
      asrBackend: backendTag, warmupInFlight: readiness == .warming,
      model: active.requestedModelAttribution)
  }
}
