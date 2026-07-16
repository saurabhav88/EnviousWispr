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
      let byID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
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
  public func ensureModelAvailable(_ registration: DeliveryRegistration) async -> DeliveryOutcome {
    await joinOrStartFetch(registration, trigger: nil)
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
    _ registration: DeliveryRegistration, trigger: DeliveryEvent.ValidationTrigger?
  ) async -> DeliveryOutcome {
    let identity = registration.manifest.identity
    if let active = entries[identity, default: Entry()].activeTask,
      entries[identity]?.activeTaskFetches == true
    {
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

  /// #1386 PR-2: import an already-downloaded model directory from a foreign,
  /// user-managed location (WhisperKit's `~/Documents/huggingface/...`) into
  /// this registration's OWNED cache. The one safe single-writer path for
  /// relocating a byte-match copy WITHOUT a second delivery lifecycle: copy the
  /// candidate into controller-owned staging on the install volume, verify every
  /// manifest file ONCE, then atomically promote + admit through the same
  /// `CacheAdmission` the fetch path uses. It NEVER deletes the source — the
  /// caller (the WhisperKit relocation coordinator) owns foreign-source cleanup
  /// AFTER admission. Rejects non-regular files, symlink components, iCloud
  /// dataless stubs, and a staging/install volume mismatch (typed refusal)
  /// BEFORE hashing. Joins an in-flight FETCH that is already admitting the same
  /// identity; supersedes a no-fetch probe via the proven cancel/drain path.
  public func importLocalCandidate(
    _ registration: DeliveryRegistration, from candidateDirectory: URL
  ) async -> DeliveryOutcome {
    let identity = registration.manifest.identity
    if let active = entries[identity, default: Entry()].activeTask,
      entries[identity]?.activeTaskFetches == true
    {
      return await active.value
    }
    if let probe = entries[identity]?.activeTask {
      entries[identity]?.drainingTask = probe
      entries[identity]?.activeTask = nil
      probe.cancel()
    }
    return await startImport(registration, from: candidateDirectory)
  }

  private func startImport(
    _ registration: DeliveryRegistration, from candidateDirectory: URL
  ) async -> DeliveryOutcome {
    let identity = registration.manifest.identity
    var entry = entries[identity, default: Entry()]
    entry.generation += 1
    entry.cancelLatched = false
    // Import WRITES + admits like a fetch, so a joiner must not treat it as a
    // no-fetch probe (a Download joining an import legitimately admits it).
    entry.activeTaskFetches = true
    let generation = entry.generation
    let drain = entry.drainingTask
    entry.drainingTask = nil
    entries[identity] = entry

    let task = Task<DeliveryOutcome, Never> { [weak self] in
      if let drain { _ = await drain.value }
      guard let self else { return .failed(DeliveryFailure(reason: .unknown, detail: "gone")) }
      return await self.runImport(registration, from: candidateDirectory, generation: generation)
    }
    entries[identity]?.activeTask = task
    let outcome = await task.value
    clearTask(identity: identity, generation: generation)
    return outcome
  }

  private func runImport(
    _ registration: DeliveryRegistration, from candidateDirectory: URL, generation: Int
  ) async -> DeliveryOutcome {
    let identity = registration.manifest.identity
    let manifest = registration.manifest
    // Post-drain staleness stop (a superseded import must not touch disk).
    guard entries[identity]?.generation == generation else {
      return .failed(DeliveryFailure(reason: .cancelled))
    }
    let admission = admission(for: registration)
    let staging = stagingDirectory(for: registration)

    // Same-volume guarantee for the atomic promote (r2 Finding 2): staging and
    // the install dir MUST share a volume or promote's rename is non-atomic.
    guard Self.sameVolume(staging, registration.installDirectory) else {
      let failure = DeliveryFailure(reason: .cacheRepairFailed, detail: "import_volume_mismatch")
      return await finishFailed(identity, failure, generation: generation)
    }

    // Fresh staging (discard any stale partial from a prior attempt).
    try? FileManager.default.removeItem(at: staging)

    // Copy the manifest's files candidate → staging, path-safe: reject symlink
    // components, non-regular files, and iCloud-dataless stubs BEFORE any bytes
    // are hashed (r2 Finding 1/2 — path safety lives in the primitive, never a
    // second walker in the coordinator).
    do {
      // Task.detached: a multi-GB directory copy is blocking file IO that must
      // NOT hold the controller actor (progress/UI reads) — the same off-actor
      // rule the hash pass follows (`streamingSHA256`). `Task`/`withTaskGroup`
      // inherit the actor; `@concurrent` needs the enclosing fn nonisolated —
      // detached utility is the house shape (EG-1 precedent).
      try await Task.detached(priority: .utility) {
        try Self.copyCandidate(manifest: manifest, from: candidateDirectory, to: staging)
      }.value
    } catch let failure as DeliveryFailure {
      return await finishFailed(identity, failure, generation: generation)
    } catch {
      return await finishFailed(
        identity, DeliveryFailure(reason: .cacheRepairFailed, detail: "import_copy"),
        generation: generation)
    }

    // Post-copy staleness stop (copy suspends): a superseding cancel/import must
    // not proceed to verify + promote.
    guard entries[identity]?.generation == generation, !Task.isCancelled else {
      return finishCancelled(identity, generation: generation)
    }

    // Verify the staged copy against the manifest — ONE hash pass. Re-check
    // generation + cancellation after each suspending hash.
    for file in manifest.files {
      let staged = staging.appendingPathComponent(file.resolvedInstallPath)
      guard CacheAdmission.sizeMatches(url: staged, expected: file.sizeBytes),
        await CacheAdmission.streamingSHA256(of: staged) == file.sha256
      else {
        let failure = DeliveryFailure(
          reason: .cacheRepairFailed, detail: "import_verify:\(file.component)")
        return await finishFailed(identity, failure, generation: generation)
      }
      guard entries[identity]?.generation == generation, !Task.isCancelled else {
        return finishCancelled(identity, generation: generation)
      }
    }

    // Terminal slice: from here through `.admitted` there is NO await, so a
    // racing cancel either bumped the generation BEFORE this gate (cancel wins;
    // no promote) or runs AFTER the synchronous promote (completion won). One
    // terminal per attempt (exhaustive r7 P1, mirrored from runAttempt).
    guard entries[identity]?.generation == generation, !Task.isCancelled else {
      return finishCancelled(identity, generation: generation)
    }
    do {
      try admission.promoteAndAdmit(
        stagedComponents: Set(manifest.filesByComponent.map(\.component)),
        stagingDirectory: staging, untouchedComponents: [])
    } catch let failure as DeliveryFailure {
      return await finishFailed(identity, failure, generation: generation)
    } catch {
      return await finishFailed(
        identity, DeliveryFailure(reason: .cacheRepairFailed, detail: "import_admit"),
        generation: generation)
    }
    // Local adoption without a network fetch (the #1363 adopt signal): distinct
    // from `attemptCompleted`; emit BEFORE `.admitted` so a first-run migration
    // is captured with first_run=true (grounded r3 P2).
    emitAdmittedWithoutFetch(identity, reason: .adoptedInPlace)
    setState(identity, .admitted, ifGeneration: generation)
    try? FileManager.default.removeItem(at: staging)
    await AppLogger.shared.log(
      "Model delivery imported \(identity.cacheKey)", level: .info, category: "Delivery")
    return .admitted
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
    task.cancel()
    // Drain barrier: the attempt task finishes only after its URLSession
    // delegate delivered terminal completion and file handles closed —
    // signal-based, no timer (EG-1 #1287).
    let outcome = await task.value
    // The generation bump above orphaned the attempt's own clearTask, so
    // release the ledger here — a cancelled download must not keep blocking
    // other identities' disk preflight (code-diff r5 P2).
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
      onSourceFailover: { reason in
        Task { await controller.noteFailover(identity, reason: reason, generation: generation) }
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
      await AppLogger.shared.log(
        "Model delivery admitted \(identity.cacheKey)", level: .info, category: "Delivery")
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
    let detailSuffix = failure.detail.map { " (\($0))" } ?? ""
    await AppLogger.shared.log(
      "Model delivery failed \(identity.cacheKey): \(failure.reason.rawValue)\(detailSuffix)",
      level: .info, category: "Delivery")
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

  private func noteFailover(
    _ identity: ModelIdentity, reason: DeliveryFailureClass, generation: Int
  ) {
    guard entries[identity]?.generation == generation else { return }
    emit(identity, .sourceFailover(reason: reason))
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

  // MARK: - Paths + disk

  private func admission(for registration: DeliveryRegistration) -> CacheAdmission {
    CacheAdmission(
      manifest: registration.manifest, installDirectory: registration.installDirectory,
      metadataDirectory: registration.metadataDirectory)
  }

  private var registrationsByIdentity: [ModelIdentity: DeliveryRegistration] = [:]

  private func stagingDirectory(for registration: DeliveryRegistration) -> URL {
    registrationsByIdentity[registration.manifest.identity] = registration
    return registration.metadataDirectory
      .appendingPathComponent("staging", isDirectory: true)
      .appendingPathComponent(registration.manifest.identity.cacheKey, isDirectory: true)
  }

  private func hasStagedPartials(identity: ModelIdentity) -> Bool {
    guard let registration = registrationsByIdentity[identity] else { return false }
    let staging = registration.metadataDirectory
      .appendingPathComponent("staging", isDirectory: true)
      .appendingPathComponent(identity.cacheKey, isDirectory: true)
    let entries = (try? FileManager.default.subpathsOfDirectory(atPath: staging.path)) ?? []
    return entries.contains { !$0.hasSuffix(".resume.json") }
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

  // MARK: - Local-candidate import helpers (#1386 PR-2)

  /// Two locations resolve to the same mounted volume — the guarantee that lets
  /// `promoteAndAdmit`'s staged→install move stay an atomic rename. Walks each to
  /// its nearest EXISTING ancestor (staging/install may not exist yet on a fresh
  /// install).
  static func sameVolume(_ a: URL, _ b: URL) -> Bool {
    guard let va = nearestVolumeID(of: a), let vb = nearestVolumeID(of: b) else { return false }
    return va.isEqual(vb)
  }

  private static func nearestVolumeID(of url: URL)
    -> (NSCopying & NSSecureCoding & NSObjectProtocol)?
  {
    var probe = url.standardizedFileURL
    let fm = FileManager.default
    while !fm.fileExists(atPath: probe.path) {
      let parent = probe.deletingLastPathComponent()
      guard parent.path != probe.path else { break }
      probe = parent
    }
    return (try? probe.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier
  }

  /// Copy each manifest file from `candidate/<resolvedInstallPath>` into
  /// `staging/<resolvedInstallPath>`, refusing (typed `DeliveryFailure`) any
  /// symlink component, non-regular file, iCloud-dataless stub, missing file, or
  /// path escaping the candidate root BEFORE copying. This primitive is the
  /// SINGLE path-safety authority for a foreign candidate (r2 Finding 1/2) — the
  /// relocation coordinator maps these refusals into policy and never walks the
  /// tree itself.
  static func copyCandidate(manifest: DeliveryManifest, from candidate: URL, to staging: URL) throws
  {
    let fm = FileManager.default
    let resolvedRoot = candidate.resolvingSymlinksInPath().standardizedFileURL
    for file in manifest.files {
      let relative = file.resolvedInstallPath
      // Reject a symlink at ANY component of the relative path (escape guard),
      // resolving-then-comparing, not comparing-then-resolving.
      var walk = candidate
      for component in relative.split(separator: "/") {
        walk.appendPathComponent(String(component))
        if (try? walk.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
          throw DeliveryFailure(reason: .cacheRepairFailed, detail: "import_symlink")
        }
      }
      let src = candidate.appendingPathComponent(relative)
      guard
        let vals = try? src.resourceValues(forKeys: [
          .isRegularFileKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        ])
      else {
        throw DeliveryFailure(reason: .cacheRepairFailed, detail: "import_missing")
      }
      guard vals.isRegularFile == true else {
        throw DeliveryFailure(reason: .cacheRepairFailed, detail: "import_not_regular")
      }
      if vals.isUbiquitousItem == true, vals.ubiquitousItemDownloadingStatus != .current {
        throw DeliveryFailure(reason: .cacheRepairFailed, detail: "import_dataless")
      }
      let resolvedSrc = src.resolvingSymlinksInPath().standardizedFileURL
      guard resolvedSrc.path.hasPrefix(resolvedRoot.path + "/") else {
        throw DeliveryFailure(reason: .cacheRepairFailed, detail: "import_escape")
      }
      let dst = staging.appendingPathComponent(relative)
      try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
      try fm.copyItem(at: src, to: dst)
    }
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
