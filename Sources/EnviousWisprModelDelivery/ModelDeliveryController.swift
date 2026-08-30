import EnviousWisprCore
import Foundation

/// What one model needs delivered: the manifest plus WHERE it installs and
/// where delivery bookkeeping lives. Built once per family by the app layer.
public struct DeliveryRegistration: Sendable {
  public let manifest: DeliveryManifest
  public let installDirectory: URL
  public let metadataDirectory: URL

  public init(manifest: DeliveryManifest, installDirectory: URL, metadataDirectory: URL) {
    self.manifest = manifest
    self.installDirectory = installDirectory
    self.metadataDirectory = metadataDirectory
  }
}

/// D5's local override flags, snapshotted ONCE at fetch start (mutation
/// mid-attempt never re-read — actor-reentrancy discipline). Operational
/// support keys in the SHARED suite, not user settings.
public struct DeliveryFlags: Sendable {
  public static let suiteName = "com.enviouswispr.app"

  public let familyEnabled: Bool
  public let sourceOrder: String?
  public let mirrorDisabled: Bool
  public let backupDisabled: Bool
  public let forceRevalidate: Bool

  public static func key(_ leaf: String, family: ModelFamily?) -> String {
    if let family { return "modelDelivery.\(family.rawValue).\(leaf)" }
    return "modelDelivery.\(leaf)"
  }

  public static func snapshot(family: ModelFamily, defaults: UserDefaults) -> DeliveryFlags {
    DeliveryFlags(
      familyEnabled: defaults.object(forKey: key("enabled", family: family)) as? Bool ?? true,
      sourceOrder: defaults.string(forKey: key("sourceOrder", family: family)),
      mirrorDisabled: defaults.bool(forKey: key("mirrorDisabled", family: nil)),
      backupDisabled: defaults.bool(forKey: key("backupDisabled", family: nil)),
      forceRevalidate: defaults.bool(forKey: key("forceRevalidate", family: family)))
  }

  /// Non-default observations for `flag_active` proof (D5 §1). `enabled` is
  /// reported by the ADAPTER at its bypass site (this snapshot only runs when
  /// delivery is on).
  var activeOverrides: [(flag: String, value: String)] {
    var active: [(String, String)] = []
    if let sourceOrder { active.append(("sourceOrder", sourceOrder)) }
    if mirrorDisabled { active.append(("mirrorDisabled", "true")) }
    if backupDisabled { active.append(("backupDisabled", "true")) }
    if forceRevalidate { active.append(("forceRevalidate", "true")) }
    return active
  }

  /// Manifest sources reordered/restricted per flags. Order is the ONLY
  /// mutable thing — hashes never (trust root, contract §4a). An override
  /// that would empty the list falls back to the manifest order (a support
  /// flag must not brick delivery).
  func orderedSources(from manifest: DeliveryManifest) -> [DeliveryManifest.Source] {
    var sources = manifest.sources
    if let sourceOrder {
      let wanted = sourceOrder.split(separator: ",").map {
        $0.trimmingCharacters(in: .whitespaces)
      }
      // First-wins: a manifest with a duplicate source id must degrade, not
      // trap (#1671). Every other branch here is fail-soft on bad input; a
      // publishing typo on remote manifest data must not be the one line that
      // crashes the app.
      let byID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      let reordered = wanted.compactMap { byID[$0] }
      if !reordered.isEmpty { sources = reordered }
    }
    if mirrorDisabled { sources.removeAll { $0.id == "our_copy" } }
    if backupDisabled { sources.removeAll { $0.id == "backup" } }
    if sources.isEmpty { sources = manifest.sources }
    return sources
  }
}

/// The single delivery authority (epic #1348, D4): owns manifest-pinned
/// fetch, verification, admission, cancellation, and the disk reservation
/// ledger for every registered model identity. One writer per cache;
/// single-flight join per identity; downloads live in the HOST process and
/// end at a verified cache (invariant 9 — this type never loads models).
///
/// Born from `EGOneModelStore` (#1271/#1287): generation token, drain
/// barrier, resume identity, verify-then-atomic-promote, disk preflight —
/// generalized from one file to manifest component sets. EG-1's own store
/// converges here at Phase 3.
public actor ModelDeliveryController {
  /// Terminal outcome of `ensureModelAvailable`.
  public enum DeliveryOutcome: Sendable, Equatable {
    case admitted
    case failed(DeliveryFailure)
    case cancelled(resumable: Bool)
  }

  /// Terminal outcome of `remove` (#1363 §16.1).
  public enum RemoveOutcome: Sendable, Equatable {
    case removed
    case failed(DeliveryFailure)
  }

  private struct Entry {
    var state: DeliveryState = .notReady
    var activeTask: Task<DeliveryOutcome, Never>?
    /// Whether the in-flight `activeTask` will FETCH a missing/incomplete cache
    /// (an explicit download door) vs. being a NO-FETCH probe (`admitIfComplete`,
    /// the activation path). A fetch-wanting caller must never join a no-fetch
    /// probe — the probe bails `not_present_no_fetch`, which would silently
    /// no-op a user's Download click (cloud-review P2, PR #1363).
    var activeTaskFetches = true
    var generation = 0
    /// Cancelled/superseded task possibly still draining its URLSession
    /// delegate queue; task completion IS the drain signal (EG-1 #1287).
    var drainingTask: Task<DeliveryOutcome, Never>?
    /// Bytes reserved on this volume while the fetch runs (D4 §2 ledger).
    var reservedBytes: Int64 = 0
    /// Fixed inputs for reservation shrink math: progress callbacks report
    /// CUMULATIVE bytes, so the reservation is recomputed from these each
    /// tick — never decremented repeatedly (code-diff r1 P2).
    var reservationRemainingBase: Int64 = 0
    var reservationProgressBaseline: Int64 = 0
    var reservationHeadroom: Double = 1.0
    /// First-wins cancel latch: ties the cancel EVENT to the winning exit so
    /// a racing failure can't double-emit (audit-all-terminal-paths rule).
    var cancelLatched = false
  }

  private var entries: [ModelIdentity: Entry] = [:]
  private var stateObservers: [@Sendable (ModelIdentity, DeliveryState) -> Void] = []
  private var eventObservers: [@Sendable (ModelIdentity, DeliveryEvent) -> Void] = []
  /// Events emitted before the first event observer attaches (see
  /// `addEventObserver` — the launch-window race). Bounded in `emit`.
  private var pendingEvents: [(ModelIdentity, DeliveryEvent)] = []
  /// `admittedWithoutFetch` dedupe (#1363 §16.3): once per identity per reason
  /// per process, keyed `cacheKey|reason`. Warm reopen / provider-reselect /
  /// retry all re-hit the fast path — without this they would inflate an
  /// availability signal into an attempt count. Process-scoped by design.
  private var admittedWithoutFetchSeen: Set<String> = []
  private let defaults: UserDefaults
  /// Test seam for disk capacity (production reads the volume).
  private let availableDiskBytes: @Sendable (URL) -> Int64?

  public init(
    defaults: UserDefaults? = nil,
    availableDiskBytes: @escaping @Sendable (URL) -> Int64? = ModelDeliveryController
      .volumeAvailableBytes
  ) {
    self.defaults = defaults ?? UserDefaults(suiteName: DeliveryFlags.suiteName) ?? .standard
    self.availableDiskBytes = availableDiskBytes
  }

  // MARK: - Observation (one stream, two renderers — D6)

  /// Attach-time replay: observers register from `Task`s after init, so a
  /// fast first attempt (a preflight reject takes milliseconds) can reach a
  /// terminal state before anyone listens. Without replay the UI mirror
  /// stays `.notReady` forever — a dead engine with no failure copy and no
  /// Try Again (drill 12, 2026-07-06). Each new observer immediately sees
  /// the current state of every known identity.
  public func addStateObserver(
    _ observer: @escaping @Sendable (ModelIdentity, DeliveryState) -> Void
  ) {
    stateObservers.append(observer)
    for (identity, entry) in entries {
      observer(identity, entry.state)
    }
  }

  /// Events emitted before the FIRST observer attaches are buffered and
  /// drained to it in order (telemetry for a launch-window failure must not
  /// be lost — same race as the state replay above). Observers attaching
  /// after the first see only future events: replaying history to a second
  /// renderer would double-count telemetry.
  public func addEventObserver(
    _ observer: @escaping @Sendable (ModelIdentity, DeliveryEvent) -> Void
  ) {
    let isFirst = eventObservers.isEmpty
    eventObservers.append(observer)
    if isFirst {
      for (identity, event) in pendingEvents {
        observer(identity, event)
      }
      pendingEvents.removeAll()
    }
  }

  public func state(of identity: ModelIdentity) -> DeliveryState {
    entries[identity]?.state ?? .notReady
  }

  /// Whether the identity's cache is currently admitted (marker fast path;
  /// no events, no rehash — D7 rows 11/16).
  public func isAdmitted(_ registration: DeliveryRegistration) -> Bool {
    admission(for: registration).isAdmitted()
  }

  /// Emit a `flag_active` proof for a flag whose effect lives OUTSIDE an
  /// attempt (the `enabled=false` legacy bypass never reaches `runAttempt`,
  /// so its one taking site reports through here — D5 §1).
  public func noteFlagActive(identity: ModelIdentity, flag: String, value: String) {
    emit(identity, .flagActive(flag: flag, value: value))
  }

  // MARK: - The single door

  /// Ensure the model's cache is admitted, fetching/repairing as needed.
  /// Single-flight JOIN: a second caller while one runs awaits the SAME
  /// task's outcome (D4 §2 — two windows, onboarding + cold-press).
  /// - Parameter onFetchDecision: reports START-vs-JOIN at the instant this
  ///   controller decides it, which is the only instant the answer exists and is
  ///   still useful (#2110). A caller that needs to know whether the download
  ///   running is ITS OWN cannot learn it from the outcome: by then the download
  ///   is over, and the question is asked while it runs, when Cancel arrives.
  ///
  ///   Deliberately a callback rather than a return value or an owner the
  ///   controller stores. An owner field would let a caller ASK later, which
  ///   reads as the safer design and is not: between the question and the cancel
  ///   the observed task can finish and another can start, so the answer is
  ///   stale exactly when it matters. Reporting the decision leaves ownership
  ///   where it belongs — with the caller who made the call.
  ///
  ///   Fired synchronously on this actor, so it must not block; every caller
  ///   hops it onward itself.
  public func ensureModelAvailable(
    _ registration: DeliveryRegistration,
    onFetchDecision: (@Sendable (FetchDecision) -> Void)? = nil
  ) async -> DeliveryOutcome {
    await joinOrStartFetch(registration, trigger: nil, onFetchDecision: onFetchDecision)
  }

  /// Whether a call to an explicit-fetch door STARTED the shared fetch or JOINED
  /// one already running.
  public enum FetchDecision: Sendable, Equatable {
    case started
    case joined
  }

  /// Shared join logic for the two EXPLICIT-fetch doors (`ensureModelAvailable`,
  /// `repair`). A fetch-wanting caller joins an in-flight FETCH attempt (true
  /// single-flight), but must NEVER coalesce into an in-flight NO-FETCH probe
  /// (`admitIfComplete`): for a missing/incomplete cache the probe bails with
  /// `.notReady` / `.failed(not_present_no_fetch)`, so joining it would make a
  /// user's explicit Download click silently no-op (cloud-review P2, PR #1363).
  /// When only a probe is in flight, supersede it via the PROVEN cancel/drain
  /// path — hand it to the drain slot and cancel it; `startAttempt` then bumps
  /// the generation (so the probe self-cancels at its next generation check)
  /// and the new fetch task awaits the probe's teardown before touching disk.
  /// A second fetch caller in the same wave sees the fetch task installed
  /// synchronously by `startAttempt` and joins it (no double-start, no spin).
  private func joinOrStartFetch(
    _ registration: DeliveryRegistration, trigger: DeliveryEvent.ValidationTrigger?,
    onFetchDecision: (@Sendable (FetchDecision) -> Void)? = nil
  ) async -> DeliveryOutcome {
    let identity = registration.manifest.identity
    if let active = entries[identity, default: Entry()].activeTask,
      entries[identity]?.activeTaskFetches == true
    {
      onFetchDecision?(.joined)
      return await active.value
    }
    if let probe = entries[identity]?.activeTask {
      // No-fetch probe in flight (activeTaskFetches == false): supersede it.
      // activeTask non-nil implies drainingTask nil (startAttempt nulls it when
      // it installs the task), so this never clobbers a live drain.
      entries[identity]?.drainingTask = probe
      entries[identity]?.activeTask = nil
      probe.cancel()
    }
    // Superseding a no-fetch probe still STARTS this caller's fetch.
    onFetchDecision?(.started)
    return await startAttempt(registration, trigger: trigger)
  }

  /// Adopt an already-complete cache WITHOUT fetching (the activation path,
  /// grounded r4 P2): marker fast path, or validate + admit-in-place if every
  /// component is already present and valid. Returns `true` when the cache is
  /// now admitted; `false` when a fetch would be required — in which case
  /// NOTHING is fetched and NO failure event fires (the state settles at
  /// `.notReady`, i.e. "not installed"). This is what a backend adapter calls
  /// on launch / provider-switch / settings-open so those paths never start a
  /// multi-GB download behind the user's back; the EXPLICIT download door is
  /// `ensureModelAvailable`. Joins an in-flight fetch if one is already running
  /// (a user-initiated download in progress legitimately admits it).
  public func admitIfComplete(_ registration: DeliveryRegistration) async -> Bool {
    let identity = registration.manifest.identity
    if let active = entries[identity, default: Entry()].activeTask {
      if case .admitted = await active.value { return true }
      return false
    }
    if case .admitted = await startAttempt(registration, trigger: nil, fetchIfMissing: false) {
      return true
    }
    return false
  }

  /// The load-miss repair path (grounded r1 revision 7): identical pipeline
  /// with forced revalidation semantics; emits `validation_repair` with
  /// trigger `load_miss` when components were repaired.
  public func repair(_ registration: DeliveryRegistration) async -> DeliveryOutcome {
    await joinOrStartFetch(registration, trigger: .loadMiss)
  }

  /// Cooperative cancel (D4 §3): resolves only after the live attempt fully
  /// drained (no partial in final cache is structural — staging-only writes;
  /// marker not written; handles closed via task completion).
  public func cancel(_ identity: ModelIdentity) async -> CancelOutcome {
    guard var entry = entries[identity], let task = entry.activeTask else {
      return .nothingToCancel
    }
    entry.generation += 1
    entry.cancelLatched = true
    entry.drainingTask = task
    entry.activeTask = nil
    entries[identity] = entry
    // The move to draining has LANDED here, so this is the only honest place to
    // announce it. Fired before `task.cancel()` because a test that wants to
    // observe the live draining window must be released while the window is
    // open, not after the drain has been asked to end (#2119 test support).
    afterMovedToDrainingForTesting?()
    task.cancel()
    // Drain barrier: the attempt task finishes only after its URLSession
    // delegate delivered terminal completion and file handles closed —
    // signal-based, no timer (EG-1 #1287).
    let outcome = await task.value
    // The generation bump above orphaned the attempt's own clearTask, so
    // release the ledger here — a cancelled download must not keep blocking
    // other identities' disk preflight (code-diff r5 P2).
    //
    // Clear `drainingTask` for the same reason, and it matters more since
    // #2119 (found by review of that chunk). It used to be cleared ONLY by the
    // next `startAttempt`, so an identity cancelled and never resumed kept a
    // non-nil `drainingTask` for the process lifetime. The staging sweep reads
    // that field as "work in flight", so it would have protected exactly the
    // abandoned downloads it exists to reclaim — a no-op for the feature's
    // primary population.
    //
    // Safe here and not earlier: the `await task.value` above IS the drain
    // barrier, so by this line there is nothing left for a later
    // `startAttempt` to wait on. Generation-guarded so a NEW attempt that
    // started during the await keeps its own draining task.
    if entries[identity]?.generation == entry.generation {
      entries[identity]?.drainingTask = nil
    }
    entries[identity]?.reservedBytes = 0
    if case .admitted = outcome {
      // Completion won the race (its terminal slice ran before our bump was
      // observed): the cache IS admitted — no cancel event, no cancelled
      // state (exhaustive r7 P1: one terminal event per attempt).
      entries[identity]?.cancelLatched = false
      setState(identity, .admitted)
      return .nothingToCancel
    }
    let resumable = hasStagedPartials(identity: identity)
    setState(identity, .cancelled(resumable: resumable))
    emit(identity, .cancel(phaseAtCancel: phaseAtCancel(identity: identity), resumable: resumable))
    return .cancelled(resumable: resumable)
  }

  /// Evict a model (#1363 §16.1): cancel + drain any live attempt, delete the
  /// admission marker FIRST (after which nothing reports admitted), remove the
  /// manifest's component roots from the install dir, clear staging, then set
  /// `.notReady`. File-deletion authority stays in the layer that owns the
  /// marker + orphan rules (this actor + `CacheAdmission`), never a backend
  /// adapter. Generic — Parakeet has no first-class evict either; EG-1's
  /// adapter calls it after stopping its server.
  /// 2c: whether a cancelled download left resumable partials in this
  /// identity's staging area — the disk truth behind the "paused" presentation
  /// (it survives relaunches, unlike any in-memory flag).
  ///
  /// Cloud review (PR #1637, two rounds): a metadata-only staging shell must
  /// not read as resumable. Round 1 excluded `.resume.json` sidecars but
  /// still counted directory entries as "content" — a nested model layout
  /// (e.g. `Encoder.mlmodelc/` holding only its own sidecar) walked via
  /// `subpathsOfDirectory` yields the directory name itself as an entry,
  /// which passes the suffix filter and reads as resumable even though it
  /// holds zero real bytes. This walks with resource values instead and
  /// requires an actual REGULAR FILE with positive size — a directory or an
  /// empty file proves nothing was downloaded.
  public func hasStagedPartials(_ registration: DeliveryRegistration) -> Bool {
    Self.hasStagedPartialsOnDisk(registration)
  }

  /// The same disk truth, callable WITHOUT the actor (#2109).
  ///
  /// EG-1's install-state mapper is a synchronous `nonisolated static func`
  /// running inside a state-observer callback, so it cannot `await` an actor
  /// method — and making it await would put a suspension inside the window the
  /// install-state sequencer exists to protect. The read was always pure; only
  /// the incidental registration-cache write in the old `stagingDirectory`
  /// made it isolated, and that write now lives in `startAttempt`.
  ///
  /// A `.resume.json` sidecar proves nothing was downloaded, and neither does
  /// a directory or an empty file: this requires a REGULAR FILE of positive
  /// size (PR #1637, two cloud-review rounds — a nested model layout walked
  /// via `subpathsOfDirectory` yields directory names that pass a suffix
  /// filter while holding zero real bytes).
  nonisolated package static func hasStagedPartialsOnDisk(_ registration: DeliveryRegistration)
    -> Bool
  {
    let staging = stagingDirectoryURL(for: registration)
    guard
      let enumerator = FileManager.default.enumerator(
        at: staging, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
    else { return false }
    for case let url as URL in enumerator {
      guard !url.lastPathComponent.hasSuffix(".resume.json") else { continue }
      guard
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
        values.isRegularFile == true, let size = values.fileSize, size > 0
      else { continue }
      return true
    }
    return false
  }

  public func remove(_ registration: DeliveryRegistration) async -> RemoveOutcome {
    let identity = registration.manifest.identity
    // Drain any live attempt first (reuses the cancel drain barrier); a
    // nothing-in-flight cancel is a no-op.
    _ = await cancel(identity)
    let admission = admission(for: registration)
    let fm = FileManager.default
    do {
      // (1) Marker first: the admission truth. After this isAdmitted() is false.
      if fm.fileExists(atPath: admission.markerURL.path) {
        try fm.removeItem(at: admission.markerURL)
      }
      // (2) The model files: every top-level install root the manifest claims.
      for root in CacheAdmission.componentRoots(of: registration.manifest) {
        let url = registration.installDirectory.appendingPathComponent(root)
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
      }
      // (3) Staging for this identity (any resumable partials).
      let staging = stagingDirectory(for: registration)
      if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
    } catch {
      let failure = DeliveryFailure(reason: .cacheRepairFailed, detail: "remove")
      setState(identity, .failed(failure))
      return .failed(failure)
    }
    setState(identity, .notReady)
    await AppLogger.shared.log(
      "Model delivery removed \(identity.cacheKey)", level: .info, category: "Delivery")
    return .removed
  }

  // MARK: - Attempt lifecycle

  private func startAttempt(
    _ registration: DeliveryRegistration, trigger: DeliveryEvent.ValidationTrigger?,
    fetchIfMissing: Bool = true
  ) async -> DeliveryOutcome {
    let identity = registration.manifest.identity
    // Cache the registration HERE, before the attempt task exists and before
    // any suspension (#2109). It used to be written as a side effect of
    // `stagingDirectory(for:)`, which is only reached AFTER the suspending
    // existing-cache validation — so a cancel arriving in that window found no
    // registration and `hasStagedPartials(identity:)` returned false, reporting
    // a resumable download as non-resumable on all three cancel/terminal paths.
    // Every door lands here: `ensureModelAvailable` and `repair` route through
    // `joinOrStartFetch`, and `admitIfComplete` calls `startAttempt` directly.
    registrationsByIdentity[identity] = registration
    var entry = entries[identity, default: Entry()]
    entry.generation += 1
    entry.cancelLatched = false
    entry.activeTaskFetches = fetchIfMissing
    let generation = entry.generation
    let drain = entry.drainingTask
    entry.drainingTask = nil
    entries[identity] = entry

    let task = Task<DeliveryOutcome, Never> { [weak self] in
      if let drain { _ = await drain.value }
      guard let self else { return .failed(DeliveryFailure(reason: .unknown, detail: "gone")) }
      return await self.runAttempt(
        registration, generation: generation, trigger: trigger, fetchIfMissing: fetchIfMissing)
    }
    entries[identity]?.activeTask = task
    let outcome = await task.value
    clearTask(identity: identity, generation: generation)
    return outcome
  }

  private func clearTask(identity: ModelIdentity, generation: Int) {
    guard var entry = entries[identity], entry.generation == generation else { return }
    entry.activeTask = nil
    entry.reservedBytes = 0
    entries[identity] = entry
  }

  private func runAttempt(
    _ registration: DeliveryRegistration, generation: Int,
    trigger: DeliveryEvent.ValidationTrigger?, fetchIfMissing: Bool = true
  ) async -> DeliveryOutcome {
    let identity = registration.manifest.identity
    let manifest = registration.manifest
    // Post-drain staleness stop (EG-1 #1287): a superseded attempt must not
    // touch disk.
    guard entries[identity]?.generation == generation else {
      return .failed(DeliveryFailure(reason: .cancelled))
    }
    let flags = DeliveryFlags.snapshot(family: identity.family, defaults: defaults)
    for (flag, value) in flags.activeOverrides {
      emit(identity, .flagActive(flag: flag, value: value))
    }
    let forceRevalidate = flags.forceRevalidate || trigger == .loadMiss
    if flags.forceRevalidate {
      // One-shot: self-clears after the pass it forced (D5 §1).
      defaults.removeObject(forKey: DeliveryFlags.key("forceRevalidate", family: identity.family))
    }

    let admission = admission(for: registration)

    // Marker fast path: admitted and not forced → done, no fetch (D7 row 11).
    // Emit the deduped availability signal (#1363 Decision E) so a warm
    // relaunch's cache hit is not invisible in the field.
    if !forceRevalidate, admission.isAdmitted() {
      // Emit BEFORE publishing `.admitted` (grounded r3 P2): an app-layer
      // observer flips its per-identity first_run baseline to false on
      // `.admitted`, so the availability event must be captured with the
      // pre-admission baseline. Enqueuing the event observer's work before the
      // state observer's preserves first_run=true for a genuine first run.
      emitAdmittedWithoutFetch(identity, reason: .markerFastPath)
      setState(identity, .admitted, ifGeneration: generation)
      return .admitted
    }

    // Existing-cache validation (D2 §4): one full hash pass, component grain.
    setState(identity, .preparing(validatingExistingCache: true), ifGeneration: generation)
    // Test-only barrier (#2109). Production is nil and this is a no-op.
    //
    // It exists because the ordering guarantee below it cannot be tested any
    // other way: in production this hash pass runs for SECONDS over gigabytes,
    // and a cancel landing inside it is the real defect. With unit fixtures the
    // same window is microseconds wide, so a polled test cannot land in it —
    // mutation-proved, a timing-based attempt passed against the pre-fix code
    // and would have shipped as coverage that detects nothing.
    await beforeExistingCacheValidationForTesting?()
    // Per-file liveness ticks: each validated file republishes the state so
    // the app-layer bridge advances the progress channel's mtime — the
    // sessionless wedge guard reads silence as a wedge, and a multi-second
    // hash pass must not be silent (D6 state 4).
    let controllerForTicks = self
    let validation = await admission.validateExistingCache(onFileValidated: { _ in
      Task { await controllerForTicks.tickValidating(identity, generation: generation) }
    })
    guard entries[identity]?.generation == generation, !Task.isCancelled else {
      return .cancelled(resumable: true)
    }

    let componentsToFetch = Set(manifest.filesByComponent.map(\.component))
      .subtracting(validation.verifiedComponents)
    // Repair means something WAS there and got replaced — a cold install's
    // all-missing components are a normal first download, not a repair
    // (code-diff r1 P3: first-run metrics must not read as repair storms).
    let repairedCount = validation.failedComponents.filter {
      admission.componentHasAnyFile($0)
    }.count

    // Everything already valid in place → admit without any fetch (legacy
    // migration path). No attempt events: no fetch sequence existed (D3).
    if componentsToFetch.isEmpty {
      do {
        try admission.promoteAndAdmit(
          stagedComponents: [], stagingDirectory: stagingDirectory(for: registration),
          untouchedComponents: validation.verifiedComponents)
      } catch {
        let failure = DeliveryFailure(reason: .cacheRepairFailed, detail: "admit_in_place")
        return await finishFailed(identity, failure, generation: generation)
      }
      // No fetch happened (existing file adopted in place — the #1363 EG-1
      // migration path). Emit the deduped availability signal so this success
      // is not invisible; it is distinct from `attemptCompleted` (Decision E).
      // Emit BEFORE `.admitted` (grounded r3 P2) so a migration adoption is
      // captured with first_run=true — the app-layer observer flips the
      // baseline false on `.admitted`.
      emitAdmittedWithoutFetch(identity, reason: .adoptedInPlace)
      setState(identity, .admitted, ifGeneration: generation)
      return .admitted
    }

    // No-fetch adopt path (grounded r4 P2): components are missing/incomplete
    // and the caller (activation / settings-open) forbids an implicit fetch.
    // Settle at `.notReady` (→ "not installed", the Download button) with NO
    // fetch and NO failure event — a fresh download is the user's explicit
    // choice via `ensureModelAvailable`, never a side effect of selecting EG-1.
    if !fetchIfMissing {
      setState(identity, .notReady, ifGeneration: generation)
      return .failed(DeliveryFailure(reason: .unknown, detail: "not_present_no_fetch"))
    }

    // Repair prep: failed components leave the install dir before re-fetch.
    for component in validation.failedComponents {
      admission.removeComponent(component)
    }

    // Disk preflight against the reservation ledger (D4 §2) — BEFORE any
    // network or staging write; a rejected attempt emits attempt_failed
    // WITHOUT attempt_started (D3).
    let staging = stagingDirectory(for: registration)
    let fetchFiles = manifest.files.filter { componentsToFetch.contains($0.component) }
    let stagedBytes = stagedByteCount(of: fetchFiles, in: staging)
    let verifiedInPlaceBytes = manifest.totalBytes - fetchFiles.reduce(0) { $0 + $1.sizeBytes }
    let remainingBytes = fetchFiles.reduce(Int64(0)) { $0 + $1.sizeBytes } - stagedBytes
    let required = Int64(Double(max(0, remainingBytes)) * manifest.admission.headroomFactor)
    let otherReservations = entries.reduce(Int64(0)) { sum, kv in
      kv.key == identity ? sum : sum + kv.value.reservedBytes
    }
    let available = availableDiskBytes(registration.installDirectory) ?? .max
    // Staged partials are NOT reclaimable headroom here: `remainingBytes`
    // already excludes them (they are kept and resumed, not re-downloaded),
    // so adding them to `available` would double-count and let a resumed
    // attempt start into ENOSPC (code-diff r2 P2). EG-1's reclaimable rule
    // applied to a REQUIRED computed from the full artifact size; ours nets
    // staged bytes out of required instead.
    if available - otherReservations < required {
      let failure = DeliveryFailure(reason: .insufficientDisk, detail: "preflight:\(required)")
      return await finishFailed(identity, failure, generation: generation)
    }
    if var entry = entries[identity] {
      entry.reservedBytes = required
      entry.reservationRemainingBase = max(0, remainingBytes)
      entry.reservationProgressBaseline = verifiedInPlaceBytes + stagedBytes
      entry.reservationHeadroom = manifest.admission.headroomFactor
      entries[identity] = entry
    }

    // Accepted: this is the attempt_started line (accept-gated, EG-1
    // discipline; resumed truth from disk).
    let resumed = stagedBytes > 0
    emit(identity, .attemptStarted(resumed: resumed))
    let startedAt = ContinuousClock.now
    setState(
      identity,
      .downloading(
        fractionCompleted: Double(verifiedInPlaceBytes + stagedBytes) / Double(manifest.totalBytes),
        bytesWritten: verifiedInPlaceBytes + stagedBytes, totalBytes: manifest.totalBytes),
      ifGeneration: generation)

    let controller = self
    let fetchTask = ManifestFetchTask(
      manifest: manifest, stagingDirectory: staging,
      sources: flags.orderedSources(from: manifest),
      componentsToFetch: componentsToFetch,
      verifiedInPlaceBytes: verifiedInPlaceBytes,
      onProgress: { bytes, total in
        Task {
          await controller.applyProgress(
            identity, bytes: bytes, total: total, generation: generation)
        }
      },
      onSourceFailover: { reason, fromSourceID, toSourceID in
        // Awaited rather than spawned. See `onSourceFailover`'s own doc: a
        // detached Task here is unordered against the `fetchTask.run()`
        // continuation below, which can publish a terminal event first or let a
        // cancel bump the generation so this call's guard drops the failover.
        // Re-entering the actor is safe: the controller is SUSPENDED at that
        // await, so it is not held.
        await controller.noteFailover(
          identity, reason: reason, fromSourceID: fromSourceID, toSourceID: toSourceID,
          generation: generation)
      })

    do {
      let outcome = try await fetchTask.run()
      // Terminal-winner gate (exhaustive r7 P1): from here through the
      // completed emit there is NO await, so this is one synchronous actor
      // slice — a racing cancel() either bumped the generation BEFORE this
      // check (cancellation wins; no promote, no completed event) or runs
      // AFTER the slice (completion won; cancel() sees .admitted and emits
      // nothing). completed + cancel can never both fire for one attempt.
      guard entries[identity]?.generation == generation, !Task.isCancelled else {
        return finishCancelled(identity, generation: generation)
      }
      setState(identity, .verifying)
      try admission.promoteAndAdmit(
        stagedComponents: componentsToFetch, stagingDirectory: staging,
        untouchedComponents: validation.verifiedComponents)
      // Repair visibility (one event per validation pass, D3): only when an
      // EXISTING cache lost components — a cold first install repairs nothing.
      if repairedCount > 0 {
        emit(
          identity,
          .validationRepair(componentsCount: repairedCount, trigger: trigger ?? .markerMismatch))
      }
      emit(
        identity,
        .attemptCompleted(
          durationBucket: Self.durationBucket(since: startedAt),
          bytesDownloadedBucket: Self.bytesBucket(outcome.bytesDownloaded),
          sourcesUsed: outcome.sourcesUsed, finalSourceID: outcome.finalSourceID,
          repairedComponentsCount: repairedCount))
      setState(identity, .admitted)
      try? FileManager.default.removeItem(at: staging)
      // Post-admission reclamation (#2119). The bootstrap call catches staging
      // abandoned before this launch; this one catches anything superseded by
      // the admission that just happened.
      sweepSupersededStaging(registration)
      // The local line is written by the `.attemptCompleted` arm of
      // `deliveryLogLine` (#2135). An ad-hoc call here as well would print TWO
      // lines for one admission, and a doubled line invites reading one
      // occurrence as two — the misreading this issue exists to prevent.
      return .admitted
    } catch let failure as DeliveryFailure where failure.reason == .cancelled {
      return finishCancelled(identity, generation: generation)
    } catch is CancellationError {
      return finishCancelled(identity, generation: generation)
    } catch let failure as DeliveryFailure {
      return await finishFailed(identity, failure, generation: generation)
    } catch {
      let failure = ManifestFetchTask.classifyTransportError(error, sourceID: nil)
      return await finishFailed(identity, failure, generation: generation)
    }
  }

  /// The ONE terminal-failure exit: state, event, and the app.log line move
  /// together — a failure class that skips any of the three is invisible to
  /// one of its consumers (drill 12 found the preflight reject silent in
  /// app.log while the catch path logged, 2026-07-06).
  private func finishFailed(
    _ identity: ModelIdentity, _ failure: DeliveryFailure, generation: Int
  ) async -> DeliveryOutcome {
    // Terminal-winner gate, failure side (code-diff r9 P2 — twin of the
    // completed path's no-await slice, exhaustive r7 P1): a racing cancel()
    // or a superseding startAttempt() bumped the generation, so that winner
    // owns the terminal event — a stale attempt must not emit or log a
    // second one (attempt_failed + cancel for one attempt). It only reports
    // its outcome; deliberately NOT finishCancelled(), whose latch-reset
    // branch could emit a spurious cancel when a new attempt already reset
    // `cancelLatched`.
    guard entries[identity]?.generation == generation else {
      return .cancelled(resumable: hasStagedPartials(identity: identity))
    }
    setState(identity, .failed(failure), ifGeneration: generation)
    emit(
      identity,
      .attemptFailed(
        reason: failure.reason, failingSourceID: failure.failingSourceID, detail: failure.detail))
    // The local line is written by the `.attemptFailed` arm of
    // `deliveryLogLine` (#2135), from the emit two statements above. It carries
    // the failing source id as well, which this call could not.
    return .failed(failure)
  }

  /// Cancel exit: the cancel EVENT is owned by `cancel()` (first-wins latch);
  /// the attempt task only reports its outcome — never a paired
  /// attempt_failed(cancelled) (D3 sequencing invariant).
  private func finishCancelled(_ identity: ModelIdentity, generation: Int) -> DeliveryOutcome {
    let resumable = hasStagedPartials(identity: identity)
    if entries[identity]?.cancelLatched != true {
      // Cancellation arrived through task-tree cancellation without a
      // cancel() call (e.g. controller torn down): still one cancel event.
      setState(identity, .cancelled(resumable: resumable), ifGeneration: generation)
      emit(identity, .cancel(phaseAtCancel: "downloading", resumable: resumable))
    }
    return .cancelled(resumable: resumable)
  }

  // MARK: - Progress + state plumbing

  private func applyProgress(_ identity: ModelIdentity, bytes: Int64, total: Int64, generation: Int)
  {
    guard entries[identity]?.generation == generation,
      case .downloading = entries[identity]?.state
    else { return }
    // Shrink the reservation as bytes land (D4 §2): recomputed from the
    // acceptance-time baseline because `bytes` is CUMULATIVE — remaining =
    // base - landed, reserved = remaining x headroom.
    if var entry = entries[identity] {
      let landed = max(0, bytes - entry.reservationProgressBaseline)
      let remaining = max(0, entry.reservationRemainingBase - landed)
      entry.reservedBytes = Int64(Double(remaining) * entry.reservationHeadroom)
      entries[identity] = entry
    }
    setState(
      identity,
      .downloading(
        fractionCompleted: Double(bytes) / Double(total), bytesWritten: bytes, totalBytes: total),
      ifGeneration: generation)
  }

  private func tickValidating(_ identity: ModelIdentity, generation: Int) {
    guard entries[identity]?.generation == generation,
      case .preparing = entries[identity]?.state
    else { return }
    setState(identity, .preparing(validatingExistingCache: true))
  }

  /// **The local log and telemetry legitimately disagree here, and only here.**
  ///
  /// Awaiting this call orders it against the `fetchTask.run()` continuation. It
  /// does NOT order it against a concurrent `cancel()`: both enter this actor,
  /// and a cancel serviced first bumps the generation, after which the guard
  /// below discards the event (#2135 cloud review, round 2).
  ///
  /// Dropping it is CORRECT for telemetry and WRONG for the log, because the two
  /// answer different questions. **A telemetry event is a claim about an
  /// attempt**, so an event belonging to a superseded generation must not be
  /// attributed to the live one — that is exactly what the guard is for.
  /// **A log line is a record of an occurrence**, and the failover genuinely
  /// happened, before the cancel, whatever the generation did afterwards.
  /// Suppressing it makes the log lie by omission about a real event — and a
  /// missing line reads as "it did not happen", which is the direction that
  /// produces confidently wrong conclusions.
  ///
  /// So the line is written unconditionally and the EMIT stays guarded. This is
  /// the one place these two channels diverge; everywhere else the switch inside
  /// `emit` serves both. Do not "tidy" this by moving the log back below the
  /// guard, and do not fix it by relaxing the guard — the guard is right about
  /// its own question.
  private func noteFailover(
    _ identity: ModelIdentity, reason: DeliveryFailureClass, fromSourceID: String,
    toSourceID: String, generation: Int
  ) {
    let event = DeliveryEvent.sourceFailover(
      reason: reason, fromSourceID: fromSourceID, toSourceID: toSourceID)
    guard entries[identity]?.generation == generation else {
      #if DEBUG
        enqueueDeliveryLog(identity, event)
      #endif
      return
    }
    emit(identity, event)
  }

  private func setState(
    _ identity: ModelIdentity, _ state: DeliveryState, ifGeneration generation: Int
  ) {
    guard entries[identity]?.generation == generation else { return }
    setState(identity, state)
  }

  private func setState(_ identity: ModelIdentity, _ state: DeliveryState) {
    entries[identity, default: Entry()].state = state
    for observer in stateObservers { observer(identity, state) }
  }

  /// Emit `admittedWithoutFetch` at most once per identity per reason per
  /// process (#1363 §16.3). Called only from no-await slices (both no-fetch
  /// admission points), so no generation gate is needed here.
  private func emitAdmittedWithoutFetch(
    _ identity: ModelIdentity, reason: DeliveryEvent.AdmissionReason
  ) {
    let key = "\(identity.cacheKey)|\(reason.rawValue)"
    guard admittedWithoutFetchSeen.insert(key).inserted else { return }
    emit(identity, .admittedWithoutFetch(reason: reason))
  }

  private func emit(_ identity: ModelIdentity, _ event: DeliveryEvent) {
    #if DEBUG
      enqueueDeliveryLog(identity, event)
    #endif
    guard !eventObservers.isEmpty else {
      // Pre-attach buffer (drained by the first `addEventObserver`). Bounded:
      // a launch window emits a handful of events; if something pathological
      // floods before attach, keep the EARLIEST — attempt_started/failed at
      // the front are the ones the funnel cannot lose.
      if pendingEvents.count < 64 { pendingEvents.append((identity, event)) }
      return
    }
    for observer in eventObservers { observer(identity, event) }
  }

  // MARK: - Local log (#2135)

  #if DEBUG

    /// Emit order, minted on this actor. Present in every line so a reader can
    /// see a gap, and so a residual reordering is legible rather than silently
    /// wrong.
    private var deliveryLogSequence: UInt64 = 0

    /// The tail of a chain of writes. Each write awaits its predecessor, so the
    /// FILE order matches emit order. Separate unstructured `Task`s are not
    /// FIFO, and this log's whole value is that a sequence can be read top to
    /// bottom — a sequence number alone would make disorder auditable, never
    /// readable.
    ///
    /// Best-effort at process termination, stated rather than hidden:
    /// `applicationWillTerminate` is synchronous and cannot await this tail, so
    /// a rapid quit or a `kill -9` can discard unwritten lines. Guaranteeing a
    /// drain needs a wider asynchronous-termination design, which is not
    /// justified for a debug diagnostic.
    private var deliveryLogTail: Task<Void, Never>?

    /// Test seam. A recorder installed HERE observes the production enqueue
    /// path — the same rendering, the same chain, the same call site — rather
    /// than a substitute renderer, which would prove a stub instead of the
    /// production body.
    private var deliveryLogSinkForTesting: (@Sendable (String) async -> Void)?

    package func setDeliveryLogSinkForTesting(_ sink: (@Sendable (String) async -> Void)?) {
      deliveryLogSinkForTesting = sink
    }

    /// Await the write chain. Tests need this because the assertion is about
    /// what LANDED, and the chain is the thing that decides when that is true.
    package func flushDeliveryLogsForTesting() async {
      await deliveryLogTail?.value
    }

    /// Render on the actor, in emit order, then hand the finished string off.
    /// The string is therefore correct whatever the writer does.
    private func enqueueDeliveryLog(_ identity: ModelIdentity, _ event: DeliveryEvent) {
      deliveryLogSequence &+= 1
      let line = Self.deliveryLogLine(
        identity: identity, event: event, sequence: deliveryLogSequence)
      let previous = deliveryLogTail
      let sink = deliveryLogSinkForTesting
      deliveryLogTail = Task {
        await previous?.value
        if let sink {
          await sink(line)
        } else {
          await AppLogger.shared.log(line, level: .info, category: "Delivery")
        }
      }
    }

    /// The ONE place a `DeliveryEvent` becomes a local log line.
    ///
    /// A `switch` rather than a list of call sites, and that is the mechanism
    /// rather than a preference: the compiler owns exhaustiveness, so a ninth
    /// event fails to BUILD here until someone decides its line. A hand-written
    /// list is a convention, and a convention with a comment claiming it is
    /// exhaustive is how a new enum member gets silently dropped (#2207).
    ///
    /// `Model delivery admitted` and `Model delivery failed` reproduce the
    /// wording of the two ad-hoc lines this replaces, verbatim, because those
    /// are what someone greps for today.
    ///
    /// THE STRING RETURNED HERE IS NOT THE LINE A READER SEES. `AppLogger`
    /// prefixes a timestamp, a level and the CATEGORY before writing
    /// (`AppLogger.swift`, `writeRendered`), and this event's category is
    /// `Delivery` — see the `AppLogger.shared.log(... category: "Delivery")`
    /// call a few lines above. So the composed line reads:
    ///
    ///     [2026-08-25T01:14:02-0400] [INFO] [Delivery] [#1] Model delivery admitted …
    ///
    /// The sequence prefix is therefore `[#N]` and not `[delivery #N]`: the
    /// category token already says Delivery, and the longer form stuttered the
    /// word three times in two adjacent bracketed tokens (#2399). Anyone
    /// editing this prefix is editing the middle of that composed line, which
    /// nothing at this declaration would otherwise say — the unit test below
    /// pins THIS string and is downstream of the wrapper, so it cannot see the
    /// composed form at all.
    package static func deliveryLogLine(
      identity: ModelIdentity, event: DeliveryEvent, sequence: UInt64
    ) -> String {
      let prefix = "[#\(sequence)]"
      let key = identity.cacheKey
      switch event {
      case .attemptStarted(let resumed):
        return "\(prefix) Model delivery attempt started \(key): resumed=\(resumed)"
      case .attemptCompleted(
        let durationBucket, let bytesDownloadedBucket, let sourcesUsed, let finalSourceID,
        let repairedComponentsCount):
        return
          "\(prefix) Model delivery admitted \(key): duration=\(durationBucket) "
          + "bytes=\(bytesDownloadedBucket) sources=\(sourcesUsed) "
          + "final_source=\(finalSourceID) repaired=\(repairedComponentsCount)"
      case .attemptFailed(let reason, let failingSourceID, let detail):
        let detailSuffix = detail.map { " (\($0))" } ?? ""
        let sourceSuffix = failingSourceID.map { " source=\($0)" } ?? ""
        return
          "\(prefix) Model delivery failed \(key): \(reason.rawValue)\(detailSuffix)"
          + sourceSuffix
      case .sourceFailover(let reason, let fromSourceID, let toSourceID):
        return
          "\(prefix) Model delivery source failover \(key): \(fromSourceID) -> "
          + "\(toSourceID), reason=\(reason.rawValue)"
      case .validationRepair(let componentsCount, let trigger):
        return
          "\(prefix) Model delivery validation repair \(key): "
          + "components=\(componentsCount) trigger=\(trigger.rawValue)"
      case .cancel(let phaseAtCancel, let resumable):
        return
          "\(prefix) Model delivery cancelled \(key): phase=\(phaseAtCancel) "
          + "resumable=\(resumable)"
      case .flagActive(let flag, let value):
        return "\(prefix) Model delivery flag active \(key): \(flag)=\(value)"
      case .admittedWithoutFetch(let reason):
        return
          "\(prefix) Model delivery admitted \(key) without fetch: reason=\(reason.rawValue)"
      }
    }

  #endif

  // MARK: - Paths + disk

  /// Reclaim staging directories for superseded revisions of this
  /// registration's model (#2109, #2119).
  ///
  /// A partially-downloaded revision that is later superseded is otherwise
  /// never deleted: staging is keyed by `cacheKey`, a successful admission
  /// removes only its OWN directory, and nothing enumerates the rest. Up to a
  /// full model's worth of bytes per abandoned revision, permanently.
  ///
  /// NOT gated on `admission.evictPreviousRevisions`, deliberately, and the
  /// divergence from the superseded-MARKER cleanup is the point. That flag
  /// protects a legitimate choice: keeping a previous revision installed and
  /// usable. Staging is not an install — it is resume CACHE, and the marker is
  /// what makes an install real. The worst case of deleting it is refetched
  /// bytes if a later build re-pins that revision, never a broken or unusable
  /// model. Gating it would inherit the defect #2109's own comments name:
  /// three of four shipped manifests carry that flag's value copied from a
  /// sibling, so for most artefacts it encodes nobody's decision.
  ///
  /// SAME VARIANT is part of the match, not a detail. WhisperKit transcription
  /// and Live Preview deliberately SHARE this one metadata directory while
  /// keeping separate install directories, on the stated grounds that
  /// `cacheKey` includes the variant so their staging and markers cannot
  /// collide. If this match ever loosened to family+name it would delete
  /// across two models designed to coexist here, and the symptom would be a
  /// preview download losing its staging for no visible reason (framing from
  /// the session building #2123, who owns that pair).
  ///
  /// LIVENESS IS BUILT FORWARD. Identity → URL is total; URL → identity is
  /// not, because `cacheKey` flattens name and revision. So the protected set
  /// is derived from entries that actually have work in flight, mapped to
  /// their URLs through the pure path helper, and candidates are compared
  /// against it. Nothing parses a directory name back into an identity.
  ///
  /// A retained entry is NOT liveness: entries survive `clearTask`, so keying
  /// on their presence would protect long-dead revisions forever and quietly
  /// defeat the sweep. Only a non-nil `activeTask` or `drainingTask` counts.
  ///
  /// Best-effort per entry, and the whole method is suspension-free between
  /// building the protected set and deleting, so no attempt can start in the
  /// gap.
  public func sweepSupersededStaging(_ registration: DeliveryRegistration) {
    let identity = registration.manifest.identity

    // THE KILL SWITCH REFUSES THE WHOLE SWEEP, before any read or unlink.
    //
    // Every other byte-mutating path into this controller is gated by the
    // ADAPTER, which returns early while delivery is disabled
    // (`EGOneDeliveryAdapter` line ~93: "delivery is disabled (§16.6): no
    // mutation"). That is why the flag snapshot in `startAttempt` does not
    // check `familyEnabled` and its comment can say the snapshot "only runs
    // when delivery is on" — nothing reaches it otherwise.
    //
    // This method is a PUBLIC door the adapter does not stand in front of:
    // four bootstrap sites call it directly. Without this guard, launching
    // during an incident freeze deletes superseded staging — resumable
    // multi-GB partials — at the exact moment nothing is permitted to
    // re-fetch them. `WhisperKitLegacyUpgradeCoordinator` step 0 gates its
    // own deletion run for this reason and names the harm: deleting while
    // disabled strands a user with neither the old copy nor a fetchable
    // replacement.
    //
    // Gated HERE rather than at the four call sites, so a fifth caller
    // cannot reintroduce it by omission.
    //
    // This does not weaken #2109's cleanup guarantee: the key defaults to
    // TRUE, so every ordinary user still sweeps. Only an operator who has
    // deliberately frozen delivery defers cleanup, and it resumes on the
    // next launch after the switch returns.
    guard DeliveryFlags.snapshot(family: identity.family, defaults: defaults).familyEnabled
    else { return }

    let candidates = PriorRevisionAdmission.supersededStagingURLs(
      for: identity, metadataDirectory: registration.metadataDirectory)
    guard !candidates.isEmpty else { return }

    // Compare RESOLVED PATHS, never URL objects. A URL from
    // `contentsOfDirectory` and one built with `appendingPathComponent` can
    // denote the same directory and still differ as values: macOS temp roots
    // resolve `/var/...` to `/private/var/...`, and directory URLs may or may
    // not carry a trailing slash. Set membership on the raw URLs therefore
    // silently never matched, and the protection failed OPEN — the sweep
    // deleted staging for a download that was actively running. Caught by
    // `sweepNeverDeletesStagingForAnAttemptInFlight`.
    func key(_ url: URL) -> String {
      url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    var protectedKeys: Set<String> = []
    for (liveIdentity, entry) in entries where entry.activeTask != nil || entry.drainingTask != nil
    {
      guard let liveRegistration = registrationsByIdentity[liveIdentity] else { continue }
      protectedKeys.insert(key(Self.stagingDirectoryURL(for: liveRegistration)))
    }

    let fm = FileManager.default
    for candidate in candidates where !protectedKeys.contains(key(candidate)) {
      try? fm.removeItem(at: candidate)
    }
  }

  /// Whether the identity is in the LIVE DRAINING window (#2119 test support).
  ///
  /// Both halves are required. "No active task" alone is also true AFTER the
  /// drain finishes, so a test parking on it could sweep once draining had
  /// already completed and miss the very window it claims to cover — the
  /// draining branch would go unexercised while the test read green.
  func isDrainingForTesting(_ identity: ModelIdentity) -> Bool {
    guard let entry = entries[identity] else { return false }
    return entry.activeTask == nil && entry.drainingTask != nil
  }

  /// Test-only barrier awaited after `.preparing` publishes and BEFORE the
  /// existing-cache validation suspends (#2109). Never set in production.
  ///
  /// Deliberately `internal`, not `package` or `public`: the test target uses
  /// `@testable import`, so internal is reachable, and widening it would put a
  /// test hook on the delivery API that other modules could call. Matches the
  /// module's existing seam precedent (`ChunkAppendDelegate.protocolClassesForTesting`),
  /// which is likewise internal and not `#if DEBUG` — keeping it out of a DEBUG
  /// guard means the covering test compiles and runs in the Release lane too,
  /// rather than silently vanishing from it.
  var beforeExistingCacheValidationForTesting: (@Sendable () async -> Void)?

  /// Cross-actor setter for the barrier above; an actor's stored property
  /// cannot be assigned from outside its isolation.
  func setBeforeExistingCacheValidationForTesting(_ hook: (@Sendable () async -> Void)?) {
    beforeExistingCacheValidationForTesting = hook
  }

  /// Fired the instant `cancel` moves an attempt from `activeTask` to
  /// `drainingTask` (#2119 test support). Never set in production.
  ///
  /// Exists because the alternative is POLLING, and polling this particular
  /// transition starves it: every probe is a hop onto this actor, so a tight
  /// `Task.yield()` loop keeps the controller answering "are you draining yet"
  /// instead of draining. That test passed locally and timed out on post-merge
  /// main, where the runner has fewer cores — a signal removes the race rather
  /// than betting against it (test-timing.md: wait on a signal, use a deadline
  /// only as the fallback AROUND it).
  ///
  /// Synchronous and non-async on purpose: it runs inside the actor-isolated
  /// window between the move landing and `task.cancel()`, so it must not
  /// suspend and let that window close before the waiter is released.
  var afterMovedToDrainingForTesting: (@Sendable () -> Void)?

  /// Cross-actor setter; see `setBeforeExistingCacheValidationForTesting`.
  func setAfterMovedToDrainingForTesting(_ hook: (@Sendable () -> Void)?) {
    afterMovedToDrainingForTesting = hook
  }

  private func admission(for registration: DeliveryRegistration) -> CacheAdmission {
    CacheAdmission(
      manifest: registration.manifest, installDirectory: registration.installDirectory,
      metadataDirectory: registration.metadataDirectory)
  }

  private var registrationsByIdentity: [ModelIdentity: DeliveryRegistration] = [:]

  /// The staging path authority. `nonisolated` and `static` deliberately: it
  /// is a pure function of the registration and touches no actor state, which
  /// is what lets a SYNCHRONOUS caller off the actor derive the same path
  /// (#2109 — the EG-1 install-state mapper cannot await).
  ///
  /// Identity → URL is total. The reverse is NOT: `cacheKey` flattens name and
  /// revision without an injective boundary, so a URL cannot be parsed back
  /// into a `ModelIdentity`. Anything needing to know which identity owns a
  /// directory must map forward from a known identity and compare, never parse.
  nonisolated package static func stagingDirectoryURL(for registration: DeliveryRegistration) -> URL
  {
    registration.metadataDirectory
      .appendingPathComponent("staging", isDirectory: true)
      .appendingPathComponent(registration.manifest.identity.cacheKey, isDirectory: true)
  }

  private func stagingDirectory(for registration: DeliveryRegistration) -> URL {
    // No longer caches the registration: that write moved to `startAttempt`,
    // where it cannot be outrun by a cancel. Deriving a path is not a lifetime
    // concern and should never have owned one.
    Self.stagingDirectoryURL(for: registration)
  }

  private func hasStagedPartials(identity: ModelIdentity) -> Bool {
    guard let registration = registrationsByIdentity[identity] else { return false }
    return hasStagedPartials(registration)
  }

  private func phaseAtCancel(identity: ModelIdentity) -> String {
    // A cancel during REPAIR is `downloading` (repair IS a download, D6
    // state 5 / D3 r2 finding 4); verify-phase cancels report verifying.
    if case .verifying = entries[identity]?.state { return "verifying" }
    return "downloading"
  }

  private func stagedByteCount(of files: [DeliveryManifest.File], in staging: URL) -> Int64 {
    let fm = FileManager.default
    return files.reduce(Int64(0)) { sum, file in
      // Staged files live under the resolved install path (contract §4b).
      let path = staging.appendingPathComponent(file.resolvedInstallPath).path
      let size = ((try? fm.attributesOfItem(atPath: path)[.size] as? Int64) ?? nil) ?? 0
      return sum + min(size, file.sizeBytes)
    }
  }

  /// Production disk probe — same key EG-1 ships (`EGOneModelStore`), but
  /// walked to the NEAREST EXISTING ancestor: on a fresh install the install
  /// dir does not exist yet, and a nil probe treated as "unknown" would
  /// bypass the insufficient-disk preflight entirely (code-diff r1 P2).
  public static let volumeAvailableBytes: @Sendable (URL) -> Int64? = { url in
    var probe = url.standardizedFileURL
    let fm = FileManager.default
    while !fm.fileExists(atPath: probe.path) {
      let parent = probe.deletingLastPathComponent()
      guard parent.path != probe.path else { break }
      probe = parent
    }
    let values = try? probe.resourceValues(
      forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return values?.volumeAvailableCapacityForImportantUsage
  }

  // MARK: - Telemetry buckets (EG-1's shipped dials)

  static func durationBucket(since start: ContinuousClock.Instant) -> String {
    let seconds = Double((ContinuousClock.now - start).components.seconds)
    switch seconds {
    case ..<60: return "under_1m"
    case ..<300: return "1m_5m"
    case ..<1200: return "5m_20m"
    default: return "over_20m"
    }
  }

  static func bytesBucket(_ bytes: Int64) -> String {
    switch bytes {
    case ..<(50 << 20): return "under_50mb"
    case ..<(200 << 20): return "50mb_200mb"
    case ..<(600 << 20): return "200mb_600mb"
    default: return "over_600mb"
    }
  }
}
