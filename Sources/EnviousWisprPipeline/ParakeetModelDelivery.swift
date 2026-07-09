import EnviousWisprCore
import EnviousWisprModelDelivery
import Foundation

/// Thrown by `ParakeetEngineAdapter.warmUp()` when the delivery stage ends in
/// a typed failure — carries the class/detail so the App layer can render the
/// D6 state copy (7/8/10) through the existing warm-up-failed surface.
public struct ParakeetDeliveryError: Error, Equatable {
  public let reason: DeliveryFailureClass
  public let detail: String?

  init(_ failure: DeliveryFailure) {
    self.reason = failure.reason
    self.detail = failure.detail
  }
}

/// Pipeline-side handle for the Parakeet delivery stage (#1348 Phase 2): the
/// one object the adapter talks to. Owns the flag read (one authority for
/// "is delivery on"), the ProgressFile bridge for the DOWNLOAD phase (the
/// host now feeds the same progress channel onboarding and the wedge guard
/// already watch; the service keeps feeding the compile/load phase), and the
/// controller calls. Built once by `WisprBootstrapper`.
@MainActor
public final class ParakeetDeliveryHandle {
  private let controller: ModelDeliveryController
  private let registration: DeliveryRegistration
  private let defaults: UserDefaults

  public init(
    controller: ModelDeliveryController, registration: DeliveryRegistration,
    defaults: UserDefaults? = nil
  ) {
    self.controller = controller
    self.registration = registration
    self.defaults = defaults ?? UserDefaults(suiteName: DeliveryFlags.suiteName) ?? .standard
    let identity = registration.manifest.identity
    Task {
      await controller.addStateObserver { [identity] observedIdentity, state in
        guard observedIdentity == identity else { return }
        Task { @MainActor in Self.bridgeToProgressFile(state) }
      }
    }
  }

  /// The D5 kill-switch, read fresh per warm-up (relaunch-free legacy
  /// fallback; the service's offline switch follows via `cacheOnly`).
  public func isEnabled() -> Bool {
    defaults.object(forKey: DeliveryFlags.key("enabled", family: .parakeet)) as? Bool ?? true
  }

  public func ensureAvailable() async -> ModelDeliveryController.DeliveryOutcome {
    await controller.ensureModelAvailable(registration)
  }

  /// One-shot repair after a cache-only load failure (grounded r1 revision 7;
  /// bounded to a single retry by the adapter).
  public func repair() async -> ModelDeliveryController.DeliveryOutcome {
    await controller.repair(registration)
  }

  /// #1388 step 3: user Cancel during the DOWNLOAD portion of the onboarding
  /// install. Cooperative — resolves after the live attempt fully drains
  /// (controller D4 §3), and the adapter's awaiting `ensureAvailable()` then
  /// returns `.cancelled`, surfacing as `EngineWarmupOutcome.cancelled`.
  /// No-op when nothing is in flight. This is USER intent, unlike the
  /// removed #1371 watchdog canceller that fought the fetcher's retry policy.
  public func cancelActiveFetch() async {
    _ = await controller.cancel(registration.manifest.identity)
  }

  /// D5 §1: the `enabled=false` bypass is proven by telemetry from the ONE
  /// site that takes it (the adapter's legacy branch).
  public func noteLegacyPathActive() {
    Task {
      await controller.noteFlagActive(
        identity: registration.manifest.identity, flag: "parakeet.enabled", value: "false")
    }
  }

  /// Download-phase progress rides the existing shared progress channel with
  /// the shipped fraction convention ([0, 0.5] = download half — the quip
  /// timer and stall policy key off it), so onboarding, the settings row, and
  /// the sessionless wedge guard need no new plumbing. Validation writes tick
  /// the file's mtime (liveness for the guard) without moving the fraction.
  private static func bridgeToProgressFile(_ state: DeliveryState) {
    let file = ProgressFile.shared
    switch state {
    case .preparing(let validating):
      file.write(
        fraction: 0,
        // Single authority for both literals: the wedge guard PARKS on the
        // validating phase and JUDGES the listing phase (#1388 Codex r4).
        phase: validating
          ? ModelLoadStallPolicy.validatingCachePhase : ModelLoadStallPolicy.listingPhase,
        detail: "")
    case .downloading(let fraction, let bytesWritten, let totalBytes):
      let mb = Int(Double(bytesWritten) / 1_048_576)
      let totalMB = Int(Double(totalBytes) / 1_048_576)
      file.write(
        fraction: fraction * 0.5,
        // Single authority for this literal (the wedge guard parks on it, #1405).
        phase: ModelLoadStallPolicy.downloadingPhase,
        detail: "\(mb) MB of \(totalMB) MB (\(Int(fraction * 100))%)")
    case .verifying:
      // Single authority for the literal (the wedge guard parks on it, #1388).
      file.write(fraction: 0.5, phase: ModelLoadStallPolicy.verifyingDownloadPhase, detail: "")
    case .admitted:
      // #1405 download->load boundary: CLEAR the progress file the instant
      // delivery completes. This moves the phase off the download phase so the
      // load-wedge guard un-parks and resumes judging the model LOAD — but
      // unlike WRITING a "loading" phase, clearing leaves NO signal, so the
      // guard's pre-first-signal deadline still covers a load that wedges
      // before emitting its own progress. Critical on the marker fast path
      // (cache hit), where `.admitted` is reached with no prior write, so a
      // phantom signal here would be the ONLY signal and would defeat that
      // deadline (cloud-review P1). The load's own progress repopulates the
      // file; onboarding's checklist advances off warm-up readiness, not this.
      ProgressFile.shared.clear()
    case .notReady, .cancelled, .failed:
      break
    }
  }
}
