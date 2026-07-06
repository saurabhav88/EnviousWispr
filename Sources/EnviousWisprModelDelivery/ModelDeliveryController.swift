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

  private struct Entry {
    var state: DeliveryState = .notReady
    var activeTask: Task<DeliveryOutcome, Never>?
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

  public func addStateObserver(
    _ observer: @escaping @Sendable (ModelIdentity, DeliveryState) -> Void
  ) {
    stateObservers.append(observer)
  }

  public func addEventObserver(
    _ observer: @escaping @Sendable (ModelIdentity, DeliveryEvent) -> Void
  ) {
    eventObservers.append(observer)
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
    let identity = registration.manifest.identity
    if let active = entries[identity, default: Entry()].activeTask {
      return await active.value
    }
    return await startAttempt(registration, trigger: nil)
  }

  /// The load-miss repair path (grounded r1 revision 7): identical pipeline
  /// with forced revalidation semantics; emits `validation_repair` with
  /// trigger `load_miss` when components were repaired.
  public func repair(_ registration: DeliveryRegistration) async -> DeliveryOutcome {
    let identity = registration.manifest.identity
    if let active = entries[identity, default: Entry()].activeTask {
      return await active.value
    }
    return await startAttempt(registration, trigger: .loadMiss)
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
    _ = await task.value
    let resumable = hasStagedPartials(identity: identity)
    setState(identity, .cancelled(resumable: resumable))
    emit(identity, .cancel(phaseAtCancel: phaseAtCancel(identity: identity), resumable: resumable))
    return .cancelled(resumable: resumable)
  }

  // MARK: - Attempt lifecycle

  private func startAttempt(
    _ registration: DeliveryRegistration, trigger: DeliveryEvent.ValidationTrigger?
  ) async -> DeliveryOutcome {
    let identity = registration.manifest.identity
    var entry = entries[identity, default: Entry()]
    entry.generation += 1
    entry.cancelLatched = false
    let generation = entry.generation
    let drain = entry.drainingTask
    entry.drainingTask = nil
    entries[identity] = entry

    let task = Task<DeliveryOutcome, Never> { [weak self] in
      if let drain { _ = await drain.value }
      guard let self else { return .failed(DeliveryFailure(reason: .unknown, detail: "gone")) }
      return await self.runAttempt(registration, generation: generation, trigger: trigger)
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
    trigger: DeliveryEvent.ValidationTrigger?
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

    // Marker fast path: admitted and not forced → done, silently (D7 row 11).
    if !forceRevalidate, admission.isAdmitted() {
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
        setState(identity, .failed(failure), ifGeneration: generation)
        emit(
          identity,
          .attemptFailed(reason: failure.reason, failingSourceID: nil, detail: failure.detail))
        return .failed(failure)
      }
      setState(identity, .admitted, ifGeneration: generation)
      return .admitted
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
      setState(identity, .failed(failure), ifGeneration: generation)
      emit(
        identity,
        .attemptFailed(reason: failure.reason, failingSourceID: nil, detail: failure.detail))
      return .failed(failure)
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
      try Task.checkCancellation()
      setState(identity, .verifying, ifGeneration: generation)
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
      setState(identity, .admitted, ifGeneration: generation)
      try? FileManager.default.removeItem(at: staging)
      await AppLogger.shared.log(
        "Model delivery admitted \(identity.cacheKey)", level: .info, category: "Delivery")
      return .admitted
    } catch let failure as DeliveryFailure where failure.reason == .cancelled {
      return finishCancelled(identity, generation: generation)
    } catch is CancellationError {
      return finishCancelled(identity, generation: generation)
    } catch let failure as DeliveryFailure {
      setState(identity, .failed(failure), ifGeneration: generation)
      emit(
        identity,
        .attemptFailed(
          reason: failure.reason, failingSourceID: failure.failingSourceID, detail: failure.detail))
      await AppLogger.shared.log(
        "Model delivery failed \(identity.cacheKey): \(failure.reason.rawValue)",
        level: .info, category: "Delivery")
      return .failed(failure)
    } catch {
      let failure = ManifestFetchTask.classifyTransportError(error, sourceID: nil)
      setState(identity, .failed(failure), ifGeneration: generation)
      emit(
        identity,
        .attemptFailed(
          reason: failure.reason, failingSourceID: failure.failingSourceID, detail: failure.detail))
      return .failed(failure)
    }
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

  private func emit(_ identity: ModelIdentity, _ event: DeliveryEvent) {
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
      let path = staging.appendingPathComponent(file.path).path
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
