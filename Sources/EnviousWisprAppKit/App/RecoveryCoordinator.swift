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
///   narrow `RecordingRecoveryEnding` — discard / no-speech / user-cancel delete
///   now; a fault ending (pipeline / audio / engine / system-cancel) RETAINS the
///   spool so the audio is recovered on the next launch.
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

  /// #1707 Phase 3 (§3.2) — `EngineRecoveryGate.tryBeginRecovery()`/
  /// `endRecovery()`, injected by the composition root exactly like
  /// `isEngineSwitching` above (this type never references `EngineRecoveryGate`
  /// by concrete type, matching the existing closure-injection convention).
  /// `RecoveryCoordinator` is the SOLE owner of these calls — `RecoverySpool
  /// Replayer` runs entirely underneath the already-held claim and never calls
  /// them itself. Defaults keep every existing test that doesn't wire a gate
  /// behaving as before (always able to claim).
  var tryBeginRecoveryClaim: () -> Bool = { true }
  var endRecoveryClaim: () -> Void = {}

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

  /// #1707 Phase 3 (§3.3) — ids that must wait for a genuinely NEW launch
  /// rather than any same-launch rescan. Three populations: (1) an attempt-
  /// marker clear that FAILED after a deferred outcome (Keychain-transient or
  /// a History-save failure DURING REPLAY) — a surviving marker would be
  /// misread by a same-launch rescan as a crashed attempt (the crash-loop
  /// guard's "marker present ⇒ abandoned" reasoning only holds for a
  /// genuinely new launch); (2) a LIVE recording's own RETAINED failure
  /// ending (GitHub cloud review, PR #1732 round 1) — the engine may still be
  /// in the exact broken state that produced the failure; (3) a LIVE
  /// recording that reached `.complete` but whose History save failed (PR
  /// #1732 round 6) — `onDurableSave` never fires for this case (nothing to
  /// delete), but the same terminal transition's own wake-up must not
  /// immediately re-attempt (and potentially delete) the spool this failure
  /// just retained. Every same-launch pass skips these ids, leaving them
  /// untouched on disk for a future launch's fresh `RecoveryCoordinator`
  /// instance (which always starts empty). NEVER cleared during one
  /// instance's lifetime; tests model "a new launch" by constructing a new
  /// coordinator, never by clearing this set on an existing one.
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
    resetEngine: @escaping @MainActor () -> Void = {}
  ) {
    self.keyStore = keyStore
    self.makeSpoolStore = makeSpoolStore
    self.replayer = replayer
    self.existingRecoveryIDs = existingRecoveryIDs
    self.isDictationActive = isDictationActive
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

  /// The SOLE spool+key destructor (#1464). Deletes the spool file (which also
  /// clears its attempt marker) SYNCHRONOUSLY — it is cheap local FS, and a
  /// follow-up scan / the dedup + discard callers must see it gone at once — then
  /// destroys the per-session key OFF the MainActor (the key store can be securityd
  /// IPC, `keychain-not-mainactor`). Best-effort + idempotent (`try?`), so a
  /// double-delete or a concurrently-removed spool is a harmless no-op. Returns the
  /// detached key-delete work so tests can await completion; callers may discard it.
  @discardableResult
  private func destroySpoolAndKey(id: String) -> Task<Void, Never> {
    try? makeSpoolStore().delete(recoverySessionID: id)
    let keyStore = self.keyStore
    return Task.detached(priority: .utility) {
      try? keyStore.delete(for: id)
    }
  }

  /// Delete-versus-retain for a live recording that ended without a durable save
  /// (#1464). Reproduces the former driver `endedWithoutSaveKind` mapping EXACTLY:
  /// delete when there is nothing worth keeping (discard / no-speech) or the user
  /// asked to drop it; RETAIN when the captured audio is the user's words a fault
  /// cut short. Static + internal so the split is unit-tested directly
  /// (`matcher-set-adversarial-tests`).
  static func shouldDeleteOnLiveEnding(_ ending: RecordingRecoveryEnding) -> Bool {
    switch ending {
    case .discarded, .noSpeech, .asrRetryExhausted:
      return true
    case .failed, .audioInterrupted, .asrInterrupted, .noTransport:
      return false
    case .cancelled(.user):
      return true
    case .cancelled(.systemOrFault):
      return false
    }
  }

  /// Delete-versus-retain after a launch replay attempt (#1464). Delete a recovered
  /// (saved) or unrecoverable orphan and a crash-loop `.abandoned` one; RETAIN a
  /// History-save failure (the audio is still good, §3.3). `.aborted` (the user
  /// discarded — already deleted by `discardActiveRecovery`), `.deferred` (the
  /// marker was never written — keep for a future launch), and #1707 Phase 3's
  /// `.deferredMarkerClearFailed` (Keychain-transient, marker survives — keep for
  /// a future launch) delete nothing here. Static + internal for direct
  /// adversarial testing.
  static func shouldDeleteAfterReplay(_ outcome: RecoveryReplayOutcome) -> Bool {
    switch outcome {
    case .recovered, .abandoned:
      return true
    case .failed(.unrecoverable):
      return true
    case .failed(.save), .failed(.saveMarkerClearFailed):
      return false
    case .aborted, .deferred, .deferredMarkerClearFailed:
      return false
    }
  }

  /// A recording's transcript was durably saved — delete that session's spool +
  /// key. Best-effort, off the user's path, idempotent. Returns the detached
  /// work so tests can await it; callers discard it.
  @discardableResult
  func handleDurableSave(recoverySessionID id: String) -> Task<Void, Never> {
    if armedSessionID == id { armedSessionID = nil }
    return destroySpoolAndKey(id: id)
  }

  /// A `.complete` dictation whose History save FAILED (GitHub cloud review,
  /// PR #1732 round 6): `onDurableSave` never fires for this case (correctly
  /// — nothing to delete, the spool must be retained), but this session's own
  /// terminal transition ALSO fires `onDictationEndedForRecovery` moments
  /// later via the SAME synchronous `fireStateChangeIfNeeded()` call that
  /// dispatches to the caller of this method first — without this
  /// suppression, that same-launch wake-up could immediately rescan and
  /// destructively replay the spool this failure meant to retain for a
  /// healthier future launch, exactly like the live-failure-ending case this
  /// mirrors. No-op when `id` is nil (armed only when recovery was on for
  /// this take).
  func suppressUntilNextLaunch(recoverySessionID id: String?) {
    guard let id else { return }
    nextLaunchOnlyRecoveryIDs.insert(id)
  }

  /// A recording ended at a terminal state WITHOUT a durable transcript save
  /// (#1063 PR2 / #1464). Applies `shouldDeleteOnLiveEnding` to the narrow
  /// `RecordingRecoveryEnding` the driver projected: a delete ending (discard /
  /// no-speech / user-cancel) destroys the spool + key now; a retain ending
  /// (pipeline / audio / engine / system-cancel) keeps it for the next launch.
  /// Idempotent + best-effort; a no-op when `id` is nil. Always clears the live-
  /// recording protection (the recording is over). Returns the detached delete
  /// work (delete endings only) so tests can await it.
  ///
  /// A retain ending ALSO defers this id to `nextLaunchOnlyRecoveryIDs`
  /// (GitHub cloud review, PR #1732): this same session's own
  /// `onDictationEndedForRecovery` wake-up fires right after this call and
  /// requests a same-launch rescan — without this, that rescan could pick up
  /// the spool just retained here while the engine is still in the exact
  /// state that produced the failure, replay it, classify it
  /// `.failed(.unrecoverable)`, and delete the very audio this branch meant
  /// to keep for a healthier future launch. Runs before that rescan Task is
  /// even scheduled (both synchronous MainActor calls from the same driver
  /// callback), so the exclusion is always in place before the pass runs.
  @discardableResult
  func handleRecordingEndedWithoutDurableSave(
    recoverySessionID id: String?, ending: RecordingRecoveryEnding
  ) -> Task<Void, Never>? {
    guard let id else { return nil }
    if armedSessionID == id { armedSessionID = nil }
    guard Self.shouldDeleteOnLiveEnding(ending) else {
      nextLaunchOnlyRecoveryIDs.insert(id)
      return nil
    }
    return destroySpoolAndKey(id: id)
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
    return destroySpoolAndKey(id: id)
  }

  /// On launch, scan for orphan spools and recover them (#1063 PR2 — replaces
  /// PR1's purge). Single-flight via the same owning drain loop
  /// `requestRecoveryRecheck()` uses (#1707 Phase 3, §3.4) — a concurrent call
  /// coalesces into a follow-up pass rather than running twice.
  func scanAndRecover() async {
    pendingRescan = true
    guard !scanInProgress else { return }
    scanInProgress = true
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
    guard !scanInProgress else { return }
    scanInProgress = true
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
    while pendingRescan {
      pendingRescan = false
      let yieldedToLiveStart = await runOneScanPass()
      if yieldedToLiveStart {
        pendingRescan = false
        return
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
      return false
    }
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
        destroySpoolAndKey(id: id)
      } else {
        recoverable.append(id)
      }
    }
    guard !recoverable.isEmpty else { return false }

    // #1707 Phase 3 (§3.3): skip ids whose marker-clear failure means only a
    // genuinely NEW launch may safely re-check them — they stay on disk,
    // untouched, waiting for a future launch's fresh coordinator instance.
    let attemptable = recoverable.filter { !nextLaunchOnlyRecoveryIDs.contains($0) }
    guard !attemptable.isEmpty else { return false }

    TelemetryService.shared.recoveryFound(count: attemptable.count)
    // #1707 Phase 3 (§3.1): cleared once per fresh pass — a live-start refusal
    // observed DURING this pass (between items, below) still yields the
    // engine; a refusal from a PRIOR pass must not spuriously yield this one.
    pendingLiveStartSignal = false

    for id in attemptable {
      // Atomic per-item handshake (§3.1/§3.2) — ONE non-suspending MainActor
      // turn: checked and claimed here with no `await` between any step, so
      // there is no window between "checked" and "acted." Preserves the
      // existing switch symmetry exactly: a switch already in progress makes
      // recovery defer here; once `isRecovering` is set below, a NEW switch
      // cannot begin (`EngineCoordinator` already checks it).
      guard !pendingLiveStartSignal else { return true }
      // Contention guard: never run the shared engine while a live dictation is
      // in flight (a recording can start in the launch window, including with
      // recovery OFF) OR while an engine switch is in flight (#1171 — a switch
      // unloads/sets the active engine; starting recovery on top would race the
      // shared engine). Defer the remaining orphans — they stay on disk.
      guard !isDictationActive(), !isEngineSwitching() else { return false }
      guard tryBeginRecoveryClaim() else {
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
        endRecoveryClaim()
        onRecoveryComplete?()
      }
      let outcome = await replayer.replay(recoverySessionID: id) { [weak self] in
        // Discard bumps `recoveryGeneration`; a mismatch ⇒ abandon this in-flight
        // replay. Coordinator gone ⇒ treat as aborted (safe).
        self?.recoveryGeneration != generationAtStart
      }
      // #1707 Phase 3 (§3.3): a marker-clear failure under either deferred
      // outcome means only a genuinely new launch may safely re-check this id.
      switch outcome {
      case .deferredMarkerClearFailed, .failed(.saveMarkerClearFailed):
        nextLaunchOnlyRecoveryIDs.insert(id)
      default:
        break
      }
      // #1464: the coordinator is the sole destructor — the replayer no longer
      // deletes, so apply the replay predicate now that `replay()` has returned.
      // (`.aborted` deletes nothing here: `discardActiveRecovery` already did.)
      if Self.shouldDeleteAfterReplay(outcome) { destroySpoolAndKey(id: id) }
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
    destroySpoolAndKey(id: id)
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
