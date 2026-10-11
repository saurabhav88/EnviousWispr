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

/// #1525 PR G. Pins this struct's exact measured current wire identity
/// (`docs/audits/2026-07-14-1525-pr-g-preflight.md` §1) — a fixed string,
/// not a switch, confirmed empirically constant across all 10
/// `DeliveryFailureClass` reasons. Reaches Sentry via the model-load-failed
/// path when Parakeet delivery cannot be ensured available. NEVER change
/// this string once shipped.
extension ParakeetDeliveryError: StableSentryErrorIdentity {
  public var sentryFingerprintDescriptor: String {
    "EnviousWisprPipeline.ParakeetDeliveryError#1"
  }

  public var sentrySemanticID: String { "parakeet.delivery_failed" }
}

/// Pipeline-side handle for the Parakeet delivery stage (#1348 Phase 2): the
/// one object the adapter talks to. Owns the flag read (one authority for
/// "is delivery on"), the ProgressFile bridge for the DOWNLOAD phase (the
/// host now feeds the same progress channel onboarding and the wedge guard
/// already watch; the service keeps feeding the compile/load phase), and the
/// controller calls. Built once by `WisprBootstrapper`.
@MainActor
public final class ParakeetDeliveryHandle {
  /// #3546: where this handle's progress goes. Production writes the shared
  /// progress file; tests inject a recording sink so nothing touches the file
  /// the dev app and other suites share.
  package struct ProgressSink: Sendable {
    package let write: @Sendable (_ fraction: Double, _ phase: String, _ detail: String) -> Void
    package let clear: @Sendable () -> Void

    package init(
      write: @escaping @Sendable (Double, String, String) -> Void,
      clear: @escaping @Sendable () -> Void
    ) {
      self.write = write
      self.clear = clear
    }

    package static let shared = ProgressSink(
      write: { ProgressFile.shared.write(fraction: $0, phase: $1, detail: $2) },
      clear: { ProgressFile.shared.clear() })
  }

  /// #3546: who owns the shared progress channel for this handle's attempts.
  /// `.always`: every attempt is the foreground's (the serving model's handle,
  /// exactly as before). `.scoped`: only while a foreground operation holds it
  /// (the Ultra target, whose background fetch must never write or clear the
  /// foreground warm-up's progress).
  package enum ProgressOwnership: Sendable { case always, scoped }

  private let controller: ModelDeliveryController
  private let registration: DeliveryRegistration
  private let defaults: UserDefaults
  private let progress: ProgressSink
  private let owners: ForegroundProgressOwners
  package let progressOwnership: ProgressOwnership
  /// `.scoped` only: progress events applied strictly in publication order,
  /// so a foreground caller can wait for every event up to its outcome.
  private let progressDelivery = ForegroundProgressDelivery()
  /// The progress observer's registration; a foreground operation waits for
  /// it so no early state of its own attempt is missed.
  private var progressObservation: Task<Void, Never>?

  public convenience init(
    controller: ModelDeliveryController, registration: DeliveryRegistration,
    defaults: UserDefaults? = nil
  ) {
    self.init(
      controller: controller, registration: registration, defaults: defaults,
      progressOwnership: .always, progress: .shared)
  }

  package init(
    controller: ModelDeliveryController, registration: DeliveryRegistration,
    defaults: UserDefaults? = nil, progressOwnership: ProgressOwnership,
    progress: ProgressSink
  ) {
    self.controller = controller
    self.registration = registration
    self.defaults = defaults ?? UserDefaults(suiteName: DeliveryFlags.suiteName) ?? .standard
    self.progress = progress
    self.progressOwnership = progressOwnership
    let owners = ForegroundProgressOwners(always: progressOwnership == .always)
    self.owners = owners
    let identity = registration.manifest.identity
    let delivery = progressDelivery
    let scoped = progressOwnership == .scoped
    progressObservation = Task {
      await controller.addStateObserver { [identity] observedIdentity, state in
        guard observedIdentity == identity else { return }
        // Ownership is captured HERE, in publication order on the controller
        // actor, not when the queued event reaches the main actor: an event
        // published by background work must never be attributed to a
        // foreground operation that started after it.
        guard let epoch = owners.ownedEpoch() else { return }
        let apply: @MainActor @Sendable () -> Void = {
          guard owners.isCurrent(epoch) else { return }
          Self.bridgeToProgressFile(state, progress)
        }
        if scoped {
          delivery.enqueue(apply)
        } else {
          Task { @MainActor in apply() }
        }
      }
    }
  }

  /// #3546: this registration's delivery states, in publication order, each
  /// with a token `capture` reads AT PUBLICATION on the controller actor, so
  /// an owner can tell which of its operations an event belongs to.
  package func observeState<Token: Sendable>(
    capture: @escaping @Sendable () -> Token,
    _ handler: @escaping @MainActor @Sendable (DeliveryState, Token) -> Void
  ) {
    let identity = registration.manifest.identity
    let sequencer = DeliveryStateSequencer()
    let gate = AppliedStateGate()
    Task {
      await controller.addStateObserver { [identity] observedIdentity, state in
        guard observedIdentity == identity else { return }
        let token = capture()
        let seq = sequencer.next()
        Task { @MainActor in
          guard gate.admit(seq) else { return }
          handler(state, token)
        }
      }
    }
  }

  /// #3546: `ensureAvailable()` and `repair()` as a FOREGROUND operation of a
  /// `.scoped` handle: the progress channel is this caller's for the duration,
  /// including when it joins an attempt background work started. The download
  /// boundary is the `.admitted` event's clear, delivered through the ordered
  /// publication stream; the caller waits for that stream before returning,
  /// so nothing from this attempt writes or clears progress once it starts
  /// loading. (`.always` handles keep the queued clear they always had, plus
  /// this direct one.)
  package func ensureAvailableInForeground() async -> ModelDeliveryController.DeliveryOutcome {
    await inForeground { await self.ensureAvailable() }
  }

  package func repairInForeground() async -> ModelDeliveryController.DeliveryOutcome {
    await inForeground { await self.repair() }
  }

  private func inForeground(
    _ operation: () async -> ModelDeliveryController.DeliveryOutcome
  ) async -> ModelDeliveryController.DeliveryOutcome {
    await progressObservation?.value
    guard !Task.isCancelled else {
      return .cancelled(resumable: await controller.hasStagedPartials(registration))
    }
    owners.acquire()
    let outcome = await operation()
    if progressOwnership == .scoped {
      await progressDelivery.drain()
    } else if case .admitted = outcome {
      progress.clear()
    }
    owners.release()
    return outcome
  }

  /// Test seams (internal): wait for every queued progress event; delay each.
  func drainProgressForTesting() async {
    await progressDelivery.drain()
  }

  func setProgressDelayForTesting(_ delay: (@MainActor @Sendable () async -> Void)?) {
    progressDelivery.setDelayForTesting(delay)
  }

  /// #3546: the bundled manifest's revision and byte total, for the load
  /// request the adapter writes. Read-only facts of this handle's registration.
  package var modelRevision: String { registration.manifest.identity.revision }
  package var modelTotalBytes: Int64 { registration.manifest.totalBytes }

  /// The D5 kill-switch, read fresh per warm-up (relaunch-free legacy
  /// fallback; the service's offline switch follows via `cacheOnly`).
  public func isEnabled() -> Bool {
    defaults.object(forKey: DeliveryFlags.key("enabled", family: .parakeet)) as? Bool ?? true
  }

  public func ensureAvailable() async -> ModelDeliveryController.DeliveryOutcome {
    await controller.ensureModelAvailable(registration, onFetchDecision: onFetchDecisionForTesting)
  }

  /// Test seam (internal): told whether each `ensureAvailable()` started an
  /// attempt or joined a running one.
  var onFetchDecisionForTesting: (@Sendable (ModelDeliveryController.FetchDecision) -> Void)?

  /// The install directory, once it is safe to read and once anything the user
  /// already has on disk has been brought into it (#2697).
  ///
  /// **The single door.** Every consumer of the Parakeet location goes through
  /// this, including the kill-switch branch, which is the whole point: donor
  /// migration used to live inside a delivery attempt, so the one branch that
  /// runs no attempt got no migration and re-downloaded 483 MB online, or could
  /// not warm up at all offline, with a complete copy on disk the whole time.
  ///
  /// Returns `nil` when the location is REFUSED — currently when it resolves
  /// inside the donor. A refusal must never be substitutable by a caller
  /// resolving a path of its own, which is why nothing else may answer this
  /// question.
  public func ensureModelLocationReady(
    onProgress: (@Sendable () -> Void)? = nil
  ) async -> URL? {
    // #2695: an UNAVAILABLE resolution refuses here, and refusing is the whole
    // point of returning an optional. `isUnavailable` can be true while
    // `dataDirectory` still holds a real path — that path is for an error
    // message to NAME, never a destination — so taking it because it is non-nil
    // is exactly the defect the flag exists to prevent.
    guard !StorageRoot.live.isUnavailable else { return nil }
    guard ModelDeliveryController.installLocationIsSafe(registration) else { return nil }
    // Review A1: migration hashes whole files, and the sessionless wedge guard
    // reads SILENCE as a wedge. Without a tick, a migration slow enough to
    // matter is indistinguishable from a hang, and the user is told the app is
    // stuck while it is working. The validating phase is the right one: the
    // guard PARKS on it rather than judging it, which is exactly the contract
    // for a multi-second hash the user did not ask for.
    let progress = self.progress
    let tick: @Sendable () -> Void = {
      progress.write(0, ModelLoadStallPolicy.validatingCachePhase, "")
      onProgress?()
    }
    await controller.ensureLegacyMigration(registration, onProgress: tick)
    return registration.installDirectory
  }

  /// #3546: read-only facts and non-fetching operations the upgrade policy
  /// needs for THIS handle's registration (the v3 identity it accepts, or the
  /// Ultra target it upgrades to).
  package var installDirectory: URL { registration.installDirectory }
  package var cacheKey: String { registration.manifest.identity.cacheKey }
  package var metadataDirectory: URL { registration.metadataDirectory }
  /// The same two refusals `ensureModelLocationReady` makes before it acts:
  /// unavailable storage, or an install location inside the donor.
  package var locationIsUsable: Bool {
    !StorageRoot.live.isUnavailable && ModelDeliveryController.installLocationIsSafe(registration)
  }

  /// The admission marker fast path (digest, sizes, recorded mtimes); no hashing.
  package func isAdmitted() async -> Bool {
    await controller.isAdmitted(registration)
  }

  /// Full validation of the owned install and a marker refresh when it is
  /// complete; never fetches (`ModelDeliveryController.admitIfComplete`).
  package func admitIfComplete() async -> Bool {
    await controller.admitIfComplete(registration)
  }

  /// Read-only donor recovery that a completed migration record does not
  /// suppress (a declined one still does). Ticks the shared progress file like
  /// `ensureModelLocationReady`, for the same wedge-guard reason.
  package func recoverFromDonor() async {
    let progress = self.progress
    await controller.recoverFromDonor(
      registration,
      onProgress: {
        progress.write(0, ModelLoadStallPolicy.validatingCachePhase, "")
      })
  }

  /// Deletes this registration's whole owned install, marker and staging,
  /// recording no decline (`ModelDeliveryController.retireOwnedInstall`).
  package func retireOwnedInstall(ownedModelsRoot: URL) async -> Bool {
    await controller.retireOwnedInstall(registration, ownedModelsRoot: ownedModelsRoot)
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
  private static func bridgeToProgressFile(_ state: DeliveryState, _ file: ProgressSink) {
    switch state {
    case .preparing(let validating):
      file.write(
        0,
        // Single authority for both literals: the wedge guard PARKS on the
        // validating phase and JUDGES the listing phase (#1388 Codex r4).
        validating
          ? ModelLoadStallPolicy.validatingCachePhase : ModelLoadStallPolicy.listingPhase,
        "")
    case .downloading(let fraction, let bytesWritten, let totalBytes):
      let mb = Int(Double(bytesWritten) / 1_048_576)
      let totalMB = Int(Double(totalBytes) / 1_048_576)
      file.write(
        fraction * 0.5,
        // Single authority for this literal (the wedge guard parks on it, #1405).
        ModelLoadStallPolicy.downloadingPhase,
        "\(mb) MB of \(totalMB) MB (\(Int(fraction * 100))%)")
    case .verifying:
      // Single authority for the literal (the wedge guard parks on it, #1388).
      file.write(0.5, ModelLoadStallPolicy.verifyingDownloadPhase, "")
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
      file.clear()
    case .notReady, .cancelled, .failed:
      break
    }
  }
}

/// #3546: foreground ownership of a handle's progress channel. Read on the
/// controller actor when a state is published, so it is lock-protected.
/// `ownedEpoch()` is nil when no foreground operation owns the channel; the
/// epoch moves each time ownership ends, so an event captured under an ended
/// ownership is dropped when it reaches the main actor.
final class ForegroundProgressOwners: @unchecked Sendable {
  private let lock = NSLock()
  private let always: Bool
  private var count = 0
  private var epoch: UInt64 = 0

  init(always: Bool) { self.always = always }

  func ownedEpoch() -> UInt64? {
    lock.withLock { always || count > 0 ? epoch : nil }
  }

  func isCurrent(_ captured: UInt64) -> Bool {
    lock.withLock { captured == epoch && (always || count > 0) }
  }

  func acquire() {
    lock.withLock { count += 1 }
  }

  func release() {
    lock.withLock {
      count -= 1
      if count == 0 { epoch &+= 1 }
    }
  }
}

/// #3546: applies a `.scoped` handle's progress events on the main actor in
/// publication order (each waits for the one before), so `drain()` returns
/// only after every event published so far has been applied.
final class ForegroundProgressDelivery: @unchecked Sendable {
  private let lock = NSLock()
  private var tail: Task<Void, Never>?
  /// Test seam (internal): awaited before each event is applied, so a test can
  /// deliver progress late and prove callers wait for it.
  private var delayForTesting: (@MainActor @Sendable () async -> Void)?

  func setDelayForTesting(_ delay: (@MainActor @Sendable () async -> Void)?) {
    lock.withLock { delayForTesting = delay }
  }

  func enqueue(_ apply: @escaping @MainActor @Sendable () -> Void) {
    lock.withLock {
      let previous = tail
      let delay = delayForTesting
      tail = Task { @MainActor in
        if let previous { await previous.value }
        if let delay { await delay() }
        apply()
      }
    }
  }

  func drain() async {
    let pending = lock.withLock { tail }
    if let pending { await pending.value }
  }
}
