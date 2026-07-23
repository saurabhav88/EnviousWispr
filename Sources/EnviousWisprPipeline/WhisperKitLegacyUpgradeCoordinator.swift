import EnviousWisprASR
import EnviousWisprModelDelivery
import Foundation

/// Retires the multilingual engine's foreign copy and refetches a verified one.
///
/// The copy lives in `~/Documents/huggingface/...` — a cache we do not own, populated by a
/// borrowed downloader against Hugging Face's runtime listing API. That is the #1339 exposure
/// epic #1348 exists to delete. This runs on **every launch, forever**: ~700 downloads to date
/// must still work whenever those users upgrade, so the common path has to stay free.
///
/// Mirrors `EGOneLegacyUpgradeCoordinator`'s shape and shares its mechanism via
/// `LegacyRetirement` (#1386 PR-2a). What differs is policy, and only policy: EG-1 retires one
/// flat app-owned file; this retires 24 nested files from a foreign cache another app may also
/// be writing.
///
/// **Writes no setting and touches no engine.** It deletes a folder and downloads a folder.
/// Contract: `model-delivery-contract.md` §5b. Rules L1–L9: the plan's §1.
@MainActor
public final class WhisperKitLegacyUpgradeCoordinator {

  /// Content-free and path-free: these cross the telemetry boundary.
  public enum Event: Sendable, Equatable {
    case legacyDetected
    case legacyRetired
    case legacyRetirementRefused(reason: RefusalReason)
    case legacyRetirementFailed(reason: FailureReason)
    case replacementCompleted
  }

  public enum RefusalReason: String, Sendable, Equatable {
    case mismatch
    case containment
  }

  public enum FailureReason: String, Sendable, Equatable {
    case unreadable
    case markerWrite
    case delete
  }

  public var onEvent: (@MainActor @Sendable (Event) -> Void)?

  /// #1707 Phase 3 (§3.2, row 14) / #1741 Chunk 8 — the shared
  /// `EngineMutationScope` constructed once by the composition root (this
  /// type never references `EngineRecoveryGate` by concrete type). This
  /// coordinator never moves the engine itself, but its delete+refetch window
  /// (steps 6-8 of `retireAndRefetchIfNeeded()`) mutates the SAME on-disk
  /// model files a concurrent crash-recovery replay's `activeEngine.load()`
  /// reads from — a genuine hazard the launch grounding brief found (this
  /// Task and `RecoveryCoordinator.scanAndRecover()`'s Task fire one line
  /// apart with zero ordering). Required at construction (no default) —
  /// replaces the old defaulted `tryBeginEngineMutation`/`endEngineMutation`/
  /// `wakeRecoveryIfOwed` closure triplet; the scope's own `onRefused`
  /// closure now owns refusal telemetry.
  package let engineMutationScope: EngineMutationScope

  /// L5: at most one command is current, and its KIND is load-bearing — a later ensure-intent
  /// must know whether it is joining a fetch or waiting out a Cancel.
  enum CommandKind: Sendable, Equatable {
    case ensure
    case cancel
    /// 2c: the deliberate one-field seam L5 promised — Remove drains, unloads,
    /// deletes. Distinguishable from `.cancel` so a duplicate Remove joins and
    /// a Cancel-during-Remove joins rather than preempting an accepted deletion.
    case remove
  }

  /// 2c: the outcome the Settings row renders inline.
  public enum RemoveOutcome: Sendable, Equatable {
    case removed
    /// L1 refusal: the owed marker would not clear; nothing was touched.
    case refusedMarkerClear
    /// The delivery layer refused (kill switch off) or failed the deletion.
    case failed
  }

  private let documentsDirectory: URL
  private let appSupportDirectory: URL
  private let trustedFiles: [LegacyRetirement.TrustedFile]
  private let variant: String

  private let ensureAvailable: @MainActor @Sendable () async -> Bool
  private let cancelActiveFetch: @MainActor @Sendable () async -> Void
  private let isAdmitted: @MainActor @Sendable () async -> Bool
  /// 2c: full engine unload before deletion (adapter's `unloadForRemoval`).
  /// Settable, not init-injected: the adapter is constructed AFTER this
  /// coordinator (wiring precedes the driver in the composition root), so the
  /// bootstrapper assigns it once the driver exists. nil-safe default no-ops.
  public var unloadForRemoval: @MainActor @Sendable () async -> Void = {}
  /// 2c: the delivery-layer deletion (marker + files + staging). Returns success.
  public var removeFromDelivery: @MainActor @Sendable () async -> Bool = { false }
  /// The kill switch, read at the TOP of every retirement run — not only at the
  /// fetch door. A rollback (switch off) must refuse the whole operation before
  /// the first disk mutation: retiring the legacy copy and then refusing the
  /// refetch would strand the user with neither model (Codex 2b-r1 P1).
  private let isDeliveryEnabled: @MainActor @Sendable () -> Bool

  /// Seams. Production passes nil and gets `LegacyRetirement`'s real implementations —
  /// including its inode-bound hashing, which a URL-taking closure cannot express.
  private let hashFile: (@Sendable (URL) async throws -> String)?
  private let removeItem: ((URL) throws -> Void)?

  private var command:
    (kind: CommandKind, task: Task<Void, Never>, ticket: Int, removeOutcome: RemoveOutcomeCell?)?
  private var commandTicket = 0
  private var commandGeneration = 0

  package init(
    documentsDirectory: URL = FileManager.default.urls(
      for: .documentDirectory, in: .userDomainMask)[0],
    appSupportDirectory: URL = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask)[0],
    variant: String,
    trustedFiles: [LegacyRetirement.TrustedFile],
    isAdmitted: @escaping @MainActor @Sendable () async -> Bool,
    ensureAvailable: @escaping @MainActor @Sendable () async -> Bool,
    cancelActiveFetch: @escaping @MainActor @Sendable () async -> Void,
    isDeliveryEnabled: @escaping @MainActor @Sendable () -> Bool,
    engineMutationScope: EngineMutationScope,
    hashFile: (@Sendable (URL) async throws -> String)? = nil,
    removeItem: ((URL) throws -> Void)? = nil
  ) {
    self.documentsDirectory = documentsDirectory
    self.appSupportDirectory = appSupportDirectory
    self.variant = variant
    self.trustedFiles = trustedFiles
    self.isAdmitted = isAdmitted
    self.ensureAvailable = ensureAvailable
    self.cancelActiveFetch = cancelActiveFetch
    self.isDeliveryEnabled = isDeliveryEnabled
    self.engineMutationScope = engineMutationScope
    self.hashFile = hashFile
    self.removeItem = removeItem
  }

  // MARK: - Paths

  /// The shared swift-transformers cache. Repo-id-keyed, and **not ours**: MacWhisper and
  /// Argmax's own SDK use this same path.
  private var foreignCacheRoot: URL {
    documentsDirectory.appendingPathComponent(
      "huggingface/models/argmaxinc/whisperkit-coreml", isDirectory: true)
  }

  private var foreignVariantDirectory: URL {
    foreignCacheRoot.appendingPathComponent(variant, isDirectory: true)
  }

  private var metadataDirectory: URL {
    appSupportDirectory.appendingPathComponent(
      "EnviousWispr/ModelDelivery", isDirectory: true)
  }

  /// L2. Zero-byte; its presence is the whole message.
  private var owedMarkerURL: URL {
    metadataDirectory.appendingPathComponent("whisperkit-replacement-owed")
  }

  /// L4. Not a flag — a versioned identity record of what we examined.
  private var declinedRecordURL: URL {
    metadataDirectory.appendingPathComponent("whisperkit-foreign-declined.json")
  }

  private var isReplacementOwed: Bool {
    FileManager.default.fileExists(atPath: owedMarkerURL.path)
  }

  // MARK: - Launch

  /// Every launch, forever (§2.1).
  public func runLaunch() async {
    await joinOrStart(.ensure) { [weak self] in
      await self?.retireAndRefetchIfNeeded()
    }
  }

  /// L5: ensure-intent joins the stored task; an explicit Download re-checks admission after
  /// the join and fetches only if still absent, so two fetches of one identity are impossible.
  public func download() async {
    let generation = commandGeneration
    await joinOrStart(.ensure) { [weak self] in
      await self?.retireAndRefetchIfNeeded()
    }
    // A Cancel that landed during the join bumped the generation. Falling through
    // to the admission re-check would immediately restart the multi-GB fetch the
    // user just cancelled (Codex 2b-r3 P1) — the cancelled command wins.
    guard commandGeneration == generation else { return }
    if await isAdmitted() == false {
      await joinOrStart(.ensure) { [weak self] in
        _ = await self?.ensureAvailable()
      }
    }
  }

  /// L1: clear the marker FIRST. If that fails, refuse the whole command — bumping the
  /// generation first would supersede the in-flight fetch without cancelling it, and it could
  /// still admit while its own completion is forbidden from clearing the marker.
  ///
  /// The drain is then REGISTERED as the current command (`.cancel` — the kind L5 defined
  /// for exactly this): a Download pressed mid-drain joins it instead of racing the
  /// controller cancellation, where it could join the very fetch being terminated and end
  /// with nothing started (Codex 2b-r4 P2). The slot stays occupied until the superseded
  /// work has actually unwound, so "at most one command" holds through the drain too.
  public func cancel() async throws {
    // L5: Cancel arriving during Remove JOINS it — an accepted deletion cannot
    // be undone, so preempting the Remove drain would only corrupt its slot.
    if let current = command, current.kind == .remove {
      await current.task.value
      return
    }
    try LegacyRetirement.clearMarker(owedMarkerURL)
    commandGeneration += 1
    let superseded = command?.task
    superseded?.cancel()
    commandTicket += 1
    let ticket = commandTicket
    let drain = Task { [cancelActiveFetch] in
      await cancelActiveFetch()
      if let superseded { _ = await superseded.value }
    }
    command = (kind: .cancel, task: drain, ticket: ticket, removeOutcome: nil)
    await drain.value
    if command?.ticket == ticket { command = nil }
  }

  /// 2c: the user pressed Remove (the in-flight dictation refusal happens at
  /// the CALLER — this coordinator arbitrates delivery commands, not sessions).
  /// L1 verbatim: marker clear first (refuse everything on failure), one
  /// non-suspending slice bumps the generation and cancels the stored task,
  /// then the drain awaits the controller's fetch stop, the superseded work's
  /// unwind, the engine unload, and finally the deletion. Registered as the
  /// current command (kind .remove): duplicates join; ensures wait it out.
  public func remove() async -> RemoveOutcome {
    // L5: duplicate Remove joins the one in flight and receives the DRAIN'S
    // OWN outcome — reading the world instead lies when deletion partially
    // failed (marker gone, bytes remaining reads as "removed"; Codex 2c-r1 P2).
    if let current = command, current.kind == .remove {
      let cell = current.removeOutcome
      await current.task.value
      // The cell was captured at JOIN time, so a third Remove starting after
      // the slot clears cannot swap the verdict under this joiner
      // (Codex 2c-r4 P2 — outcomes are per-drain, never shared state).
      return cell?.value ?? .failed
    }
    do {
      try LegacyRetirement.clearMarker(owedMarkerURL)
    } catch {
      return .refusedMarkerClear
    }
    commandGeneration += 1
    let superseded = command?.task
    superseded?.cancel()
    commandTicket += 1
    let ticket = commandTicket
    let cell = RemoveOutcomeCell()
    let drain = Task { [cancelActiveFetch, unloadForRemoval, removeFromDelivery] in
      await cancelActiveFetch()
      if let superseded { _ = await superseded.value }
      await unloadForRemoval()
      let ok = await removeFromDelivery()
      // MainActor-serial, set BEFORE the drain completes: this drain's OWN
      // cell, captured by every joiner at join time.
      cell.value = ok ? .removed : .failed
    }
    command = (kind: .remove, task: drain, ticket: ticket, removeOutcome: cell)
    await drain.value
    if command?.ticket == ticket { command = nil }
    return cell.value
  }

  private func joinOrStart(_ kind: CommandKind, _ work: @escaping @Sendable () async -> Void)
    async
  {
    // L5: the KIND decides what a join means. Joining the SAME kind is the work
    // itself (two ensures are one fetch) — return. Waiting out a DIFFERENT kind
    // (an ensure arriving during a Cancel drain) completes nothing of ours: free
    // the finished command's slot OURSELVES and re-evaluate (Codex 2b-r4 P2 —
    // without this, a Download pressed mid-drain silently did nothing). Clearing
    // here, ticket-guarded, cannot spin: the slot either empties (loop exits) or
    // holds a NEW command (loop legitimately waits on it). Awaiting a completed
    // task does not yield, so waiting for the owner's own cleanup would busy-spin
    // the MainActor — proven by this suite hanging before this clause existed.
    while let current = command {
      await current.task.value
      if current.kind == kind { return }
      if command?.ticket == current.ticket { command = nil }
    }
    // The trailing clear is ticket-guarded: `cancel()` nils `command` while this call is
    // still suspended on `task.value`, so a Download registered between that cancel and
    // this resume must not be wiped by the OLD command's cleanup — a wiped registration
    // would let a later press start a second concurrent run instead of joining.
    commandTicket += 1
    let ticket = commandTicket
    let task = Task { await work() }
    command = (kind: kind, task: task, ticket: ticket, removeOutcome: nil)
    await task.value
    if command?.ticket == ticket { command = nil }
  }

  // MARK: - The eight steps

  private func retireAndRefetchIfNeeded() async {
    let generation = commandGeneration
    let fm = FileManager.default

    // 0. The kill switch refuses the WHOLE run — before any read, marker write, or unlink.
    //    A marker already owed stays owed: it survives untouched for a future launch where
    //    the switch is back on. Deleting while disabled would strand a rollback user with
    //    neither the legacy copy nor a fetchable replacement.
    guard isDeliveryEnabled() else { return }

    // 1. Cheap exit. Existence checks, and — only if a declined record exists — one lstat per
    //    recorded entry to see whether it is still valid. Zero hashes either way (L4).
    let owed = isReplacementOwed
    let foreignExists = fm.fileExists(atPath: foreignVariantDirectory.path)
    if !owed {
      guard foreignExists else { return }
      if declinedRecordIsStillValid() { return }
    }

    // 2. A marker beats every foreign state — absent, exact, partial, changed, unreadable
    //    (L3). A crash mid-delete leaves a partial set that would otherwise re-read as
    //    mismatch and strand the marker forever.
    if !owed {
      // 3. Containment. A symlinked variant dir pointing outside the cache is not ours.
      guard LegacyRetirement.isContained(foreignVariantDirectory, within: foreignCacheRoot)
      else {
        emit(.legacyRetirementRefused(reason: .containment))
        writeDeclinedRecord()
        return
      }
      emit(.legacyDetected)
    }

    // 4. Fingerprint. A throw here is cancellation and nothing else (L9): every other failure
    //    is classified into a verdict.
    let verdicts: [String: LegacyRetirement.EntryVerdict]
    do {
      verdicts = try await LegacyRetirement.fingerprint(
        root: foreignVariantDirectory, files: trustedFiles, hashFile: hashFile)
    } catch {
      return
    }
    guard generation == commandGeneration else { return }

    if !owed {
      switch LegacyRetirement.rollUp(verdicts) {
      case .absent:
        // The ~465 users who never had this model. Emit NOTHING — a no-op event on every
        // launch forever is not telemetry, it is noise.
        return
      case .mismatch:
        emit(.legacyRetirementRefused(reason: .mismatch))
        writeDeclinedRecord(verdicts: verdicts)
        return
      case .unreadable:
        emit(.legacyRetirementFailed(reason: .unreadable))
        writeDeclinedRecord(verdicts: verdicts)
        return
      case .match:
        break
      }

      // 5. Marker before the first unlink — the linearization point (L2). No suspension
      //    between this succeeding and the first unlink.
      guard LegacyRetirement.writeMarkerAtomically(owedMarkerURL) else {
        emit(.legacyRetirementFailed(reason: .markerWrite))
        return
      }
    }

    // #1707 Phase 3 (§3.2, row 14): hold a mutation claim across the
    // delete+refetch window below — a concurrent crash-recovery replay's
    // `activeEngine.load()` must never read these files mid-flux. A denied
    // claim (recovery holds the engine) defers this launch's migration
    // attempt entirely; it is safe to retry on a future launch since the
    // owed marker (freshly written above at step 5, or already owed from a
    // prior launch) already exists and nothing has been deleted yet.
    _ = await engineMutationScope.withClaim(site: "whisperKitLegacyMigration") {
      // 6. Delete only what still matches the identity we captured (L3).
      let result = LegacyRetirement.unlinkUnchanged(
        root: foreignVariantDirectory, verdicts: verdicts, removeItem: removeItem)
      if result.preserved.isEmpty {
        removeEmptyManifestDirectories()
        emit(.legacyRetired)
      } else {
        // Keep the marker and fetch anyway: we owe them a model either way, and the stale bytes
        // are a disk cost, not a correctness one.
        emit(.legacyRetirementFailed(reason: .delete))
      }

      guard generation == commandGeneration else { return }

      // 7. Refetch through the verified path.
      let admitted = await ensureAvailable()
      guard generation == commandGeneration else { return }

      // 8. Clear the marker on admission. Nothing else — no engine was ever moved.
      if admitted {
        try? LegacyRetirement.clearMarker(owedMarkerURL)
        emit(.replacementCompleted)
      }
    }
  }

  // MARK: - L4: the declined record

  /// What we examined, so the record stays an accurate disk fact.
  private struct DeclinedRecord: Codable {
    struct Entry: Codable {
      let relativePath: String
      /// nil = we could not read this entry's identity at all. Explicit, because "we could not
      /// look" and "it was not there" are different facts and only one of them is permanent.
      let identity: Identity?
    }
    struct Identity: Codable, Equatable {
      let device: Int32
      let inode: UInt64
      let sizeBytes: Int64
      let modifiedAtSeconds: Int64
      let modifiedAtNanoseconds: Int64
      let changedAtSeconds: Int64
      let changedAtNanoseconds: Int64

      init(_ i: LegacyRetirement.FileIdentity) {
        device = i.device
        inode = i.inode
        sizeBytes = i.sizeBytes
        modifiedAtSeconds = i.modifiedAtSeconds
        modifiedAtNanoseconds = i.modifiedAtNanoseconds
        changedAtSeconds = i.changedAtSeconds
        changedAtNanoseconds = i.changedAtNanoseconds
      }
    }
    let version: Int
    let variant: String
    let entries: [Entry]
  }

  /// Is the declined copy unchanged since we refused it?
  ///
  /// This is what keeps a refusal cheap forever without making it a lie. A bare "declined"
  /// flag would refuse a user who repaired their copy or restored Documents access, for as
  /// long as the app exists. Comparing a fresh `lstat` sweep (24 stats, no reads, no hashing)
  /// against what we recorded costs almost nothing and stays honest.
  private func declinedRecordIsStillValid() -> Bool {
    guard let data = try? Data(contentsOf: declinedRecordURL),
      let record = try? JSONDecoder().decode(DeclinedRecord.self, from: data),
      record.version == 1, record.variant == variant
    else { return false }

    let live = LegacyRetirement.snapshotIdentities(
      root: foreignVariantDirectory, relativePaths: trustedFiles.map(\.relativePath))

    for entry in record.entries {
      let now = live[entry.relativePath].flatMap { $0 }.map(DeclinedRecord.Identity.init)
      // Newly readable counts as changed: it is new information about bytes we declined.
      if now != entry.identity { return false }
    }
    return true
  }

  private func writeDeclinedRecord(
    verdicts: [String: LegacyRetirement.EntryVerdict]? = nil
  ) {
    let live = LegacyRetirement.snapshotIdentities(
      root: foreignVariantDirectory, relativePaths: trustedFiles.map(\.relativePath))
    let record = DeclinedRecord(
      version: 1, variant: variant,
      entries: trustedFiles.map {
        DeclinedRecord.Entry(
          relativePath: $0.relativePath,
          identity: live[$0.relativePath].flatMap { $0 }.map(DeclinedRecord.Identity.init))
      })
    guard let data = try? JSONEncoder().encode(record) else { return }
    try? FileManager.default.createDirectory(
      at: metadataDirectory, withIntermediateDirectories: true)
    try? data.write(to: declinedRecordURL, options: .atomic)
  }

  // MARK: - Cleanup

  /// Innermost-out, and ONLY directories the manifest names. Never the variant root's unlisted
  /// siblings, never `argmaxinc/`, never `huggingface/` — none of those are ours to reason
  /// about, and three other variants of the founder's own live beside this one.
  private func removeEmptyManifestDirectories() {
    let fm = FileManager.default
    // Every directory PREFIX, not just each file's immediate parent: `a/b/c.bin` owns both
    // `a/b` and `a`, and leaving the grandparent behind keeps the variant root non-empty, so
    // the whole retirement reads as half-done.
    var directories = Set<String>()
    for file in trustedFiles {
      let components = file.relativePath.split(separator: "/").dropLast()
      for depth in 1...max(components.count, 1) where !components.isEmpty {
        directories.insert(components.prefix(depth).joined(separator: "/"))
      }
    }
    for directory in directories.sorted(by: { $0.count > $1.count }) {
      let url = foreignVariantDirectory.appendingPathComponent(directory)
      if let contents = try? fm.contentsOfDirectory(atPath: url.path), contents.isEmpty {
        try? fm.removeItem(at: url)
      }
    }
    if let contents = try? fm.contentsOfDirectory(atPath: foreignVariantDirectory.path),
      contents.isEmpty
    {
      try? fm.removeItem(at: foreignVariantDirectory)
    }
  }

  private func emit(_ event: Event) {
    onEvent?(event)
  }
}

/// Per-drain removal verdict (MainActor-confined). Bound to its command so a
/// joiner can never read a different removal's outcome.
@MainActor final class RemoveOutcomeCell {
  var value: WhisperKitLegacyUpgradeCoordinator.RemoveOutcome = .failed
}
