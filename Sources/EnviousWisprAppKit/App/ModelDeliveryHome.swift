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

  /// #1386 PR-2. Nil when the bundled multilingual manifest failed to load —
  /// unlike Parakeet there is NO legacy fallback behind it (PR-2 retired
  /// `WhisperKit.download()`), so a nil handle means the multilingual engine
  /// honestly reports "not installed" rather than fetching by an unverified
  /// route. Unit-tested against the bundled resource.
  public private(set) var whisperKitHandle: WhisperKitDeliveryHandle?
  public private(set) var whisperKitRegistration: DeliveryRegistration?

  /// Observable mirror of the Parakeet delivery state for SwiftUI renderers.
  public private(set) var parakeetState: DeliveryState = .notReady
  /// Monotonic apply guard (EG-1 `installStateSeqApplied` precedent, made
  /// REAL per exhaustive r7 finding 7): the sequence is minted at observer-
  /// receive time (controller actor, in publish order) and a MainActor hop
  /// that lands out of order is dropped.
  private var lastAppliedStateSeq: UInt64 = 0
  /// D3 base prop, PER IDENTITY (#1363 §16.2): whether NO admitted cache
  /// existed at launch for each model — computed once during that model's
  /// observer wiring (before any warm-up can run) and flipped false on its
  /// first admission this session. Keyed by identity because EG-1 and Parakeet
  /// share ONE controller and ONE telemetry bridge; a single Bool would stamp
  /// EG-1's events with Parakeet's first-run truth. Missing key ⇒ false (a
  /// model whose baseline was never recorded is treated as not-first-run).
  private var firstRunByIdentity: [ModelIdentity: Bool] = [:]

  /// #1707 Phase 3 (§3.2, row 17) — `EngineRecoveryGate.tryBeginMutation()`/
  /// `endMutation()`, injected by the composition root (this type never
  /// references `EngineRecoveryGate` by concrete type). Guards Parakeet's
  /// Settings Download/Cancel — a separate guarded site from `ensureEngineWarm()`,
  /// since Parakeet delivery admission does not always route through it.
  /// Defaults keep every existing test/legacy construction unchanged (always
  /// able to proceed).
  var tryBeginEngineMutation: @MainActor () -> Bool = { true }
  /// Returns whether recovery was denied while this mutation was in flight
  /// and is now owed a wake-up.
  var endEngineMutation: @MainActor () -> Bool = { false }
  /// Called when `endEngineMutation()` returns true — wakes a stranded
  /// recovery attempt. Bound to `RecoveryCoordinator.requestRecoveryRecheck`.
  var wakeRecoveryIfOwed: @MainActor () -> Void = {}

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

    // The multilingual (WhisperKit) registration, built beside the shared
    // controller (#1386 PR-2). It needs NO second telemetry observer: the
    // observers wired above are per-identity for Parakeet's mirror only, and the
    // event bridge below them is already generic across every identity.
    do {
      let manifest = try DeliveryManifest.loadBundled(resource: "whisperkit-delivery-manifest")
      let appSupport = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
      let registration = DeliveryRegistration(
        manifest: manifest,
        installDirectory: appSupport.appendingPathComponent(
          "EnviousWispr/Models/whisper", isDirectory: true),
        metadataDirectory: appSupport.appendingPathComponent(
          "EnviousWispr/ModelDelivery", isDirectory: true))
      whisperKitRegistration = registration
      whisperKitHandle = WhisperKitDeliveryHandle(
        controller: controller, registration: registration)
      let home = self
      Task { await home.recordFirstRunBaseline(for: registration) }
    } catch {
      Task {
        await AppLogger.shared.log(
          "Multilingual delivery manifest unavailable — the engine will report not-installed: "
            + "\(error)",
          level: .info, category: "Delivery")
      }
    }
  }

  private func wireObservers(identity: ModelIdentity) {
    let home = self
    let registration = parakeetRegistration
    let sequencer = DeliveryStateSequencer()
    Task {
      if let registration {
        let admitted = await controller.isAdmitted(registration)
        await MainActor.run { home.firstRunByIdentity[identity] = !admitted }
      }
      await controller.addStateObserver { observedIdentity, state in
        guard observedIdentity == identity else { return }
        // Mint the sequence HERE (publish order on the controller actor);
        // apply on MainActor only if newer than the last applied.
        let seq = sequencer.next()
        Task { @MainActor in
          guard seq > home.lastAppliedStateSeq else { return }
          home.lastAppliedStateSeq = seq
          home.parakeetState = state
          if case .admitted = state { home.firstRunByIdentity[observedIdentity] = false }
        }
      }
      // First-run flip for EVERY identity (grounded r1 P3): the observer above
      // is Parakeet-filtered for its state mirror, so EG-1's `.admitted` would
      // never flip EG-1's first-run flag and EG-1 events would report
      // first_run=true for the whole process. This dedicated observer flips any
      // identity's flag on admission — idempotent and order-independent (once
      // false it stays false; `attempt_completed` is emitted before `.admitted`,
      // so the fetch-path funnel events still read the true baseline).
      await controller.addStateObserver { observedIdentity, state in
        guard case .admitted = state else { return }
        Task { @MainActor in home.firstRunByIdentity[observedIdentity] = false }
      }
      await controller.addEventObserver { observedIdentity, event in
        Task { @MainActor in
          ModelDeliveryTelemetryBridge.capture(
            event, identity: observedIdentity,
            firstRun: home.firstRunByIdentity[observedIdentity] ?? false)
        }
      }
    }
  }

  /// Record a model's first-run baseline BEFORE its first warm-up (#1363
  /// §16.2). EG-1 shares this home's controller + telemetry bridge, so its
  /// runtime calls this once at construction to seed its own first-run truth;
  /// the shared event observer above then stamps EG-1's `model_delivery.*`
  /// events with EG-1's baseline, never Parakeet's. Idempotent; a later
  /// `.admitted` for the identity flips it false via the state observer.
  public func recordFirstRunBaseline(for registration: DeliveryRegistration) async {
    let admitted = await controller.isAdmitted(registration)
    firstRunByIdentity[registration.manifest.identity] = !admitted
  }

  /// Settings-row Cancel (D6 state 11: acknowledgment is instant by design —
  /// the controller's cancel resolves only after the drain).
  public func cancelParakeetDownload() {
    guard let identity = parakeetIdentity else { return }
    Task { [weak self] in
      // #1707 Phase 3 (§3.2, row 17): hold a mutation claim for the FULL
      // cancel-drain.
      guard let self, self.tryBeginEngineMutation() else {
        TelemetryService.shared.recoveryEngineActionDeferred(site: "parakeetCancelDownload")
        return
      }
      defer {
        if self.endEngineMutation() { self.wakeRecoveryIfOwed() }
      }
      _ = await self.controller.cancel(identity)
    }
  }

  /// Settings-row Resume / Try Again: re-enters the single door (resume-aware
  /// by construction — staged partials survive a cancel).
  public func resumeParakeetDownload() {
    guard let handle = parakeetHandle else { return }
    Task { [weak self] in
      // #1707 Phase 3 (§3.2, row 17): hold a mutation claim for the FULL
      // download.
      guard let self, self.tryBeginEngineMutation() else {
        TelemetryService.shared.recoveryEngineActionDeferred(site: "parakeetResumeDownload")
        return
      }
      defer {
        if self.endEngineMutation() { self.wakeRecoveryIfOwed() }
      }
      _ = await handle.ensureAvailable()
    }
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
      // D3 base prop; refined per event below (n/a where no source applies —
      // exhaustive r7 finding 8).
      "source_id": "n/a",
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
      props["source_id"] = finalSourceID
      props["repaired_components_count"] = String(repaired)
    case .attemptFailed(let reason, let failingSourceID, let detail):
      name = "attempt_failed"
      props["reason"] = reason.rawValue
      if let failingSourceID {
        props["failing_source_id"] = failingSourceID
        props["source_id"] = failingSourceID
      }
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
    case .admittedWithoutFetch(let reason):
      // #1363 Decision E: a model became available with no fetch (warm-relaunch
      // marker fast path or existing-file adoption). Distinct from
      // attempt_completed; "available in the field" = attempt_completed OR
      // admitted_without_fetch.
      name = "admitted_without_fetch"
      props["reason"] = reason.rawValue
    }
    TelemetryService.shared.modelDeliveryEvent(name: name, properties: props)
  }
}

/// Lock-protected monotonic counter for the state observer's apply guard —
/// minted on the controller actor's publish path, compared on MainActor.
// State-publication sequencing: canonical `DeliveryStateSequencer` lives in
// EnviousWisprModelDelivery (one type, all family projections).
