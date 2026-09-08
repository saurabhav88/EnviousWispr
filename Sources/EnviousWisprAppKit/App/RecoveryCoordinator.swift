import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import EnviousWisprStorage
import Foundation

/// Host-side owner of the crash-recovery limb (#1063).
///
/// Responsibilities:
/// - **Arm** a recording: mint a durable per-recording id, generate + DURABLY
///   store the per-session key, snapshot record-time settings, and produce the
///   opaque directive the in-process capture manager writes the encrypted spool from.
/// - **Sole spool/key destructor (#1464):** every delete goes through the private
///   `destroySpoolAndKey` helper. The replayer no longer deletes; the driver no
///   longer classifies. Two exhaustive predicates decide delete-versus-retain —
///   `shouldDeleteOnLiveEnding` (a live recording that ended without a durable
///   save) and `shouldDeleteAfterReplay` (a launch replay attempt).
/// - **Clean up on success:** once a recording's transcript is durably saved,
///   delete that session's spool file + key.
/// - **Clean up on a non-saved ending:** apply `shouldDeleteOnLiveEnding` to the
///   narrow `RecordingRecoveryEnding` — under the #1755 discard doctrine EVERY
///   concluded live ending requests best-effort deletion (the user witnessed
///   the failure and re-dictates). Launch replay serves only the no-ending
///   app-gone orphan and the History-save self-heal case.
/// - **Scan + recover on launch (PR2):** find orphan spools, dedup any already
///   in History, then — behind a blocking "recovering your last recording" pill
///   that holds new recordings off the one shared engine — replay each orphan
///   (decrypt → transcribe → polish → save a non-auto-pasting "Recovered" entry).
///
/// It is a strict LIMB: every path fails open and never touches the heart path.
/// Bootstrapper-owned, a sibling of `DiagnosticsCoordinator`. Not `@Observable`:
/// `isRecovering` is read on demand by the recording gate (an imperative closure
/// read at press time), not reactively observed by any view.
@MainActor
final class RecoveryCoordinator {
  private let keyStore: RecoveryKeyStore
  /// Factory for a `RecoverySpoolStore` — constructing one prepares the spool
  /// directory (0700, Spotlight/backup-excluded), so we make a fresh value at
  /// each use rather than hold one. Injectable for tests.
  private let makeSpoolStore: @Sendable () -> RecoverySpoolStore
  /// Per-orphan replay (decrypt → transcribe → polish → save). Behind a protocol
  /// so tests drive scan/gate/generation logic against a double.
  private let replayer: any RecoverySpoolReplaying
  /// The set of `recoverySessionID`s already saved to History — read once per scan
  /// to dedup a spool whose transcript landed in a prior run's save→delete crash
  /// window (delete it WITHOUT re-transcribing). Injectable for tests.
  private let existingRecoveryIDs: @MainActor () async -> Set<String>
  /// Whether a live dictation is in flight — the recovery-independent contention
  /// guard (a recording can arm in the launch window even with recovery OFF, so
  /// `pendingSessions` protection alone wouldn't catch it — recovery is OFF
  /// means no directive, no protection entry, at all). Recovery never runs the
  /// shared engine while this is true; it defers to a future launch.
  private let isDictationActive: @MainActor () -> Bool

  /// #1807 (§C) — per-session protection, replacing the single-slot
  /// `armedSessionID: String?` this used to be. Keyed by recovery session id.
  /// ONLY covers LIVE-ARMED sessions from THIS launch (`makeDirective`
  /// inserts, the four live `handle*` entry points retire) — a scan-discovered
  /// orphan from a PRIOR process's crash never has an entry here, because no
  /// writer in this process will ever touch it (§3c: `historyDedup`,
  /// `replayOutcome`, and `userDiscard` call `destroySpoolAndKey` directly,
  /// unchanged, exactly as before this chunk).
  ///
  /// A session stays protected (excluded from the scan's `recoverable` list
  /// and the key-only sweep) not just until its final disposition is known,
  /// but until its writer ALSO confirms it can never write to the spool again
  /// AND the resulting cleanup operation (a destroy, or a plain retain) has
  /// actually SETTLED — not merely been dispatched. A genuinely unfinished
  /// writer stays protected; that is an intentional pending state, not a leak.
  /// MainActor-confined, exactly like the slot it replaces.
  ///
  /// `internal`, not `private`: `Disposition.retain` must be nameable from
  /// `requestDisposal`'s test-facing call site (see that function's doc).
  struct PendingSession {
    enum Disposition {
      case destroy(DestructionSource)
      case retain
    }
    /// nil until a `handle*` call installs it via `requestDisposal`. Refines
    /// the plan's `finalDispositionKnown` boolean into an enum carrying the
    /// actual action, per Codex plan-review round 2: "a Boolean and an
    /// arbitrary callback are not the complete contract."
    var disposition: Disposition?
    /// Set by `acknowledgeWriterQuiescent`. Proof only that the writer (if one
    /// ever existed) will never touch this spool again — NEVER proof it wrote
    /// successfully (§2.5-4; the completion closure fires on error paths too).
    var writerCanNeverWriteAgain = false
    /// True once this coordinator has claimed the session's one cleanup
    /// operation — guards a duplicate disposition call or a duplicate writer
    /// ack from starting a second marker write or deletion.
    var cleanupClaimed = false
    /// Reports proven durable discard evidence, including an earlier commit
    /// reused by a later cleanup attempt.
    var markerPersistence: Task<Bool, Never>?
    /// Every caller awaiting this session's cleanup SETTLING, not merely being
    /// claimed. Production discards the `Task` it gets back; tests await it
    /// instead of a fixed delay (§11's test contract). Resolved exactly once,
    /// inside `retireSettledSession`.
    var settlementContinuations: [CheckedContinuation<Void, Never>] = []
  }
  private var pendingSessions: [String: PendingSession] = [:]
  private var discardOperations: [String: Task<Void, Never>] = [:]
  // Proven commits remain authoritative across retries until evidence removal begins.
  private var durableDiscardEvidenceIDs: Set<String> = []

  // Instance-scoped completion seam for disposal integration tests.
  func awaitDiscardOperationsForTesting() async {
    let operations = Array(discardOperations.values)
    for operation in operations { await operation.value }
  }
  // Instance-scoped completion seam; production never awaits the sweep.
  // periphery:ignore - test seam
  var markerSweepForTesting: Task<Void, Never>?

  private var protectedSessionIDs: Set<String> {
    Set(pendingSessions.keys).union(discardOperations.keys)
  }

  private func claimDiscardOperation(
    id: String, work: @escaping @MainActor () async -> Void
  ) -> Task<Void, Never> {
    if let existing = discardOperations[id] { return existing }
    let task = Task { @MainActor [self] in
      await work()
      discardOperations.removeValue(forKey: id)
    }
    discardOperations[id] = task
    return task
  }

  /// True while an orphan is being actively replayed on the shared engine.
  /// DRIVES the recording gate: a record-press while true mints no session (shows
  /// the "recovering" pill). `private(set)` — only the scan/discard own it, and a
  /// per-item `defer` guarantees it clears on EVERY item exit (a stuck `true`
  /// would brick recording). Read by the gate via an injected closure.
  ///
  /// #1707 Phase 3 (§3.1): PER-ITEM, not scan-wide — a multi-item scan sets/
  /// clears this once per orphan (immediately before/after that orphan's
  /// replay), not once for the whole scan. This is what lets a live record-press
  /// preempt recovery between items instead of waiting for an entire multi-item
  /// scan (RULE: live-dictation-preempts-recovery-between-items). Any new
  /// engine-mutating call site must observe the SAME two claims this phase
  /// closes — `isEngineSwitching()` (unchanged, full-duration) and
  /// `EngineRecoveryGate`'s begin/end mutation pair (§3.2) — not merely read
  /// this flag; copy an EXISTING guarded call site (e.g. `EngineCoordinator
  /// .startWarm()`) rather than inventing a new pattern.
  private(set) var isRecovering = false

  /// #1171 — fired after EACH item's per-item claim releases (§3.1 moved
  /// `isRecovering` from scan-wide to per-item, so a switch deferred while ONE
  /// item held the engine can now retry as soon as THAT item releases, not only
  /// after the whole multi-item scan). Lets the composition root poke
  /// `EngineCoordinator` so a deferred switch applies now. Set by the root.
  var onRecoveryComplete: (() -> Void)?

  /// #1464 — fired after each `.recovered` replay result (a leftover recording
  /// landed in History). The composition root binds it to the standalone
  /// recovery-success overlay notice. Set by the root; nil in tests that don't
  /// exercise the notice.
  var onRecoverySucceeded: (() -> Void)?

  /// #1171 — whether an engine switch is in flight. The composition root binds
  /// this to `EngineCoordinator.isSwitching` (setter injection, like
  /// `onRecoveryComplete`, so the not-yet-built coordinator wires in after this
  /// home). The contention guard reads it so a recovery scan never starts on top
  /// of an in-flight switch (the symmetric direction: the coordinator defers a
  /// switch while recovery is active). Default no-switch keeps tests unchanged.
  var isEngineSwitching: () -> Bool = { false }

  /// #1707 Phase 3 (§3.2), required capability (#1741) — wraps
  /// `EngineRecoveryGate.tryBeginRecovery()`/`endRecovery()`, constructed by
  /// the composition root exactly like before (this type never references
  /// `EngineRecoveryGate` by concrete type, matching the existing
  /// closure-injection convention). `RecoveryCoordinator` is the SOLE owner
  /// of these calls — `RecoverySpoolReplayer` runs entirely underneath the
  /// already-held claim and never calls them itself. Required at
  /// construction, no default — a test that wants always-able-to-claim opts
  /// in explicitly via `.alwaysAllowedForTesting`.
  private let recoveryEngineClaim: RecoveryEngineClaim

  /// #1707 Phase 3 (§3.1) — set by `RecordingStarter`'s refusal path when a
  /// live record-press was refused because recovery held the engine. Checked
  /// before each item's handshake so a multi-item scan yields the engine
  /// BETWEEN items, not only at the very end. Cleared at the top of every fresh
  /// scan pass (a stale signal from a prior pass must not spuriously yield a new
  /// one that has nothing to do with it).
  var pendingLiveStartSignal = false

  /// #1707 Phase 3 (§3.4) — single-flight scan-in-progress guard, now shared by
  /// both the launch-time `scanAndRecover()` entry point and every later
  /// `requestRecoveryRecheck()` wake-up, coalesced through one owning drain
  /// loop (`drainPendingRescan()`) rather than a recursive re-invocation.
  private var scanInProgress = false
  /// Set by any wake-up trigger arriving while a pass is already running (or by
  /// a rejected concurrent `scanAndRecover()`/`requestRecoveryRecheck()` call);
  /// the owning drain loop clears it immediately before each pass, so a trigger
  /// arriving mid-pass causes exactly one later pass, never zero and never two.
  private var pendingRescan = false
  /// #1762 — debug-log only: which entry point opened the current drain loop, so
  /// each pass can name its trigger. Never read for control flow.
  private var recoveryScanTrigger = "launch"

  /// IDs excluded from SAME-LAUNCH rescans, cleared only by a genuine new
  /// launch (a fresh coordinator). Two populations remain (#1755 narrowed it
  /// from three — concluded live endings now delete instead of retaining):
  /// 1. Replay continuation cases — `.failed(.save)` / marker-clear failures /
  ///    `.deferredMarkerClearFailed` — retained for a FUTURE launch, never
  ///    re-attempted by this one.
  /// 2. A live `.completed` whose History save failed (self-heal next launch).
  private var nextLaunchOnlyRecoveryIDs: Set<String> = []

  /// Monotonic token bumped by `discardActiveRecovery()`. The replayer captures
  /// it per orphan and re-checks after every `await`: a mismatch means "discarded
  /// while my uncancellable batch transcribe was in flight" → drop the result,
  /// save nothing. The concrete mechanism behind Discard (batch transcribe has no
  /// cancel API). MainActor-confined.
  private var recoveryGeneration = 0

  /// The orphan id currently being replayed, so Discard can delete exactly the
  /// recording the user is waiting on. nil when the scan is between orphans.
  private var activeRecoveryID: String?

  /// Hard-reset the shared engine (the #445 service-kill: kills any in-flight
  /// load/transcribe and marks the engine for reinit). Lets Discard return the
  /// uncancellable in-flight replay promptly and hand the user a clean engine —
  /// so Discard is a reliable escape even if the engine wedged. Bound to
  /// `ASRManagerInterface.cancelInFlightLoad`.
  private let resetEngine: @MainActor () -> Void

  init(
    keyStore: RecoveryKeyStore = RecoveryKeyStore(),
    makeSpoolStore: @escaping @Sendable () -> RecoverySpoolStore = { RecoverySpoolStore() },
    replayer: any RecoverySpoolReplaying,
    existingRecoveryIDs: @escaping @MainActor () async -> Set<String>,
    isDictationActive: @escaping @MainActor () -> Bool,
    recoveryEngineClaim: RecoveryEngineClaim,
    resetEngine: @escaping @MainActor () -> Void = {}
  ) {
    self.keyStore = keyStore
    self.makeSpoolStore = makeSpoolStore
    self.replayer = replayer
    self.existingRecoveryIDs = existingRecoveryIDs
    self.isDictationActive = isDictationActive
    self.recoveryEngineClaim = recoveryEngineClaim
    self.resetEngine = resetEngine
  }

  enum RecoveryArmError: Error { case keyStoreFailed }

  /// Build the recovery directive for a recording about to start, or nil when
  /// recovery is off / could not arm (capture is byte-identical either way).
  ///
  /// The per-session key is stored DURABLY (awaited off the MainActor) BEFORE an
  /// enabled payload is returned, so a crash in the first moments can never leave
  /// an encrypted spool with no recoverable key. The await suspends the
  /// MainActor; it never blocks it (`keychain-not-mainactor`).
  ///
  /// - Parameters:
  ///   - settings: live settings (read on the MainActor).
  ///   - backendType: the active ASR engine (snapshot metadata, never a branch).
  ///   - supportsLanguageDetection: the active engine's CAPABILITY, read host-side
  ///     from `KernelDictationDriver.supportsLanguageDetection`
  ///     (`gate-on-capability-not-identity-literal`).
  func makeDirective(
    settings: SettingsManager,
    backendType: ASRBackendType,
    supportsLanguageDetection: Bool
  ) async -> (recoverySessionID: String, payload: Data)? {
    guard settings.crashRecoveryEnabled else { return nil }

    let recoverySessionID = UUID().uuidString
    let keyData = RecoveryKeyStore.makeKey()

    // #1173: single source of truth for the effective model.
    let resolvedModel = settings.effectiveLLMModel
    let snapshot = RecordingSettingsSnapshot(
      backendType: backendType,
      backendSupportsLanguageDetection: supportsLanguageDetection,
      languageMode: settings.languageMode,
      wordCorrectionEnabled: settings.wordCorrectionEnabled,
      fillerRemovalEnabled: settings.fillerRemovalEnabled,
      emojiFormatterEnabled: settings.emojiFormatterEnabled,
      spokenPunctuationEnabled: settings.spokenPunctuationEnabled,
      llmProvider: settings.llmProvider.rawValue,
      llmModel: resolvedModel,
      s1Control: settings.s1Control)

    // Constructing the store prepares the spool directory before the helper
    // opens the file at this path. Cheap local FS (not securityd IPC).
    let spoolPath = makeSpoolStore().spoolURL(for: recoverySessionID).path

    let directive = RecoverySpoolDirective(
      enabled: true,
      recoverySessionID: recoverySessionID,
      spoolPath: spoolPath,
      keyData: keyData,
      settingsSnapshot: snapshot)

    guard let payload = try? JSONEncoder().encode(directive) else { return nil }

    // Protect this id from the launch scan BEFORE the key can land on disk.
    // Ordering invariant: the `pendingSessions` entry is inserted
    // (synchronously, on the MainActor) no later than the key hits disk. The
    // scan reads pending membership AFTER snapshotting the on-disk spools, so
    // any spool it could have snapshotted was armed before this assignment and
    // is therefore already protected — closing the mid-arm gap (Codex
    // code-diff r4 P2). Removed below if the durable store fails — no writer
    // will ever exist for this id, so there is nothing left to protect or
    // join against; this is NOT routed through `requestDisposal`/
    // `acknowledgeWriterQuiescent` (#1807 §C), since a directive that never
    // left the coordinator needs no Audio round-trip.
    pendingSessions[recoverySessionID] = PendingSession()

    // Durably store the key off the MainActor BEFORE returning an enabled
    // payload. Fail-open: a store failure disables recovery for this take.
    let keyStore = self.keyStore
    let stored: Bool = await Task.detached(priority: .utility) {
      (try? keyStore.store(keyData: keyData, for: recoverySessionID)) != nil
    }.value
    guard stored else {
      // No durable key landed — un-protect so the scan isn't guarding a
      // phantom and a later non-saved cleanup is a no-op. Keyed by this exact
      // fresh UUID, so a concurrent double-arm (a different id) is unaffected
      // — unlike the single-slot `armedSessionID` this replaces, no id
      // collision is possible here.
      pendingSessions.removeValue(forKey: recoverySessionID)
      SentryBreadcrumb.captureError(
        RecoveryArmError.keyStoreFailed, category: .recoveryKeyStoreFailed, stage: "recording",
        extra: ["backend": backendType.rawValue])
      return nil
    }

    return (recoverySessionID, payload)
  }

  /// #1755 chunk 4 — fixed, low-cardinality labels for WHY a destruction ran.
  /// Closed enum: no caller-supplied strings, no configurability.
  ///
  /// #1807: widened from `private` to `internal` — `PendingSession
  /// .Disposition.destroy(DestructionSource)` is itself internal, and an
  /// associated value cannot be more restrictive than the case that carries
  /// it. Still constructible only within `EnviousWisprAppKit`.
  enum DestructionSource: String {
    case durableSave = "durable_save"
    case liveEnding = "live_ending"
    case preStartAbort = "pre_start_abort"
    case historyDedup = "history_dedup"
    case replayOutcome = "replay_outcome"
    case userDiscard = "user_discard"
    /// #1740: a live `.complete` dictation whose History write failed.
    case historySaveFailed = "history_save_failed"
    /// #1807 §D1: the scan found a spool that ALREADY carries a committed
    /// discard marker (`.final`/`.interruptedTemp`) — a prior pass or launch
    /// already decided to discard it, but the destructive delete never
    /// completed (crash, or the delete itself failed). No replay is ever
    /// attempted for this case; this is a cleanup retry, not a fresh decision.
    case markedForDiscard = "marked_for_discard"
  }

  /// #1755 chunk 4 test seams (internal; nil in production — the real spool
  /// store, key store, and `SentryBreadcrumb.add` run when unset). Narrow,
  /// policy-free, instance-scoped (no process-global spy, parallel-test safe).
  #if DEBUG
    /// #1755 chunk 6: crash-boundary hold seam (see the kernel's twin).
    var crashBoundaryController: CrashBoundaryFaultController = .shared
  #endif

  // periphery:ignore - test seam
  var destructionSpoolDeleteForTesting: ((String) throws -> Void)?
  // periphery:ignore - test seam
  var destructionKeyDeleteForTesting: (@Sendable (String) throws -> Void)?
  /// #1807 §D2 test seam: force the discard-marker write to fail without a
  /// real filesystem fault, so the decision table's "no durable evidence at
  /// all" fallback cell is directly reachable from a test.
  // periphery:ignore - test seam
  var destructionMarkerWriteForTesting: (@Sendable (String) throws -> Void)?
  // periphery:ignore - test seam
  var deletionFailureBreadcrumbForTesting:
    (@MainActor @Sendable (_ stage: String, _ message: String, _ data: [String: String]) -> Void)?
  /// #1740 cleanup-telemetry seam. INSTANCE-scoped, never the process-global
  /// `TelemetryService.testEventHook`: this suite runs in parallel, and a
  /// sibling test's `defer` clearing that global raced this one's emits
  /// (whole-diff review P1). `tests-no-process-global-mutable-delegate`.
  // periphery:ignore - test seam
  var cleanupTelemetryForTesting:
    (@MainActor @Sendable (_ source: String, _ component: String, _ succeeded: Bool) -> Void)?

  /// #1755 chunk 4: one failure-only breadcrumb per failed component per
  /// destruction call. Never includes the recovery ID, path, or raw error —
  /// deletion stays best-effort and swallowed; this is diagnosis only.
  private func emitDeletionFailed(component: String, source: DestructionSource, error: any Error) {
    // #1762 r5: reports the ACTION and its result, nothing further. Five review
    // rounds went to disposition clauses here — "stays on disk", "already
    // deleted", "a future launch will retry" — and each was wrong in some real
    // path: `RecoverySpoolStore.delete` also clears the attempt marker and
    // propagates THAT failure, the key delete cannot see the spool's fate under
    // concurrency, and Discard's own delete can fail after the outcome line
    // claimed success. This call site knows one thing for certain, so it says
    // exactly that. A reader correlates the spool and key lines by sequence
    // number; the log no longer does that inference for them, wrongly.
    RecoveryLog.line("\(component) delete FAILED (\(source.rawValue))")
    let data = ["component": component, "source": source.rawValue]
    if let sink = deletionFailureBreadcrumbForTesting {
      sink("recovery", "deletion_failed", data)
    } else {
      SentryBreadcrumb.add(stage: "recovery", message: "deletion_failed", data: data)
    }
    TelemetryService.shared.recoveryDeletionFailed(
      component: component, source: source.rawValue,
      errorDomain: Self.errorDomainBucket(for: error), errorCode: Self.errorCode(for: error))
  }

  private static func errorDomainBucket(for error: any Error) -> String {
    switch error {
    case let nsError as NSError where nsError.domain == NSCocoaErrorDomain: return "cocoa"
    case let nsError as NSError where nsError.domain == NSPOSIXErrorDomain: return "posix"
    default: return "other"
    }
  }

  /// `RecoveryKeyStoreError.deleteFailed(OSStatus)` bridges to `NSError` without surfacing its
  /// associated OSStatus as `.code`. Unwrap explicitly; every other error keeps its bridged NSError code.
  private static func errorCode(for error: any Error) -> Int {
    if let keyError = error as? RecoveryKeyStoreError, case .deleteFailed(let status) = keyError {
      return Int(status)
    }
    return (error as NSError).code
  }

  /// #1740 (founder Gate 2): did a SPENT attempt's cleanup actually happen?
  /// Emitted for both outcomes, success and failure, but ONLY for the two
  /// spent-attempt sources — `durable_save` fires on every successful
  /// dictation and would swamp a signal for a path this change does not touch.
  /// Shape only: source, component, succeeded. Never the id, path, or error.
  private func emitCleanupOutcome(
    component: String, source: DestructionSource, succeeded: Bool
  ) {
    switch source {
    case .replayOutcome, .historySaveFailed, .markedForDiscard:
      // #1807 §D1: `.markedForDiscard` is a retry of a previously-failed
      // cleanup (a spent decision, same spirit as the two existing spent-
      // attempt sources) — whether the retry actually succeeded is exactly
      // the signal this event exists to answer.
      if let sink = cleanupTelemetryForTesting {
        sink(source.rawValue, component, succeeded)
      } else {
        TelemetryService.shared.recoveryCleanup(
          source: source.rawValue, component: component, succeeded: succeeded)
      }
    case .durableSave, .liveEnding, .preStartAbort, .historyDedup, .userDiscard:
      // Not a spent recovery attempt — no cleanup-coverage question to answer.
      break
    }
  }

  /// The SOLE spool+key destructor (#1464). Deletes the spool file (which also
  /// clears its attempt marker) SYNCHRONOUSLY — it is cheap local FS, and a
  /// follow-up scan / the dedup + discard callers must see it gone at once — then
  /// destroys the per-session key OFF the MainActor (the key store can be securityd
  /// IPC, `keychain-not-mainactor`). Best-effort + idempotent (`try?`), so a
  /// double-delete or a concurrently-removed spool is a harmless no-op. Returns the
  /// detached key-delete work so tests can await completion; callers may discard it.
  @discardableResult
  private func destroySpoolAndKey(
    id: String, source: DestructionSource,
    markerPersistence: Task<Bool, Never>? = nil
  ) -> Task<Void, Never> {
    if let existing = discardOperations[id] { return existing }
    // #1807 round-2 correction (Codex chunk-3 review round 2, finding 1):
    // `discardOperations[id]` protects only WHILE this operation is running —
    // it clears once the work settles, success or failure. `nextLaunchOnlyRecoveryIDs`
    // is a SEPARATE concern this does not replace: if BOTH the marker write
    // and the delete fail, an id with no marker and a surviving spool must
    // still not be reclassified as a fresh REPLAY candidate this launch (the
    // exact resurrection bug this suppression exists to prevent). CLEANUP
    // eligibility (can `.markedForDiscard` retry) and REPLAY eligibility
    // (can this id enter `recoverable`) are different questions — the scan's
    // marker check now runs BEFORE this suppression is consulted (see
    // `runOneScanPass`), so a genuinely marked survivor still retries
    // cleanup regardless of this insert.
    nextLaunchOnlyRecoveryIDs.insert(id)
    let marker =
      markerPersistence
      ?? beginDiscardMarkerPersistence(recoverySessionID: id, source: source)
    return claimDiscardOperation(id: id) { [self] in
      let markerCommitted = await marker.value
      await performSpoolAndKeyDestruction(
        id: id, source: source, markerCommitted: markerCommitted
      ).value
    }
  }

  /// #1807 (§D2) — the decision table's own home. `markerCommitted` is
  /// "durable discard evidence: yes/no"; audio removal is tracked
  /// SEPARATELY from sidecar cleanup (never inferred from a combined
  /// result — `RecoverySpoolStore.delete()`'s old conflated shape is why
  /// this method no longer calls it). Sidecars remain intact until audio
  /// removal is durable. Then sidecar and key attempts fail independently.
  ///
  /// | durable discard evidence | audio removal confirmed | key action |
  /// |---|---|---|
  /// | yes | yes | delete |
  /// | yes | no  | **retain key, retain discard evidence** |
  /// | no  | yes | delete |
  /// | no  | no  | best-effort erasure (today's existing fallback) |
  ///
  /// Discard evidence is removed LAST, only after CONFIRMED synced audio
  /// removal — never before, and never when audio removal failed (the
  /// interrupted-write / final marker is exactly what must survive that
  /// case, so a future launch never resurrects it as a fresh orphan).
  private func performSpoolAndKeyDestruction(
    id: String, source: DestructionSource, markerCommitted: Bool
  ) -> Task<Void, Never> {
    let store = makeSpoolStore()
    let audioOverride = destructionSpoolDeleteForTesting
    let keyStore = self.keyStore
    let keyOverride = destructionKeyDeleteForTesting
    #if DEBUG
      let crashBoundaryController = self.crashBoundaryController
    #endif
    return Task { @MainActor [self] in
      #if DEBUG
        crashBoundaryController.boundaryReached(.beforeSpoolDelete)
      #endif
      let audioResult: Result<Void, any Error>
      if let audioOverride {
        // Existing actor-confined test seam; production disk work is detached.
        audioResult = Result { try audioOverride(id) }
      } else {
        audioResult = await Task.detached(priority: .utility) {
          Result { try store.removeSpoolAudioDurably(recoverySessionID: id) }
        }.value
      }
      let audioRemovalConfirmed: Bool
      switch audioResult {
      case .success:
        audioRemovalConfirmed = true
      case .failure(let error):
        audioRemovalConfirmed = false
        emitDeletionFailed(component: "spool", source: source, error: error)
      }

      var sidecarCleanupSucceeded = true
      if audioRemovalConfirmed {
        let result = await Task.detached(priority: .utility) {
          Result { try store.cleanupSpoolSidecars(recoverySessionID: id) }
        }.value
        if case .failure(let error) = result {
          sidecarCleanupSucceeded = false
          emitDeletionFailed(component: "spool", source: source, error: error)
        }
      }
      emitCleanupOutcome(
        component: "spool", source: source,
        succeeded: audioRemovalConfirmed && sidecarCleanupSucceeded)

      if markerCommitted && !audioRemovalConfirmed {
        RecoveryLog.line("retaining key: durable discard evidence, unconfirmed audio removal")
        return
      }

      let keyResult: Result<Void, any Error> = await Task.detached(priority: .utility) {
        #if DEBUG
          crashBoundaryController.boundaryReached(.beforeKeyDelete)
        #endif
        return Result {
          if let keyOverride {
            try keyOverride(id)
          } else {
            try keyStore.delete(for: id)
          }
        }
      }.value
      switch keyResult {
      case .success:
        emitCleanupOutcome(component: "key", source: source, succeeded: true)
      case .failure(let error):
        emitDeletionFailed(component: "key", source: source, error: error)
        emitCleanupOutcome(component: "key", source: source, succeeded: false)
      }

      // Evidence is last; failed key/sidecar cleanup cannot prevent this attempt.
      if audioRemovalConfirmed {
        durableDiscardEvidenceIDs.remove(id)
        let result: Result<Void, any Error> = await Task.detached(priority: .utility) {
          var firstFailure: (any Error)?
          do { try store.deleteDiscardMarker(for: id) } catch { firstFailure = error }
          do { try store.syncSpoolDirectory() } catch { firstFailure = firstFailure ?? error }
          if let firstFailure { return .failure(firstFailure) }
          return .success(())
        }.value
        if case .failure(let error) = result {
          emitDeletionFailed(component: "marker", source: source, error: error)
        }
      }
    }
  }

  // MARK: - #1807 (§C) — session-keyed protection + writer-completion join

  /// A `handle*` call installs this LIVE-ARMED session's final disposition (a
  /// specific `DestructionSource`, or `.retain` for "keep it"). Joins with
  /// `acknowledgeWriterQuiescent` — cleanup runs only once BOTH facts are
  /// known, whichever arrives second. Idempotent: a duplicate call for a
  /// session whose disposition is already installed joins the existing
  /// operation rather than starting another one. Returns a `Task` that
  /// completes once this session's cleanup has SETTLED — claimed, and for a
  /// destroy, its detached key-deletion work has finished — never merely
  /// dispatched. Production callers discard it; tests await it instead of a
  /// fixed delay (§11's test contract).
  ///
  /// `internal`, not `private`: the RETAIN branch of `PendingSession
  /// .Disposition` is currently unreachable through any real
  /// `RecordingRecoveryEnding` (every cell of `shouldDeleteOnLiveEnding`
  /// returns true today) — exposed for direct testing of that branch, the
  /// same reasoning `shouldDeleteOnLiveEnding`/`shouldDeleteAfterReplay`
  /// already use for their own static, directly-tested predicates.
  @discardableResult
  func requestDisposal(
    recoverySessionID id: String, disposition: PendingSession.Disposition
  ) -> Task<Void, Never> {
    // #1807 round-2 correction (Codex chunk-2 review, finding 2): a missing
    // entry means either this id was never admitted, or it was already
    // retired — NEVER manufacture a fresh one here. Doing so could strand a
    // waiter (nothing will ever complete the phantom entry's other half) or
    // let an already-cleaned-up session be re-processed.
    guard var entry = pendingSessions[id] else { return Task {} }
    if entry.disposition == nil, !entry.cleanupClaimed {
      entry.disposition = disposition
      if case .destroy(let source) = disposition {
        // #1807 (§D1): marker persistence begins as soon as final disposition
        // arrives — NOT gated on the writer-quiescence join below, which can
        // still be pending. Off-MainActor, per §D2's ordering item 2
        // (inherited by §D1). A `.retain` disposition writes no marker — a
        // marker means "never replay," which is the opposite of retaining.
        entry.markerPersistence = beginDiscardMarkerPersistence(
          recoverySessionID: id, source: source)
      }
    }
    return awaitSettlement(recoverySessionID: id, entry: entry)
  }

  /// Begins immediately at disposition, and settles before destructive cleanup.
  ///
  /// Returns whether durable discard evidence is established. A retained
  /// session keeps its proven commit across later cleanup attempts.
  private func beginDiscardMarkerPersistence(
    recoverySessionID id: String, source: DestructionSource
  ) -> Task<Bool, Never> {
    if durableDiscardEvidenceIDs.contains(id) { return Task { true } }
    let store = makeSpoolStore()
    let override = destructionMarkerWriteForTesting
    return Task.detached(priority: .utility) { [self] in
      do {
        if let override {
          try override(id)
        } else {
          let existingEvidence = try store.synchronizeExistingDiscardEvidence(for: id)
          if !existingEvidence { try store.writeDiscardMarker(for: id) }
        }
        await MainActor.run { _ = self.durableDiscardEvidenceIDs.insert(id) }
        return true
      } catch {
        await MainActor.run {
          self.emitDeletionFailed(component: "marker", source: source, error: error)
        }
        return false
      }
    }
  }

  /// The writer confirms it can never write to `id`'s spool again — fires for
  /// a real writer's finalize AND for every explicit "no writer, ever"
  /// acknowledgment (decode failure, disabled directive, low-disk refusal,
  /// and a pre-start abort's own direct ack). Idempotent — a late/duplicate
  /// ack for an already-claimed session joins silently. `internal`, not
  /// `private`: `WisprBootstrapper` (same module, different file) wires
  /// Audio's completion closure directly to this.
  func acknowledgeWriterQuiescent(recoverySessionID id: String) {
    // #1807 round-2 correction: same reasoning as `requestDisposal` above —
    // a missing entry means never-admitted or already-retired, either way
    // nothing to acknowledge.
    guard var entry = pendingSessions[id] else { return }
    guard !entry.cleanupClaimed else { return }
    entry.writerCanNeverWriteAgain = true
    pendingSessions[id] = entry
    tryClaimAndRunCleanup(recoverySessionID: id)
  }

  /// Writes `entry` back, attempts the join, and returns a `Task` resolved on
  /// settlement — now, if the join completes synchronously as part of this
  /// very call; later, when the missing half arrives via the other entry
  /// point above.
  private func awaitSettlement(
    recoverySessionID id: String, entry: PendingSession
  ) -> Task<Void, Never> {
    pendingSessions[id] = entry
    if let settling = tryClaimAndRunCleanup(recoverySessionID: id) {
      return settling
    }
    // #1807 round-2 correction (Codex chunk-2 review, finding 4): STRONG
    // self capture, matching `destroySpoolAndKey`'s own established pattern
    // ("the failure breadcrumb must survive coordinator deallocation racing
    // the detached delete"). A `[weak self]` here can silently strand a
    // waiter forever if the coordinator is released while this task is
    // in flight — the continuation lives INSIDE `pendingSessions`, so a
    // dropped `self` before the continuation registers means no path this
    // task's own reference chain can rely on. The task is short-lived; the
    // temporary strong retention ends when it completes.
    return Task { @MainActor [self] in
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        guard var waiting = self.pendingSessions[id] else {
          // Already retired — a same-launch race resolved it between the
          // write above and this continuation being registered.
          continuation.resume()
          return
        }
        waiting.settlementContinuations.append(continuation)
        self.pendingSessions[id] = waiting
      }
    }
  }

  /// The ONE place a session's cleanup operation is claimed and run, whichever
  /// of `requestDisposal`/`acknowledgeWriterQuiescent` completes the join.
  /// Returns the settling `Task` when it claimed and started cleanup just now;
  /// nil when the join is still incomplete (leaves the entry protected) or was
  /// already claimed by an earlier call.
  @discardableResult
  private func tryClaimAndRunCleanup(recoverySessionID id: String) -> Task<Void, Never>? {
    guard var entry = pendingSessions[id],
      let disposition = entry.disposition,
      entry.writerCanNeverWriteAgain,
      !entry.cleanupClaimed
    else { return nil }
    entry.cleanupClaimed = true
    pendingSessions[id] = entry
    // #1807 round-2 correction (finding 4): STRONG self capture in both
    // branches below — see `awaitSettlement`'s identical note.
    switch disposition {
    case .retain:
      return Task { @MainActor [self] in
        self.retireSettledSession(recoverySessionID: id)
      }
    case .destroy(let source):
      let inner = destroySpoolAndKey(
        id: id, source: source, markerPersistence: entry.markerPersistence)
      return Task { @MainActor [self] in
        _ = await inner.value
        self.retireSettledSession(recoverySessionID: id)
      }
    }
  }

  /// Remove a session's entry once its cleanup has genuinely settled, and
  /// resume every caller awaiting settlement.
  private func retireSettledSession(recoverySessionID id: String) {
    guard let entry = pendingSessions.removeValue(forKey: id) else { return }
    for continuation in entry.settlementContinuations {
      continuation.resume()
    }
  }

  /// Delete-versus-retain for a live recording that ended without a durable
  /// save (#1464; policy cutover #1755, founder Gate 2 2026-07-23). An ending
  /// fired ⇒ the app was ALIVE ⇒ the user witnessed the outcome, got the one
  /// in-session rescue, and re-dictates — so EVERY represented ending requests
  /// best-effort deletion (`discard-not-differentiate`). Launch replay is
  /// reserved for the no-ending app-gone orphan, which never reaches this
  /// predicate. The switch stays exhaustive with no `default` so a future
  /// ending case forces an explicit decision here. Static + internal so the
  /// cells are unit-tested directly (`matcher-set-adversarial-tests`).
  static func shouldDeleteOnLiveEnding(_ ending: RecordingRecoveryEnding) -> Bool {
    switch ending {
    // #1920: `.asrEmptyDespiteAudio` deletes like every other concluded live
    // ending. The app was alive, the user witnessed the take end with no text,
    // and re-pressing the key is the whole recovery — a surprise replay of a
    // wordless recording at a later launch would be a bug in their eyes.
    case .discarded, .noSpeech, .asrRetryExhausted, .asrEmptyDespiteAudio:
      return true
    case .failed, .audioInterrupted, .asrInterrupted, .noTransport:
      // #1755: flipped from retain — the in-session salvage/retry was the
      // user's one rescue; a surprise replay at a later launch is a bug in
      // the user's eyes, not a favor.
      return true
    // #2087: the trigger is deliberately ignored here. Both a shortcut and a
    // button cancel remain ordinary destructive cancels for spool purposes;
    // Escape Recovery changes what happens to the TEXT, never to the audio.
    case .cancelled(.user(_)):
      return true
    case .cancelled(.systemOrFault):
      // #1755: flipped — every producer is app-alive by construction (an
      // app-gone event cannot publish any ending; it leaves an orphan).
      return true
    }
  }

  /// Delete-versus-retain after a launch replay attempt (#1464; #1740 cutover).
  /// EVERY spent attempt deletes: an attempt that actually ran is the user's one
  /// rescue, whatever its outcome. Only outcomes where ASR never ran retain.
  /// Static + internal for direct adversarial testing.
  static func shouldDeleteAfterReplay(_ outcome: RecoveryReplayOutcome) -> Bool {
    switch outcome {
    case .recovered, .abandoned:
      return true
    case .failed(.unrecoverable), .failed(.save):
      // #1740: the ATTEMPT is spent. Recovering the audio and failing only the
      // History write is still an attempt; retaining it for a later launch is
      // the safety net the one-attempt rule removes. The committed attempt
      // marker — not this deletion — is what makes "one attempt" structural: a
      // spool that survives a failed delete still abandons at the entry guard.
      return true
    case .aborted:
      // `discardActiveRecovery` already requested destruction. NOT a claim that
      // no attempt ran — a Discard can land after transcription.
      return false
    case .deferred, .deferredMarkerClearFailed, .deferredPersistenceFailed:
      // ASR never ran, so the attempt is unspent. `.deferredMarkerClearFailed`
      // is the transient-Keychain case #1360 closed — never treat it as a
      // permanent deletion trigger. `.deferredPersistenceFailed` (#2207) is the
      // same shape: the readiness retry could not be recorded, so the spool is
      // held rather than destroyed.
      return false
    }
  }

  /// #1762 — the human-readable outcome label for the local debug log. Exhaustive
  /// so a new outcome cannot be added without choosing how it reads on screen;
  /// `default` here would silently log the wrong thing for a future case.
  ///
  /// Deliberately says nothing beyond the outcome name — no transcript text, no
  /// spool id, no path. `RecoveryLog`'s privacy rule applies to every caller.
  static func logLabel(_ outcome: RecoveryReplayOutcome) -> String {
    switch outcome {
    case .recovered: return "recovered — transcript saved to History"
    case .abandoned: return "abandoned — a prior attempt had already started"
    case .failed(.unrecoverable): return "unrecoverable — the attempt is spent"
    case .failed(.save): return "recovered but the History write failed"
    case .aborted: return "aborted — the user pressed Discard"
    case .deferred: return "deferred — no attempt ran"
    case .deferredMarkerClearFailed:
      return "deferred, attempt marker not cleared — a new launch re-checks it"
    case .deferredPersistenceFailed:
      return "deferred, readiness retry not recorded — a new launch abandons it"
    }
  }

  /// A recording's transcript was durably saved — delete that session's spool +
  /// key. Best-effort, off the user's path, idempotent. Returns a `Task` that
  /// completes once cleanup has SETTLED (#1807 §C: waits for the writer's own
  /// confirmation it can never write again, not merely for disposition to be
  /// known) so tests can await it; production callers discard it.
  @discardableResult
  func handleDurableSave(recoverySessionID id: String) -> Task<Void, Never> {
    requestDisposal(recoverySessionID: id, disposition: .destroy(.durableSave))
  }

  /// A `.complete` dictation whose History save FAILED (#1740). The live path
  /// still delivers the text because the save error is absorbed, so retaining
  /// this spool would buy only a later History row. Request best-effort
  /// destruction instead: #1740 removed the last live retention path.
  ///
  /// Suppress BEFORE the best-effort delete, matching
  /// `handleRecordingEndedWithoutDurableSave`: the same terminal transition
  /// fires `onDictationEndedForRecovery` moments later via the SAME synchronous
  /// `fireStateChangeIfNeeded()` call, and that same-launch wake must not
  /// rediscover a spool whose deletion failed.
  ///
  /// #1807 (founder decision, superseding the note this replaces): unlike
  /// launch replay, this spool carries no ATTEMPT marker — no replay ever
  /// ran for it. The original note here said that meant a later launch
  /// would give a delete-failure survivor its FIRST crash-recovery attempt,
  /// "consistent with the one-attempt rule." Codex's design review (Q3)
  /// found this made `.historySaveFailed` the one destruction source that
  /// could not honestly promise "never replay a concluded take" without an
  /// explicit decision — the founder chose uniformity: this source now
  /// writes the SAME durable no-replay marker (§D1) every other source
  /// does, before its delete is even attempted, so a survivor is a
  /// `.markedForDiscard` cleanup retry on the next scan, never a fresh
  /// first-ever attempt. No special case remains. No-op when `id` is nil
  /// (armed only when recovery was on).
  @discardableResult
  func handleHistorySaveFailed(recoverySessionID id: String?) -> Task<Void, Never>? {
    guard let id else { return nil }
    nextLaunchOnlyRecoveryIDs.insert(id)
    return requestDisposal(recoverySessionID: id, disposition: .destroy(.historySaveFailed))
  }

  /// A recording ended at a terminal state WITHOUT a durable transcript save
  /// (#1063 PR2 / #1464; #1755 cutover). Applies `shouldDeleteOnLiveEnding`
  /// to the narrow `RecordingRecoveryEnding` the driver projected — under the
  /// discard doctrine EVERY represented ending destroys the spool + key now.
  /// Idempotent + best-effort; a no-op when `id` is nil. Always clears the
  /// live-recording protection (the recording is over). Returns the detached
  /// delete work so tests can await it.
  ///
  /// The retain branch below is the future-proof expression of the sole
  /// policy authority: currently unreachable (no ending returns false), it
  /// keeps the deferral wiring honest should a future ending case ever
  /// decide to retain. Runs before the same-launch rescan Task is
  /// even scheduled (both synchronous MainActor calls from the same driver
  /// callback), so the exclusion is always in place before the pass runs.
  @discardableResult
  func handleRecordingEndedWithoutDurableSave(
    recoverySessionID id: String?, ending: RecordingRecoveryEnding
  ) -> Task<Void, Never>? {
    guard let id else { return nil }
    guard Self.shouldDeleteOnLiveEnding(ending) else {
      // #1762: the RETAIN branch. A live ending that keeps its spool is the one
      // that produces an orphan for a later launch to find, so it must not be
      // silent — otherwise the next launch's discovery has no antecedent.
      // Synchronous hook, so this cannot await. Ordering does not matter here:
      // this line stands alone rather than pairing with a later outcome.
      Task {
        RecoveryLog.line("live ending (\(ending)) — keeping the spool for a future launch")
      }
      nextLaunchOnlyRecoveryIDs.insert(id)
      // #1807 (§C): retain still joins the writer-quiescence contract — the
      // entry stays protected until the writer confirms it will never touch
      // this spool again, exactly like the delete branch below. Only then is
      // protection actually safe to drop.
      return requestDisposal(recoverySessionID: id, disposition: .retain)
    }
    // #1762: the DELETE branch. Logged on REQUEST, before the destructor runs —
    // `emitDeletionFailed` only fires on failure, so a successful live-ending
    // cleanup was entirely invisible. The issue asked for the ending family and
    // whether deletion was requested; both are here.
    RecoveryLog.line("live ending (\(ending)) — requesting spool deletion")
    // GitHub cloud review PR #1761: suppress BEFORE the best-effort delete.
    // If the spool deletion fails (transient FS/permission error), the same
    // callback fires `onDictationEndedForRecovery` moments later — without
    // this, that same-launch rescan could rediscover and REPLAY the
    // undeleted spool, resurrecting a take whose live terminal the user
    // already saw. A successful delete makes the suppression harmless; a
    // failed one leaves the survivor as a next-launch item, consistent with
    // the best-effort crash-atomicity contract (§3.5).
    nextLaunchOnlyRecoveryIDs.insert(id)
    return requestDisposal(recoverySessionID: id, disposition: .destroy(.liveEnding))
  }

  /// A record-press aborted BEFORE a kernel session was minted (a PTT release or
  /// concurrent-toggle stop in the arm window, or a stale recovery gate) — no
  /// `RecordingOutcome` fires, so this is the ONLY cleanup signal (#1464). Always a
  /// discard: nothing was captured. Clears the live-recording protection and
  /// destroys the just-armed spool/key through the sole destructor. Idempotent +
  /// best-effort; a no-op when `id` is nil. Returns the detached work for tests.
  @discardableResult
  func handlePreStartAbort(recoverySessionID id: String?) -> Task<Void, Never>? {
    guard let id else { return nil }
    // #1807 (§C): a pre-start abort means no kernel session was ever minted,
    // so Audio never saw this id and no writer could ever exist for it —
    // acknowledge that directly rather than waiting on a round-trip that will
    // never arrive. Order versus `requestDisposal` below does not matter: the
    // join completes once both halves are installed, whichever runs first.
    acknowledgeWriterQuiescent(recoverySessionID: id)
    return requestDisposal(recoverySessionID: id, disposition: .destroy(.preStartAbort))
  }

  /// On launch, scan for orphan spools and recover them (#1063 PR2 — replaces
  /// PR1's purge). Single-flight via the same owning drain loop
  /// `requestRecoveryRecheck()` uses (#1707 Phase 3, §3.4) — a concurrent call
  /// coalesces into a follow-up pass rather than running twice.
  func scanAndRecover() async {
    pendingRescan = true
    guard !scanInProgress else {
      recoveryScanTrigger = "launch"
      RecoveryLog.line("launch scan arrived mid-pass — a follow-up pass is queued")
      return
    }
    scanInProgress = true
    recoveryScanTrigger = "launch"
    await drainPendingRescan()
  }

  /// #1707 Phase 3 (§3.4) — the sole synchronous, MainActor, no-`await` entry
  /// point every wake-up cause calls to request a fresh recovery pass: a live
  /// dictation ending, an engine switch/warm/setup-migration completing, or
  /// `EngineRecoveryGate.endMutation()` returning true (a denied recovery claim
  /// is now owed a retry, §3.2). Safe to call from a bare `defer`. Coalesces
  /// with any in-progress pass through the SAME owning drain loop
  /// `scanAndRecover()` uses — never a parallel path.
  func requestRecoveryRecheck() {
    pendingRescan = true
    guard !scanInProgress else {
      // #1762 r2: relabel, or the drain loop credits this follow-up to whichever
      // trigger opened the loop — a wake during a launch scan would read "launch".
      recoveryScanTrigger = "wake"
      RecoveryLog.line("wake arrived mid-pass — a follow-up pass is queued")
      return
    }
    scanInProgress = true
    recoveryScanTrigger = "wake"
    Task { await drainPendingRescan() }
  }

  /// The single owning loop behind both public entry points above (§3.4 —
  /// replaces an earlier recursive re-invocation design that had a lost-trigger
  /// race and a live-yield/pending-rescan interaction). Clears `pendingRescan`
  /// immediately before each pass, so a trigger arriving mid-pass causes
  /// exactly one later pass, never zero and never two. A pass that yielded
  /// specifically because of a pending live-start signal discards any pending
  /// rescan rather than honoring it immediately — reclaiming the engine right
  /// after yielding it would defeat the entire point of the yield; the live
  /// dictation's own later end becomes the next legitimate wake-up instead.
  private func drainPendingRescan() async {
    defer { scanInProgress = false }
    var passNumber = 0
    while pendingRescan {
      pendingRescan = false
      passNumber += 1
      // #1762: log where the pass ACTUALLY starts, not where it was requested.
      // A wake arriving mid-pass queues a FOLLOW-UP pass through this loop; an
      // earlier draft claimed it joined the running pass, which is not what the
      // loop does. Announcing each pass here is accurate whatever schedules it.
      RecoveryLog.line("scan pass \(passNumber) started (\(recoveryScanTrigger))")
      let yieldedToLiveStart = await runOneScanPass()
      if yieldedToLiveStart {
        pendingRescan = false
        // #1762: BOTH exits say so. A `defer` cannot await, and this early
        // return is the yielded-to-live-dictation path — the one most likely to
        // be misread as a scan that simply stopped.
        RecoveryLog.line("scan finished (yielded to a live dictation)")
        return
      }
    }
    RecoveryLog.line("scan finished")
  }

  /// The production orphan-key sweep, returned so tests can await this operation
  /// independently of the marker sweep that may legitimately retire its evidence.
  @discardableResult
  func startKeyOnlySweep() -> Task<Void, Never> {
    let keyStore = self.keyStore
    let makeSpoolStore = self.makeSpoolStore
    return Task.detached(priority: .utility) { [weak self] in
      let keyIDs = keyStore.listAccountIDs()
      // #1807 (§C): a vanished coordinator must ABORT the sweep — it is not
      // evidence the protection set is empty. `self?.protectedSessionIDs`
      // reads nil only when `self` is nil, never when the set is genuinely
      // empty (an empty dictionary's `.keys` is a real, non-nil, empty value).
      guard let liveArmedKeys = await MainActor.run(body: { self?.protectedSessionIDs })
      else { return }
      let liveArmed = Set(liveArmedKeys)
      // Fail CLOSED if the fresh re-list errors (Codex code-diff r5 P2): treating
      // an IO/permission error as "no spools" would delete keys for real `.ewrec`
      // files. Abort the sweep instead — same discipline as the scan-start list.
      guard let currentSpoolList = try? makeSpoolStore().listSpoolSessionIDs() else { return }
      let currentSpools = Set(currentSpoolList)
      for id in keyIDs where !liveArmed.contains(id) && !currentSpools.contains(id) {
        // A failed audio-directory sync leaves a marker and a retained key.
        // The marker-only sweep must establish durable absence before this
        // orphan-key path can erase that key. Unreadability also defers.
        guard makeSpoolStore().hasDiscardMarker(for: id) == .absent else { continue }
        try? keyStore.delete(for: id)
      }
    }
  }

  /// One full discovery + per-item-replay pass. Returns `true` exactly when
  /// the pass stopped because a live record-press was refused mid-scan (§3.1)
  /// — the signal `drainPendingRescan()` uses to stop draining outright rather
  /// than immediately re-claiming the engine for a stale pending rescan.
  private func runOneScanPass() async -> Bool {
    let store = makeSpoolStore()
    // Fail CLOSED on a scan error (Codex code-diff r3 P2): a directory IO /
    // permission failure must NOT be read as "no spools" — the key-only sweep
    // below would then see an empty spool set and delete keys for spools that
    // exist but weren't listed, making those recordings undecryptable. A genuine
    // empty directory throws nothing and returns [].
    let spoolIDs: [String]
    do {
      spoolIDs = try store.listSpoolSessionIDs()
    } catch {
      // #1762: the fail-closed branch above is invisible on disk — it looks
      // identical to "no spools". Say which one happened.
      RecoveryLog.line("scan aborted — could not list the spool directory; nothing deleted")
      return false
    }
    // #1762: BEFORE any early return, including zero. A pass that found nothing
    // and finished must not read like a pass that stalled — that ambiguity is
    // the whole reason this issue exists.
    RecoveryLog.line("\(spoolIDs.count) spool(s) on disk")

    // Sweep KEY-ONLY orphans first: a key whose spool was never written — a
    // recording that armed then crashed before the helper wrote the first frame.
    // The spool scan can't see these (no `.ewrec` file), so without this they leak
    // a recovery key forever; the PR1 launch purge swept them via `listAccountIDs`
    // (Codex code-diff P2). Off-MainActor (`keychain-not-mainactor`); excludes
    // every id that DOES have a spool (deduped or recovered below, and still needs
    // its key to decrypt). Runs even when there are zero spools.
    //
    // Race-safe ordering (Codex code-diff r2 + r4 P2): inside the detached task,
    // snapshot the keys FIRST, then read the live-armed set AND re-list the
    // spools FRESH (not the scan-start `spoolIDs` snapshot). Three protections,
    // each read as late as possible so it sees the most recent state:
    //   - a key armed AFTER the key snapshot can't be in `keyIDs` (stored later);
    //   - a currently-arming take is caught by the freshly-read protection set;
    //   - a take that armed AND ENDED at a FAILURE terminal after the scan snapshot
    //     RETAINS its spool — re-listing spools fresh sees that spool, so its key is
    //     NOT swept (the stale scan-start snapshot would have missed it and deleted
    //     the key, making that recording undecryptable — r4 P2).
    // Only a key with NO spool now (and not live-armed) is a true key-only orphan.
    startKeyOnlySweep()

    // Every sweep candidate claims the same per-session operation as disposal.
    let markerSweep = Task.detached(priority: .utility) { [weak self] in
      guard let markerIDs = try? store.listDiscardMarkerSessionIDs(),
        let listedSpools = try? store.listSpoolSessionIDs()
      else { return }
      for id in Set(markerIDs).subtracting(listedSpools) {
        let cleanup: Task<Void, Never>? = await MainActor.run {
          guard let self, !self.protectedSessionIDs.contains(id) else { return nil }
          // Audio absence still needs a durable confirmation. The common
          // operation also cleans the sidecars/key preserved by an earlier
          // failed sync, before removing the discard evidence last.
          return self.destroySpoolAndKey(id: id, source: .markedForDiscard)
        }
        if let cleanup { await cleanup.value }
      }
    }
    markerSweepForTesting = markerSweep

    guard !spoolIDs.isEmpty else { return false }

    // Snapshot the History dedup set. A recording that arms during the dedup
    // `await` mints a fresh UUID not in `spoolIDs` (listed above) — already
    // excluded; the contention guard below is the backstop.
    let alreadySaved = await existingRecoveryIDs()

    // #1807 (§C): read the live-armed protection set FRESH, after the dedup
    // await above, not the value that would have been captured before it — a
    // take that armed DURING that suspension must be excluded too, matching
    // the recheck-after-every-suspension requirement (§C, independent of §D).
    let armedIDs = protectedSessionIDs
    var recoverable: [String] = []
    // #1807 round-2 correction (Codex chunk-3 review round 2, finding 1):
    // `nextLaunchOnlyRecoveryIDs` is no longer part of THIS loop condition —
    // an id held for a future launch must still have its MARKER checked
    // (below), so a `.markedForDiscard` retry is never blocked by the same
    // suppression that protects REPLAY eligibility. Only after the marker
    // check clears as `.absent` does the suppression apply, right before
    // `recoverable`/History-dedup classification.
    for id in spoolIDs where !armedIDs.contains(id) {
      // #1807 (§D1): the discard marker is checked BEFORE History-dedup
      // classification, in this SAME sequence — not a separate pass. A
      // committed discard decision vetoes replay ahead of every other check,
      // and (round 2) ahead of the same-launch suppression below too —
      // CLEANUP eligibility and REPLAY eligibility are different questions.
      switch store.hasDiscardMarker(for: id) {
      case .final, .interruptedTemp:
        // Never replay; a prior pass or launch already decided to discard
        // this spool but the destructive delete never completed. Retry
        // cleanup without ever appending to `recoverable`.
        RecoveryLog.line("already marked for discard — retrying cleanup, no replay")
        destroySpoolAndKey(id: id, source: .markedForDiscard)
        continue
      case .unreadable:
        // Cannot tell — defer this spool THIS PASS rather than guess either
        // way (never collapse into `.absent`, the exact `fileExists` mistake
        // §A already fixed once in this file).
        RecoveryLog.line("discard marker unreadable — deferring this spool this pass")
        continue
      case .absent:
        break  // ordinary eligibility checks apply below
      }
      // #1807 round-2 correction (finding 1): an UNMARKED id already held for
      // a future launch (a live-ending/history-save-failure whose cleanup
      // failed, with no marker ever committed) must not be reclassified as a
      // fresh replay candidate this launch — the resurrection bug this
      // suppression exists to prevent. A marked id already retried above and
      // never reaches this line.
      guard !nextLaunchOnlyRecoveryIDs.contains(id) else { continue }
      if alreadySaved.contains(id) {
        // Saved in a prior run's save→delete crash window: delete WITHOUT
        // re-transcribing (the dedup MUST precede any append — History forbids a
        // duplicate id). Routed through the sole destructor (#1464); these ids are
        // never appended to `recoverable`, so the async delete never races a replay.
        RecoveryLog.line("already in History — deleting without re-transcribing")
        destroySpoolAndKey(id: id, source: .historyDedup)
      } else {
        recoverable.append(id)
      }
    }
    guard !recoverable.isEmpty else {
      RecoveryLog.line("\(spoolIDs.count) spool(s) found, none recoverable — pass done")
      return false
    }

    // #1707 Phase 3 (§3.3): skip ids whose marker-clear failure means only a
    // genuinely NEW launch may safely re-check them — they stay on disk,
    // untouched, waiting for a future launch's fresh coordinator instance.
    let attemptable = recoverable.filter { !nextLaunchOnlyRecoveryIDs.contains($0) }
    guard !attemptable.isEmpty else {
      // #1762 r3: generic on purpose. `nextLaunchOnlyRecoveryIDs` also holds
      // live endings and History-save failures whose delete failed, and neither
      // has a replay marker — naming one cause would be wrong for most members.
      RecoveryLog.line(
        "\(recoverable.count) recoverable, all held for a future launch — pass done")
      return false
    }

    RecoveryLog.line("\(attemptable.count) spool(s) to attempt this pass")
    TelemetryService.shared.recoveryFound(count: attemptable.count)
    // #1707 Phase 3 (§3.1): cleared once per fresh pass — a live-start refusal
    // observed DURING this pass (between items, below) still yields the
    // engine; a refusal from a PRIOR pass must not spuriously yield this one.
    pendingLiveStartSignal = false

    for id in attemptable {
      // GitHub cloud review, PR #1732: between the PRIOR item's `defer`
      // (which flips `isRecovering` back to `false`) and this item's own
      // claim below, nothing suspends — so a record-press whose Task is
      // queued exactly in that window never actually gets a scheduling turn
      // to observe `isRecovering == false` and proceed; Swift's MainActor
      // only switches tasks at a genuine suspension point. `await
      // Task.yield()` here gives such a press its turn BEFORE this item's
      // check-and-claim sequence begins, so it can mint its own session
      // normally instead of waiting through this item too. Placed before the
      // atomic handshake below, not inside it — the handshake itself still
      // has no `await` between its own check and claim.
      await Task.yield()
      // #1807 round-2 correction (Codex chunk-2 review, finding 3): recheck
      // pending membership immediately after this suspension, before replay
      // admission — a take that armed DURING the yield above must not be
      // replayed. Matches the recheck-after-every-suspension requirement
      // (§C) and the identical recheck already applied to the dedup loop
      // above, after its own `await`.
      guard !protectedSessionIDs.contains(id) else { continue }
      // #1807 round-2 correction (chunk-3 review round 2, finding 1): the
      // marker check runs BEFORE the same-launch suppression check, exactly
      // like the dedup loop above — a marked survivor still retries cleanup
      // even if it's also in `nextLaunchOnlyRecoveryIDs`.
      switch store.hasDiscardMarker(for: id) {
      case .final, .interruptedTemp:
        destroySpoolAndKey(id: id, source: .markedForDiscard)
        continue
      case .unreadable:
        continue
      case .absent:
        break
      }
      guard !nextLaunchOnlyRecoveryIDs.contains(id) else { continue }
      // Atomic per-item handshake (§3.1/§3.2) — ONE non-suspending MainActor
      // turn: checked and claimed here with no `await` between any step, so
      // there is no window between "checked" and "acted." Preserves the
      // existing switch symmetry exactly: a switch already in progress makes
      // recovery defer here; once `isRecovering` is set below, a NEW switch
      // cannot begin (`EngineCoordinator` already checks it).
      guard !pendingLiveStartSignal else {
        RecoveryLog.line(
          "yielding the engine to a live dictation — remaining spools stay on disk")
        return true
      }
      // Contention guard: never run the shared engine while a live dictation is
      // in flight (a recording can start in the launch window, including with
      // recovery OFF) OR while an engine switch is in flight (#1171 — a switch
      // unloads/sets the active engine; starting recovery on top would race the
      // shared engine). Defer the remaining orphans — they stay on disk.
      guard !isDictationActive(), !isEngineSwitching() else {
        RecoveryLog.line(
          isDictationActive()
            ? "deferred — a dictation is in flight; spools stay on disk"
            : "deferred — an engine switch is in flight; spools stay on disk")
        return false
      }
      guard recoveryEngineClaim.tryBegin() else {
        RecoveryLog.line(
          "deferred — the engine gate is held; a retry is owed when it releases")
        // The gate is held by an in-flight mutation; its `endMutation()`
        // wake-up (§3.2's `recoveryRetryOwed`) calls `requestRecoveryRecheck()`
        // when it releases, so stopping here is never a stranded deferral.
        return false
      }
      isRecovering = true

      activeRecoveryID = id
      let generationAtStart = recoveryGeneration
      // Per-item — not per-scan (§3.1) — so a switch deferred behind THIS item
      // can retry as soon as THIS item's claim releases, not only after the
      // whole multi-item scan. R1 (Codex REV-2, BLOCKER) still holds: this
      // fires on EVERY exit from this iteration — normal completion, a thrown
      // error, or `break` — so a stuck `isRecovering = true` can never brick
      // recording.
      defer {
        activeRecoveryID = nil
        isRecovering = false
        recoveryEngineClaim.end()
        onRecoveryComplete?()
      }
      // #1762: BEFORE the await, not after. If the process wedges or dies inside
      // model load or transcription — the failure this diagnostic exists to
      // investigate — an after-the-fact line never runs, and the log cannot show
      // that this item ever entered replay. Pairs with the outcome line below:
      // an "attempting" with no outcome IS the signature of a wedge.
      RecoveryLog.line("attempting replay")
      let outcome = await replayer.replay(recoverySessionID: id) { [weak self] in
        // Discard bumps `recoveryGeneration`; a mismatch ⇒ abandon this in-flight
        // replay. Coordinator gone ⇒ treat as aborted (safe).
        self?.recoveryGeneration != generationAtStart
      }
      // #1707 Phase 3 (§3.3): a marker-clear failure under either deferred
      // outcome means only a genuinely new launch may safely re-check this id.
      switch outcome {
      case .deferredMarkerClearFailed, .deferredPersistenceFailed:
        // #1707 Phase 3, extended by #2207: both mean the bookkeeping did not
        // complete, so only a genuinely new launch may re-check this id. A
        // same-launch rescan would re-enter a replay whose budget state is
        // unknown — the one thing the bound cannot tolerate.
        nextLaunchOnlyRecoveryIDs.insert(id)
      default:
        break
      }
      // #1464: the coordinator is the sole destructor — the replayer no longer
      // deletes, so apply the replay predicate now that `replay()` has returned.
      // (`.aborted` deletes nothing here: `discardActiveRecovery` already did.)
      let willDelete = Self.shouldDeleteAfterReplay(outcome)
      // #1762: outcome AND disposition on one line. Disposition is the half that
      // was impossible to read from disk — a spool that is gone tells you nothing
      // about whether it was recovered or given up on.
      // #1762 r2: `.aborted` returns false from the predicate because
      // `discardActiveRecovery` ALREADY deleted — "keeping" was factually wrong
      // and told the reader discarded audio was still on disk.
      let disposition: String
      switch outcome {
      case .aborted: disposition = "Discard already requested deletion"
      default: disposition = willDelete ? "requesting deletion" : "keeping"
      }
      RecoveryLog.line("replay \(Self.logLabel(outcome)) — \(disposition)")
      // #1807 (§C): recheck the live-armed protection set fresh, after the
      // `await replayer.replay(...)` suspension above — an orphan's id
      // reusing a freshly-armed live session's id is not a real occurrence
      // (fresh UUIDs per arm), but a direct destroy here must still defer to
      // that session's own join rather than racing it, on the same recheck
      // discipline the scan's dedup loop above follows.
      if willDelete, !protectedSessionIDs.contains(id) {
        destroySpoolAndKey(id: id, source: .replayOutcome)
      }
      // Post the standalone success notice for a recording that landed in History.
      if case .recovered = outcome { onRecoverySucceeded?() }
      // A Discard ends the whole hold; remaining orphans (rare) wait for the next
      // launch/rescan. Every other outcome continues to the next orphan.
      if outcome == .aborted { break }
    }
    // GitHub cloud review, PR #1732: a live-start signal that arrived during
    // the LAST item's replay (or the discard `break` above) has no further
    // loop iteration left to catch it at the top-of-loop guard — check once
    // more here. Confirmed by reproduction (not just reasoning): without this
    // check, a `pendingRescan` that ALSO gets set during that same window (an
    // unrelated wake-up cause, coalesced since a scan is already in progress)
    // makes `drainPendingRescan()` immediately run another pass; if the
    // retained item's own rediscovery keeps re-triggering the same wake-up
    // cause, this is not just a stranded signal but a genuine infinite loop
    // (reproduced via `pendingLiveStartYieldsAfterFinalItem`, which hangs
    // without this line).
    if pendingLiveStartSignal { return true }
    return false
  }

  /// The user pressed Discard on the recovering pill. No-op when nothing is
  /// actively recovering. (#1063 PR2.)
  ///
  /// 1. Bump `recoveryGeneration` so the in-flight replay's post-`await` check
  ///    drops its result (no stale "Recovered" save).
  /// 2. `resetEngine()` — hard-reset the shared engine (the #445 service-kill). For
  ///    the default out-of-process engine this KILLS the in-flight (otherwise
  ///    uncancellable) load/transcribe, so the replay returns `.aborted` almost
  ///    immediately — Discard works even against a wedge (founder fix).
  /// 3. Delete the orphan the user discarded (spool + key + marker).
  ///
  /// It does NOT clear `isRecovering` directly (Codex code-diff r6 P2): the gate is
  /// released by the scan loop's `defer` when the replay RETURNS — i.e. once the
  /// engine is genuinely free. For the out-of-process engine that is ~instant (the
  /// reset killed the call). For the IN-PROCESS engine, `cancelInFlightLoad` cannot
  /// stop a running Core ML transcribe, so the call finishes (a few seconds) before
  /// the gate opens — preventing a new recording from contending with it. Either
  /// way the gate opens exactly when the shared engine is actually free.
  func discardActiveRecovery() {
    guard isRecovering, let id = activeRecoveryID else { return }
    recoveryGeneration &+= 1
    resetEngine()
    // Route through the sole destructor (#1464). The post-replay predicate sees
    // `.aborted` for this id and does NO second delete.
    destroySpoolAndKey(id: id, source: .userDiscard)
    activeRecoveryID = nil
    TelemetryService.shared.recoveryCompleted(outcome: "discarded")
  }
}

// MARK: - Sentry identity

/// Pins the single case's Sentry grouping key to the exact pre-migration
/// string measured while the nested type remained genuinely `private`
/// (#1525 PR C), mirroring `HeartPathError`'s shipped pattern. The
/// pre-migration 90-day Sentry cross-check found no matching issue, so no
/// live title was available as a second source for this case.
extension RecoveryCoordinator.RecoveryArmError: StableSentryErrorIdentity {
  var sentryFingerprintDescriptor: String { "RecoveryArmError#0" }
  var sentrySemanticID: String { "recovery.arm_key_store_failed" }
}
