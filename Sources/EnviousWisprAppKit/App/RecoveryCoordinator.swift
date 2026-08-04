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
  /// `armedSessionID` alone wouldn't catch it). Recovery never runs the shared
  /// engine while this is true; it defers to a future launch.
  private let isDictationActive: @MainActor () -> Bool

  /// The recovery session armed for the CURRENT recording, or nil. Set BEFORE
  /// the directive's key is durably stored (so the launch scan can never delete a
  /// key it snapshots mid-arm); cleared if that store fails, on durable save, or
  /// when the recording ends without a durable save. Its remaining job in PR2 is
  /// to let the launch scan PROTECT a live in-progress recording from a
  /// concurrent-arm race. MainActor-confined.
  private var armedSessionID: String?

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
      useExtendedThinking: settings.useExtendedThinking)

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
    // Ordering invariant: `armedSessionID` is set (synchronously, on the
    // MainActor) no later than the key hits disk. The scan reads `armed` AFTER
    // snapshotting the on-disk spools, so any spool it could have snapshotted was
    // armed before this assignment and is therefore already protected — closing
    // the mid-arm gap (Codex code-diff r4 P2). Cleared below if the durable store
    // fails. (A concurrent double-arm overwrites this; the loser's key is an
    // orphan a future launch scan recovers or sweeps — harmless.)
    armedSessionID = recoverySessionID

    // Durably store the key off the MainActor BEFORE returning an enabled
    // payload. Fail-open: a store failure disables recovery for this take.
    let keyStore = self.keyStore
    let stored: Bool = await Task.detached(priority: .utility) {
      (try? keyStore.store(keyData: keyData, for: recoverySessionID)) != nil
    }.value
    guard stored else {
      // No durable key landed — un-protect so the scan isn't guarding a phantom
      // and a later non-saved cleanup is a no-op. Guard the id in case a
      // concurrent arm overwrote the slot (won't happen with sequential
      // recordings, but keeps the clear precise).
      if armedSessionID == recoverySessionID { armedSessionID = nil }
      SentryBreadcrumb.captureError(
        RecoveryArmError.keyStoreFailed, category: .recoveryKeyStoreFailed, stage: "recording",
        extra: ["backend": backendType.rawValue])
      return nil
    }

    return (recoverySessionID, payload)
  }

  /// #1755 chunk 4 — fixed, low-cardinality labels for WHY a destruction ran.
  /// Closed enum: no caller-supplied strings, no configurability.
  private enum DestructionSource: String {
    case durableSave = "durable_save"
    case liveEnding = "live_ending"
    case preStartAbort = "pre_start_abort"
    case historyDedup = "history_dedup"
    case replayOutcome = "replay_outcome"
    case userDiscard = "user_discard"
    /// #1740: a live `.complete` dictation whose History write failed.
    case historySaveFailed = "history_save_failed"
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
  private func emitDeletionFailed(component: String, source: DestructionSource) {
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
    case .replayOutcome, .historySaveFailed:
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
  private func destroySpoolAndKey(id: String, source: DestructionSource) -> Task<Void, Never> {
    #if DEBUG
      // #1755 chunk 6: crash-boundary hold — immediately before the spool
      // attempt (seam or real store). Unarmed: no-op.
      crashBoundaryController.boundaryReached(.beforeSpoolDelete)
    #endif
    do {
      if let override = destructionSpoolDeleteForTesting {
        try override(id)
      } else {
        try makeSpoolStore().delete(recoverySessionID: id)
      }
      emitCleanupOutcome(component: "spool", source: source, succeeded: true)
    } catch {
      emitDeletionFailed(component: "spool", source: source)
      emitCleanupOutcome(component: "spool", source: source, succeeded: false)
    }
    // Key deletion ALWAYS runs, detached, even after a spool failure.
    let keyStore = self.keyStore
    let keyOverride = destructionKeyDeleteForTesting
    // Capture self STRONGLY: the failure breadcrumb must survive coordinator
    // deallocation racing the detached delete (a weak capture silently
    // dropped it). The task is short-lived; the temporary strong retention
    // ends when the task completes.
    #if DEBUG
      let crashBoundaryController = self.crashBoundaryController
    #endif
    return Task.detached(priority: .utility) {
      #if DEBUG
        // #1755 chunk 6: crash-boundary hold — immediately before the key
        // attempt. While destruction_api_return is armed this call GATES
        // (parks without publishing) so the caller-side hook can prove the
        // live-ending API returned first.
        crashBoundaryController.boundaryReached(.beforeKeyDelete)
      #endif
      do {
        if let keyOverride {
          try keyOverride(id)
        } else {
          try keyStore.delete(for: id)
        }
        await MainActor.run {
          self.emitCleanupOutcome(component: "key", source: source, succeeded: true)
        }
      } catch {
        await MainActor.run {
          self.emitDeletionFailed(component: "key", source: source)
          self.emitCleanupOutcome(component: "key", source: source, succeeded: false)
        }
      }
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
    case .cancelled(.user):
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
    case .deferred, .deferredMarkerClearFailed:
      // ASR never ran, so the attempt is unspent. `.deferredMarkerClearFailed`
      // is the transient-Keychain case #1360 closed — never treat it as a
      // permanent deletion trigger.
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
    }
  }

  /// A recording's transcript was durably saved — delete that session's spool +
  /// key. Best-effort, off the user's path, idempotent. Returns the detached
  /// work so tests can await it; callers discard it.
  @discardableResult
  func handleDurableSave(recoverySessionID id: String) -> Task<Void, Never> {
    if armedSessionID == id { armedSessionID = nil }
    return destroySpoolAndKey(id: id, source: .durableSave)
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
  /// NOTE: unlike launch replay, this spool carries NO attempt marker — no
  /// replay ever ran for it. If deletion fails, a later launch gives it its
  /// FIRST crash-recovery attempt, which is consistent with the one-attempt
  /// rule. No-op when `id` is nil (armed only when recovery was on).
  @discardableResult
  func handleHistorySaveFailed(recoverySessionID id: String?) -> Task<Void, Never>? {
    guard let id else { return nil }
    if armedSessionID == id { armedSessionID = nil }
    nextLaunchOnlyRecoveryIDs.insert(id)
    return destroySpoolAndKey(id: id, source: .historySaveFailed)
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
    if armedSessionID == id { armedSessionID = nil }
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
      return nil
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
    return destroySpoolAndKey(id: id, source: .liveEnding)
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
    if armedSessionID == id { armedSessionID = nil }
    return destroySpoolAndKey(id: id, source: .preStartAbort)
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
    let armed = armedSessionID

    // Sweep KEY-ONLY orphans first: a key whose spool was never written — a
    // recording that armed then crashed before the helper wrote the first frame.
    // The spool scan can't see these (no `.ewrec` file), so without this they leak
    // a recovery key forever; the PR1 launch purge swept them via `listAccountIDs`
    // (Codex code-diff P2). Off-MainActor (`keychain-not-mainactor`); excludes
    // every id that DOES have a spool (deduped or recovered below, and still needs
    // its key to decrypt). Runs even when there are zero spools.
    //
    // Race-safe ordering (Codex code-diff r2 + r4 P2): inside the detached task,
    // snapshot the keys FIRST, then read the live armed id AND re-list the spools
    // FRESH (not the scan-start `spoolIDs` snapshot). Three protections, each read
    // as late as possible so it sees the most recent state:
    //   - a key armed AFTER the key snapshot can't be in `keyIDs` (stored later);
    //   - a currently-arming take is caught by the freshly-read `liveArmed`;
    //   - a take that armed AND ENDED at a FAILURE terminal after the scan snapshot
    //     RETAINS its spool — re-listing spools fresh sees that spool, so its key is
    //     NOT swept (the stale scan-start snapshot would have missed it and deleted
    //     the key, making that recording undecryptable — r4 P2).
    // Only a key with NO spool now (and not live-armed) is a true key-only orphan.
    let keyStore = self.keyStore
    let makeSpoolStore = self.makeSpoolStore
    Task.detached(priority: .utility) { [weak self] in
      let keyIDs = keyStore.listAccountIDs()
      let liveArmed = await MainActor.run { self?.armedSessionID }
      // Fail CLOSED if the fresh re-list errors (Codex code-diff r5 P2): treating
      // an IO/permission error as "no spools" would delete keys for real `.ewrec`
      // files. Abort the sweep instead — same discipline as the scan-start list.
      guard let currentSpoolList = try? makeSpoolStore().listSpoolSessionIDs() else { return }
      let currentSpools = Set(currentSpoolList)
      for id in keyIDs where id != liveArmed && !currentSpools.contains(id) {
        try? keyStore.delete(for: id)
      }
    }

    guard !spoolIDs.isEmpty else { return false }

    // Snapshot the History dedup set. A recording that arms during the dedup
    // `await` mints a fresh UUID not in `spoolIDs` (listed above) — already
    // excluded; the contention guard below is the backstop.
    let alreadySaved = await existingRecoveryIDs()

    var recoverable: [String] = []
    for id in spoolIDs where id != armed {
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
      case .deferredMarkerClearFailed:
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
      if willDelete {
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
