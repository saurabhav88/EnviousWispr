import EnviousWisprCore
import EnviousWisprModelDelivery
import EnviousWisprPipeline
import EnviousWisprServices
@preconcurrency import FluidAudio
import Foundation

/// App-owned home for the model-delivery layer (#1348 Phase 2): owns the
/// single `ModelDeliveryController`, the Parakeet registration built from the
/// bundled signed-app manifest (the trust root), the telemetry bridge onto
/// `model_delivery.*`, and the observable UI mirror the settings row renders
/// (one state stream, two renderers — D6). A narrow home in the #763
/// direction; the composition root holds it as one `let`.
@Observable @MainActor
public final class ModelDeliveryHome {
  public let controller = ModelDeliveryController()
  /// Nil when the bundled manifest failed to load — a can't-happen-in-release
  /// condition (unit-tested against the bundled resource); the Parakeet path
  /// then runs legacy delivery, never crashes.
  public private(set) var parakeetHandle: ParakeetDeliveryHandle?
  private var parakeetIdentity: ModelIdentity?
  private var parakeetRegistration: DeliveryRegistration?

  /// Observable mirror of the Parakeet delivery state for SwiftUI renderers.
  public private(set) var parakeetState: DeliveryState = .notReady
  /// Monotonic apply guard: MainActor hops can land out of order under load
  /// (EG-1 `installStateSeqApplied` precedent).
  private var stateSeq: UInt64 = 0
  /// D3 base prop: whether NO admitted Parakeet cache existed at launch —
  /// computed once during observer wiring (before any warm-up can run) and
  /// flipped false on the first admission this session. Approximates "at
  /// attempt start" at session granularity, which is what the funnel slices
  /// on (first-run install vs existing user).
  private var parakeetFirstRun = false

  public init() {
    do {
      let manifest = try DeliveryManifest.loadBundled(resource: "parakeet-delivery-manifest")
      let identity = manifest.identity
      let registration = DeliveryRegistration(
        manifest: manifest,
        installDirectory: AsrModels.defaultCacheDirectory(for: .v3),
        metadataDirectory: FileManager.default.urls(
          for: .applicationSupportDirectory, in: .userDomainMask)[0]
          .appendingPathComponent("EnviousWispr/ModelDelivery", isDirectory: true))
      parakeetIdentity = identity
      parakeetRegistration = registration
      parakeetHandle = ParakeetDeliveryHandle(controller: controller, registration: registration)
      wireObservers(identity: identity)
    } catch {
      Task {
        await AppLogger.shared.log(
          "Model delivery manifest unavailable — Parakeet stays on the legacy path: \(error)",
          level: .info, category: "Delivery")
      }
    }
  }

  private func wireObservers(identity: ModelIdentity) {
    let home = self
    let registration = parakeetRegistration
    Task {
      if let registration {
        let admitted = await controller.isAdmitted(registration)
        await MainActor.run { home.parakeetFirstRun = !admitted }
      }
      await controller.addStateObserver { observedIdentity, state in
        guard observedIdentity == identity else { return }
        Task { @MainActor in
          home.stateSeq &+= 1
          home.parakeetState = state
          if case .admitted = state { home.parakeetFirstRun = false }
        }
      }
      await controller.addEventObserver { observedIdentity, event in
        Task { @MainActor in
          ModelDeliveryTelemetryBridge.capture(
            event, identity: observedIdentity, firstRun: home.parakeetFirstRun)
        }
      }
    }
  }

  /// Settings-row Cancel (D6 state 11: acknowledgment is instant by design —
  /// the controller's cancel resolves only after the drain).
  public func cancelParakeetDownload() {
    guard let identity = parakeetIdentity else { return }
    Task { _ = await controller.cancel(identity) }
  }

  /// Settings-row Resume / Try Again: re-enters the single door (resume-aware
  /// by construction — staged partials survive a cancel).
  public func resumeParakeetDownload() {
    guard let handle = parakeetHandle else { return }
    Task { _ = await handle.ensureAvailable() }
  }
}

/// The ONE authority for user-facing delivery-failure copy (D6 states
/// 7/8/10/11 + the captive-portal sentence) — onboarding's friendly-error
/// mapping and the settings row both render from here, so the two surfaces
/// can never drift.
public enum ModelDeliveryCopy {
  public static func message(reason: DeliveryFailureClass, detail: String?) -> String {
    switch reason {
    case .sourceUnreachable, .sourceTimeout, .source5xx, .source4xx:
      return "Can't reach the download server. Check your connection and try again."
    case .insufficientDisk:
      return
        "Not enough free space to install the speech model. Free up about 1 GB and try again."
    case .integrityMismatch, .cacheRepairFailed:
      if detail == "intercepted_network" {
        return
          "If you are on hotel or public Wi-Fi, finish signing in to the network, then try again."
      }
      return
        "The download couldn't be verified. Try again, and if this keeps happening, contact support."
    case .cancelled:
      return "Download paused. Resume anytime."
    case .permissionDenied, .unknown:
      return
        "The download couldn't finish. Try again, and if this keeps happening, contact support."
    }
  }
}

/// Maps controller `DeliveryEvent`s 1:1 onto D3's `model_delivery.*` PostHog
/// events with the base properties (family/model_name/revision/variant come
/// from the identity; `schema_version`/`app_version` are constants of this
/// build). Sibling of `EGOneTelemetryBridge`.
@MainActor
enum ModelDeliveryTelemetryBridge {
  static func capture(_ event: DeliveryEvent, identity: ModelIdentity, firstRun: Bool) {
    var props: [String: String] = [
      "family": identity.family.rawValue,
      "model_name": identity.name,
      "revision": identity.revision,
      "variant": identity.variant,
      "first_run": String(firstRun),
      "schema_version": "1",
    ]
    let name: String
    switch event {
    case .attemptStarted(let resumed):
      name = "attempt_started"
      props["resumed"] = String(resumed)
    case .attemptCompleted(
      let durationBucket, let bytesBucket, let sourcesUsed, let finalSourceID, let repaired):
      name = "attempt_completed"
      props["duration_bucket"] = durationBucket
      props["bytes_downloaded_bucket"] = bytesBucket
      props["sources_used"] = String(sourcesUsed)
      props["final_source_id"] = finalSourceID
      props["repaired_components_count"] = String(repaired)
    case .attemptFailed(let reason, let failingSourceID, let detail):
      name = "attempt_failed"
      props["reason"] = reason.rawValue
      if let failingSourceID { props["failing_source_id"] = failingSourceID }
      if let detail { props["detail"] = detail }
    case .sourceFailover(let reason):
      name = "source_failover"
      props["reason"] = reason.rawValue
    case .validationRepair(let componentsCount, let trigger):
      name = "validation_repair"
      props["components_count"] = String(componentsCount)
      props["trigger"] = trigger.rawValue
    case .cancel(let phaseAtCancel, let resumable):
      name = "cancel"
      props["phase_at_cancel"] = phaseAtCancel
      props["resumable"] = String(resumable)
    case .flagActive(let flag, let value):
      name = "flag_active"
      props["flag"] = flag
      props["value"] = value
    }
    TelemetryService.shared.modelDeliveryEvent(name: name, properties: props)
  }
}
