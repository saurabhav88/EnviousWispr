import EnviousWisprCore
import EnviousWisprModelDelivery
import Foundation

/// EG-1's LIMB adapter over the shared `ModelDeliveryController` (#1348 Phase
/// 3). The thin EG-1 sibling of `ParakeetDeliveryHandle`: it owns the EG-1
/// `DeliveryRegistration`, reads the `eg_one.enabled` flag, exposes the
/// controller's ensure/repair/remove/cancel, forwards an install-state stream
/// mapped from `DeliveryState`, and translates delivery failures into EG-1's
/// UI vocabulary.
///
/// The limb difference vs Parakeet lives ENTIRELY in what the consumer does
/// with a failed outcome: Parakeet (a heart) surfaces a blocking warm-up
/// error; EG-1 (a limb) surfaces a settings-row RED + Try Again and returns,
/// and polish silently falls back to raw text. The shared controller is
/// identical for both — no EG-1 branch lives in the leaf.
@MainActor
public final class EGOneDeliveryAdapter {
  private let controller: ModelDeliveryController
  private let registration: DeliveryRegistration
  private let defaults: UserDefaults
  /// Version string surfaced as `.installed(version:)` (the runtime manifest's
  /// version, e.g. `v1`); the delivery identity's revision carries the same.
  private let version: String

  public init(
    controller: ModelDeliveryController,
    registration: DeliveryRegistration,
    version: String,
    defaults: UserDefaults? = nil
  ) {
    self.controller = controller
    self.registration = registration
    self.version = version
    self.defaults = defaults ?? UserDefaults(suiteName: DeliveryFlags.suiteName) ?? .standard
  }

  /// The verified on-disk model location the runtime boots llama-server from:
  /// the install dir joined with the resolved install path (contract §4b —
  /// the LOCAL name `eg-1-v1.gguf`, never the fetch key). Valid only after an
  /// `.admitted` outcome.
  public var installedArtifactURL: URL {
    let installName =
      registration.manifest.files.first?.resolvedInstallPath
      ?? registration.manifest.files.first?.path ?? ""
    return registration.installDirectory.appendingPathComponent(installName)
  }

  /// The D5 kill-switch, read fresh per call (relaunch-free). Disabled ⇒ no
  /// delivery mutation (#1363 §16.6). Internal: EG-1's flag gates only the
  /// adapter's own ensure/repair/remove (unlike Parakeet, whose engine adapter
  /// reads the flag to choose the cache-only load path).
  private func isEnabled() -> Bool {
    defaults.object(forKey: DeliveryFlags.key("enabled", family: .egOne)) as? Bool ?? true
  }

  /// Ensure EG-1's bytes are admitted, fetching/adopting as needed. When
  /// delivery is disabled (§16.6): no mutation — return `.admitted` if the
  /// existing cache is already admitted (the server may use trusted bytes),
  /// else a limb-not-ready failure (dictation raw-fallbacks). The bypass fires
  /// `flag_active` from its one taking site (D5 §1).
  public func ensureAvailable() async -> ModelDeliveryController.DeliveryOutcome {
    if !isEnabled() {
      controllerNoteDisabled()
      if await controller.isAdmitted(registration) { return .admitted }
      return .failed(DeliveryFailure(reason: .unknown, detail: "delivery_disabled"))
    }
    return await controller.ensureModelAvailable(registration)
  }

  /// Adopt an already-present model WITHOUT fetching — the activation path
  /// (launch / provider-switch / settings-open, grounded r4 P2). Returns true
  /// when EG-1 is now admitted (marker fast path, or an existing byte-correct
  /// file validated + admitted in place — the migration case). Returns false
  /// when a fetch would be required; NO download starts (only the explicit
  /// Download button calls `ensureAvailable`). When delivery is disabled
  /// (§16.6): no mutation — trust an existing marker, never adopt-unmarked.
  public func adoptIfPresent() async -> Bool {
    if !isEnabled() {
      controllerNoteDisabled()
      return await controller.isAdmitted(registration)
    }
    return await controller.admitIfComplete(registration)
  }

  /// One-shot repair after a cache-only load failure (§16.5); no-op when
  /// disabled.
  public func repair() async -> ModelDeliveryController.DeliveryOutcome {
    if !isEnabled() {
      controllerNoteDisabled()
      if await controller.isAdmitted(registration) { return .admitted }
      return .failed(DeliveryFailure(reason: .unknown, detail: "delivery_disabled"))
    }
    return await controller.repair(registration)
  }

  /// Cancel any in-flight delivery (Resume-able; staged partials survive).
  public func cancel() async {
    _ = await controller.cancel(registration.manifest.identity)
  }

  /// Evict the model (delete marker + files + staging). Disabled ⇒ no
  /// remove-on-behalf (§16.6): the flag gates all delivery mutation.
  public func remove() async -> ModelDeliveryController.RemoveOutcome {
    if !isEnabled() {
      controllerNoteDisabled()
      return .failed(DeliveryFailure(reason: .unknown, detail: "delivery_disabled"))
    }
    return await controller.remove(registration)
  }

  /// Observe EG-1's install state, mapped from the shared engine's
  /// `DeliveryState`. Ordering is guarded by a sequence minted on the
  /// controller actor (publish order); an out-of-order MainActor hop is
  /// dropped, so the callback fires with monotonic states.
  ///
  /// Startup seed (grounded r1 P2): the controller has NO in-memory entry for
  /// EG-1 until the first `ensureAvailable` runs, so the observer's replay
  /// yields `.notReady`. To avoid showing Download for an already-admitted
  /// cache when EG-1 is not the launch provider, seed from the admission
  /// marker — a cheap check (no rehash, D7 row 11), the equivalent of the old
  /// store's `refreshInstalledState()` at wiring. A legacy unmarked file is
  /// adopted (and its state corrected) on the first activation/settings-open.
  public func observeInstallState(_ onState: @escaping @MainActor (EGOneInstallState) -> Void) {
    let identity = registration.manifest.identity
    let version = version
    let sequencer = InstallStateSequencer()
    Task {
      await controller.addStateObserver { [weak self] observedIdentity, state in
        guard observedIdentity == identity else { return }
        // Mint the sequence on the controller actor (publish order); apply on
        // MainActor only if newer than the last applied (drop reordered hops).
        let seq = sequencer.next()
        let mapped = Self.map(state, version: version)
        Task { @MainActor in
          guard let self, seq > self.lastAppliedInstallSeq else { return }
          self.lastAppliedInstallSeq = seq
          onState(mapped)
        }
      }
      // Seed from the marker AFTER registration (so this seq outranks the
      // replay's `.notReady`): an admitted cache shows Installed at startup.
      if await controller.isAdmitted(registration) {
        let seq = sequencer.next()
        await MainActor.run { [weak self] in
          guard let self, seq > self.lastAppliedInstallSeq else { return }
          self.lastAppliedInstallSeq = seq
          onState(.installed(version: version))
        }
      }
    }
  }

  /// Apply guard for the install-state stream (MainActor-isolated): a
  /// reordered older MainActor hop is dropped so the callback fires monotonic.
  private var lastAppliedInstallSeq: UInt64 = 0

  private func controllerNoteDisabled() {
    let identity = registration.manifest.identity
    Task {
      await controller.noteFlagActive(
        identity: identity, flag: "eg1.enabled", value: "false")
    }
  }

  // MARK: - Mapping (DeliveryState → EG-1 UI vocabulary)

  nonisolated static func map(_ state: DeliveryState, version: String) -> EGOneInstallState {
    switch state {
    case .notReady:
      return .notInstalled
    case .preparing:
      // Existing-cache validation / staging setup reads as "verifying" in the
      // EG-1 row (yellow).
      return .verifying
    case .downloading(let fraction, _, _):
      return .downloading(fractionCompleted: fraction)
    case .verifying:
      return .verifying
    case .admitted:
      return .installed(version: version)
    case .cancelled:
      // The EG-1 row shows a paused/saved state via the .cancelled failure
      // copy ("Download canceled. Your progress is saved.").
      return .failed(.cancelled)
    case .failed(let failure):
      return .failed(Self.mapFailure(failure.reason))
    }
  }

  /// Map the shared engine's closed failure taxonomy onto EG-1's existing UI
  /// copy buckets (`AIPolishSettingsView.egOneFailureCopy`). Every class is a
  /// retry-able RED — the limb never blocks dictation.
  nonisolated static func mapFailure(_ reason: DeliveryFailureClass) -> EGOneDownloadFailure {
    switch reason {
    case .sourceUnreachable, .sourceTimeout:
      return .network
    case .source4xx, .source5xx:
      return .http
    case .integrityMismatch, .cacheRepairFailed:
      return .checksum
    case .insufficientDisk:
      return .disk
    case .cancelled:
      return .cancelled
    case .permissionDenied, .unknown:
      // No exact bucket; "server had a problem, try again" is the least
      // misleading retry copy for a rare permission/unknown class.
      return .http
    }
  }
}

/// Lock-protected monotonic counter minted on the controller actor's publish
/// path, compared on MainActor — the install-state observer's apply guard
/// (mirrors `ModelDeliveryHome.StateSequencer`).
private final class InstallStateSequencer: @unchecked Sendable {
  private let lock = NSLock()
  private var value: UInt64 = 0
  func next() -> UInt64 {
    lock.withLock {
      value &+= 1
      return value
    }
  }
}
