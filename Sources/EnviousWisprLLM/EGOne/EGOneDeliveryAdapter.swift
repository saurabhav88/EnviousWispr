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
  /// USER-FACING display label surfaced as `.installed(version:)`, e.g. "1.1"
  /// rendered as "EG-1 V1.1" (#2109). Optional: a manifest without one shows
  /// no label rather than falling back to the internal revision, which is a
  /// path component (`v3-eg2`) and not a thing to put in front of a user.
  private let version: String?

  public init(
    controller: ModelDeliveryController,
    registration: DeliveryRegistration,
    version: String?,
    defaults: UserDefaults? = nil
  ) {
    self.controller = controller
    self.registration = registration
    self.version = version
    self.defaults = defaults ?? UserDefaults(suiteName: DeliveryFlags.suiteName) ?? .standard
  }

  // MARK: - Legacy-upgrade hooks (#1386 PR-1)

  /// Installed by `EGOneUpgradeCoordinator` at the composition root. The
  /// adapter stays the single delivery doorway; the coordinator's monolith
  /// retirement runs before any fetch door, and admission/decline outcomes are
  /// reported back so the owed marker never drifts from delivery reality.
  ///
  /// `beforeDecline` carries WHICH action fired it (#2096). `cancel()` and `remove()` both
  /// reach it and they do not mean the same thing: Remove is about the model, Cancel is about
  /// one download, and the settings row can start a download the coordinator did not. Passing
  /// the producer keeps that distinction explicit here instead of leaving the coordinator to
  /// infer it from in-flight state that a user-initiated download would also set.
  private var legacyPrepareBeforeEnsure: (@MainActor @Sendable () async -> Bool)?
  private var legacyRecordDecline:
    (@MainActor @Sendable (EGOneUpgradeCoordinator.DeclineSource) -> Bool)?
  private var legacyDidAdmit: (@MainActor @Sendable () -> Void)?

  func installLegacyUpgradeHooks(
    beforeEnsure: @escaping @MainActor @Sendable () async -> Bool,
    beforeDecline: @escaping @MainActor @Sendable (EGOneUpgradeCoordinator.DeclineSource) -> Bool,
    onAdmitted: @escaping @MainActor @Sendable () -> Void
  ) {
    legacyPrepareBeforeEnsure = beforeEnsure
    legacyRecordDecline = beforeDecline
    legacyDidAdmit = onAdmitted
  }

  /// The verified on-disk model location the runtime boots llama-server from:
  /// the install dir joined with the manifest's resolved entrypoint (contract
  /// §4b — the LOCAL name, never the fetch key; #1417: for a sharded manifest
  /// this is shard 1's install name, `llama-server` auto-loads the rest). Valid
  /// only after an `.admitted` outcome. Thin consumer of
  /// `DeliveryManifest.resolvedEntrypointPath` — no fallback logic of its own.
  public var installedArtifactURL: URL {
    let installName = registration.manifest.resolvedEntrypointPath ?? ""
    return registration.installDirectory.appendingPathComponent(installName)
  }

  /// The D5 kill-switch, read fresh per call (relaunch-free). Disabled ⇒ no
  /// delivery mutation (#1363 §16.6). Internal: EG-1's flag gates only the
  /// adapter's own ensure/repair/remove (unlike Parakeet, whose engine adapter
  /// reads the flag to choose the cache-only load path). Static so the
  /// legacy-upgrade coordinator reads the SAME key without duplicating it
  /// (#1386 PR-1).
  static func isDeliveryEnabled(defaults: UserDefaults) -> Bool {
    defaults.object(forKey: DeliveryFlags.key("enabled", family: .egOne)) as? Bool ?? true
  }

  private func isEnabled() -> Bool {
    Self.isDeliveryEnabled(defaults: defaults)
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

    // A1 - Every fetch door prepares retirement first and reports admission.
    if let legacyPrepareBeforeEnsure,
      !(await legacyPrepareBeforeEnsure())
    {
      return .failed(
        DeliveryFailure(reason: .cacheRepairFailed, detail: "legacy_retirement"))
    }

    let outcome = await controller.ensureModelAvailable(registration)
    if case .admitted = outcome {
      legacyDidAdmit?()
    }
    return outcome
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

    let admitted = await controller.admitIfComplete(registration)
    if admitted {
      legacyDidAdmit?()
    }
    return admitted
  }

  /// Current-cache admission truth, for the legacy-upgrade coordinator's launch
  /// table (#1386 PR-1). Module-scoped: nothing outside this module needs it.
  func isAdmitted() async -> Bool {
    await controller.isAdmitted(registration)
  }

  /// One-shot repair after a cache-only load failure (§16.5); no-op when
  /// disabled.
  public func repair() async -> ModelDeliveryController.DeliveryOutcome {
    if !isEnabled() {
      controllerNoteDisabled()
      if await controller.isAdmitted(registration) { return .admitted }
      return .failed(DeliveryFailure(reason: .unknown, detail: "delivery_disabled"))
    }

    if let legacyPrepareBeforeEnsure,
      !(await legacyPrepareBeforeEnsure())
    {
      return .failed(
        DeliveryFailure(reason: .cacheRepairFailed, detail: "legacy_retirement"))
    }

    let outcome = await controller.repair(registration)
    if case .admitted = outcome {
      legacyDidAdmit?()
    }
    return outcome
  }

  /// Cancel any in-flight delivery (Resume-able; staged partials survive).
  ///
  /// A2 - Explicit decline is recorded before controller cancellation,
  /// regardless of the delivery switch (contract §5c.10: the switch guards
  /// model bytes, never the user's recorded decision). If admission already
  /// won the race, the verified model simply stays installed.
  public func cancel() async {
    if let legacyRecordDecline, !legacyRecordDecline(.cancel) {
      return
    }

    _ = await controller.cancel(registration.manifest.identity)
  }

  /// Evict the model (delete marker + files + staging). Disabled ⇒ no
  /// remove-on-behalf (§16.6): the flag gates all delivery mutation.
  ///
  /// A3 - Explicit decline is recorded before the switch is consulted. The
  /// switch still prevents current-model deletion.
  public func remove() async -> ModelDeliveryController.RemoveOutcome {
    if let legacyRecordDecline, !legacyRecordDecline(.remove) {
      return .failed(
        DeliveryFailure(reason: .permissionDenied, detail: "replacement_marker_clear"))
    }

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
    let registration = registration
    Task {
      // SEED FIRST, THEN OBSERVE (#2109). The order is inverted from what it
      // used to be, and the inversion is the whole reason `updatePaused` is
      // reachable at all.
      //
      // `addStateObserver` replays only identities already present in the
      // controller's `entries`, and an entry exists only once something has
      // touched that identity. A user sitting on a PRIOR revision with no
      // fetch in flight has no entry, so the observer never fires for them —
      // and the old seed was gated on `isAdmitted`, which is false for exactly
      // that user because the pinned revision is the thing they lack. Neither
      // path published anything, so the row kept `EGOneRuntime`'s initial
      // `.notInstalled` and the paused-update state could never appear on a
      // cold launch, which is the only moment it matters.
      //
      // Seeding first is also what makes the ordering safe. The previous
      // comment here reasoned that the seed must come AFTER registration so it
      // outranks the replay's `.notReady` — correct when the seed could only
      // ever be `.installed` for an admitted cache, and WRONG now that the
      // seed carries a disk-derived guess, because a guess must never outrank
      // live truth. Attaching second means any already-running attempt is
      // replayed with a LATER sequence number and wins, and if nothing is
      // running there is no entry, no replay, and the seed stands.
      let seedSeq = sequencer.next()
      let seeded: EGOneInstallState =
        await controller.isAdmitted(registration)
        ? .installed(version: version)
        : Self.notServingState(for: registration, version: version)
      await MainActor.run { [weak self] in
        guard let self, seedSeq > self.lastAppliedInstallSeq else { return }
        self.lastAppliedInstallSeq = seedSeq
        if case .installed = seeded { self.legacyDidAdmit?() }
        onState(seeded)
      }

      await controller.addStateObserver { [weak self] observedIdentity, state in
        guard observedIdentity == identity else { return }
        // Mint the sequence on the controller actor (publish order); apply on
        // MainActor only if newer than the last applied (drop reordered hops).
        let seq = sequencer.next()
        let mapped = Self.map(state, version: version, registration: registration)
        Task { @MainActor in
          guard let self, seq > self.lastAppliedInstallSeq else { return }
          self.lastAppliedInstallSeq = seq

          // A4 - Same existing adapter state stream; no second controller
          // observer. Admission through ANY door (manual Try Again included)
          // completes the legacy replacement.
          if case .admitted = state {
            self.legacyDidAdmit?()
          }

          onState(mapped)
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

  /// Disk truth the mapper needs, read once per mapping call.
  ///
  /// Both reads are SYNCHRONOUS by construction (#2109): `map` runs inside the
  /// controller's state-observer callback, between minting a sequence number
  /// and applying it on the MainActor, so it cannot await. Adding a suspension
  /// there would open the exact window `InstallStateSequencer` exists to close.
  nonisolated static func diskFacts(
    for registration: DeliveryRegistration
  ) -> (hasPartials: Bool, olderRevisionSurvives: Bool) {
    (
      hasPartials: ModelDeliveryController.hasStagedPartialsOnDisk(registration),
      olderRevisionSurvives: PriorRevisionAdmission.supersededInstallSurvives(
        identity: registration.manifest.identity,
        metadataDirectory: registration.metadataDirectory,
        installDirectory: registration.installDirectory)
    )
  }

  nonisolated static func map(
    _ state: DeliveryState, version: String?, registration: DeliveryRegistration
  ) -> EGOneInstallState {
    switch state {
    case .notReady:
      return Self.notServingState(for: registration, version: version)
    case .preparing:
      // Existing-cache validation / staging setup reads as "verifying" in the
      // EG-1 row (yellow).
      return .verifying
    case .downloading(let fraction, _, _):
      // `upgradeTo` is nil HERE BY DESIGN, not by omission. This mapping is
      // stateless and per-tick; whether the download replaces a working older
      // revision is a fact about the state we came FROM. `EGOneRuntime` owns
      // that and enriches this value.
      return .downloading(fractionCompleted: fraction, upgradeTo: nil)
    case .verifying:
      return .verifying
    case .admitted:
      return .installed(version: version)
    case .cancelled:
      // #2109: a cancel is a user DECISION, not a failure. It used to map to
      // `.failed(.cancelled)`, which rendered a red row with a Try Again
      // button for something the user chose. Which paused state it is depends
      // on whether a working older revision survives underneath.
      return Self.notServingState(for: registration, version: version)
    case .failed(let failure):
      return .failed(Self.mapFailure(failure.reason))
    }
  }

  /// The three ways EG-1 can be not-serving, separated by DISK truth rather
  /// than by how we got here (#2109). `.notReady` and `.cancelled` both land
  /// here because the user-visible question is identical in both: is there a
  /// working model underneath, and is there a download to resume?
  ///
  /// Order matters. A surviving older revision is the strongest signal — it
  /// means AI cleanup was working and has stopped, which is the thing #2109
  /// exists to stop hiding — so it is checked first and reported whether or
  /// not partials exist.
  nonisolated static func notServingState(
    for registration: DeliveryRegistration, version: String?
  ) -> EGOneInstallState {
    let facts = Self.diskFacts(for: registration)
    if facts.olderRevisionSurvives {
      // The TARGET version travels with the state so copy never hard-codes a
      // model release: a revision ships as a manifest edit with no Swift
      // change, and a literal would then name the wrong version confidently.
      return .updatePaused(resumable: facts.hasPartials, targetVersion: version)
    }
    return facts.hasPartials ? .paused : .notInstalled
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
