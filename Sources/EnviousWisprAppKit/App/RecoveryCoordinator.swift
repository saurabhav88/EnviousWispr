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

  /// True while the launch scan is replaying orphans behind the blocking pill.
  /// DRIVES the recording gate: a record-press while true mints no session (shows
  /// the "recovering" pill). `private(set)` — only the scan/discard own it, and a
  /// `defer` guarantees it clears on EVERY scan exit (a stuck `true` would brick
  /// recording). Read by the gate via an injected closure.
  private(set) var isRecovering = false

  /// #1171 — fired after a recovery scan finishes AND `isRecovering` has cleared
  /// (registered as a `defer` AFTER the `isRecovering = false` defer, so LIFO runs
  /// it second). Lets the composition root poke `EngineCoordinator` so an engine
  /// switch deferred because it arrived while recovery held the shared engine
  /// applies now. Set by the root.
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

  /// Monotonic token bumped by `discardActiveRecovery()`. The replayer captures
  /// it per orphan and re-checks after every `await`: a mismatch means "discarded
  /// while my uncancellable batch transcribe was in flight" → drop the result,
  /// save nothing. The concrete mechanism behind Discard (batch transcribe has no
  /// cancel API). MainActor-confined.
  private var recoveryGeneration = 0

  /// The orphan id currently being replayed, so Discard can delete exactly the
  /// recording the user is waiting on. nil when the scan is between orphans.
  private var activeRecoveryID: String?

  /// Single-flight guard so a re-trigger of `scanAndRecover()` can't double-run.
  private var scanInProgress = false

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
  /// discarded — already deleted by `discardActiveRecovery`) and `.deferred` (the
  /// marker was never written — keep for a future launch) delete nothing here.
  /// Static + internal for direct adversarial testing.
  static func shouldDeleteAfterReplay(_ outcome: RecoveryReplayOutcome) -> Bool {
    switch outcome {
    case .recovered, .abandoned:
      return true
    case .failed(.unrecoverable):
      return true
    case .failed(.save), .failed(.saveMarkerClearFailed):
      return false
    case .aborted, .deferred:
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

  /// A recording ended at a terminal state WITHOUT a durable transcript save
  /// (#1063 PR2 / #1464). Applies `shouldDeleteOnLiveEnding` to the narrow
  /// `RecordingRecoveryEnding` the driver projected: a delete ending (discard /
  /// no-speech / user-cancel) destroys the spool + key now; a retain ending
  /// (pipeline / audio / engine / system-cancel) keeps it for the next launch.
  /// Idempotent + best-effort; a no-op when `id` is nil. Always clears the live-
  /// recording protection (the recording is over). Returns the detached delete
  /// work (delete endings only) so tests can await it.
  @discardableResult
  func handleRecordingEndedWithoutDurableSave(
    recoverySessionID id: String?, ending: RecordingRecoveryEnding
  ) -> Task<Void, Never>? {
    guard let id else { return nil }
    if armedSessionID == id { armedSessionID = nil }
    guard Self.shouldDeleteOnLiveEnding(ending) else { return nil }
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

  /// On launch, scan for orphan spools and recover them behind the blocking pill
  /// (#1063 PR2 — replaces PR1's purge). Single-flight. Sequential. One attempt
  /// per orphan. Strict limb: fails open at every step.
  func scanAndRecover() async {
    guard !scanInProgress else { return }
    scanInProgress = true
    defer { scanInProgress = false }

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
      return
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

    guard !spoolIDs.isEmpty else { return }

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
    guard !recoverable.isEmpty else { return }

    // Contention guard: never run the shared engine while a live dictation is in
    // flight (a recording can start in the launch window, including with recovery
    // OFF) OR while an engine switch is in flight (#1171 — a switch unloads/sets
    // the active engine; starting recovery on top would race the shared engine).
    // Defer the orphans to a future launch — they stay on disk.
    guard !isDictationActive(), !isEngineSwitching() else { return }

    TelemetryService.shared.recoveryFound(count: recoverable.count)
    isRecovering = true
    // #1171 — registered BEFORE the `isRecovering = false` defer so LIFO runs this
    // SECOND (after the flag clears): the deferred-switch retry it triggers sees
    // `isRecovering == false` and can apply. Only fires when recovery actually ran.
    defer { onRecoveryComplete?() }
    // R1 (Codex REV-2, BLOCKER): clear the gate on EVERY exit — normal completion,
    // a thrown error, or an early return. A stuck `isRecovering = true` would
    // refuse every record-start and brick the heart path.
    defer { isRecovering = false }

    for id in recoverable {
      activeRecoveryID = id
      let generationAtStart = recoveryGeneration
      let outcome = await replayer.replay(recoverySessionID: id) { [weak self] in
        // Discard bumps `recoveryGeneration`; a mismatch ⇒ abandon this in-flight
        // replay. Coordinator gone ⇒ treat as aborted (safe).
        self?.recoveryGeneration != generationAtStart
      }
      activeRecoveryID = nil
      // #1464: the coordinator is the sole destructor — the replayer no longer
      // deletes, so apply the replay predicate now that `replay()` has returned.
      // (`.aborted` deletes nothing here: `discardActiveRecovery` already did.)
      if Self.shouldDeleteAfterReplay(outcome) { destroySpoolAndKey(id: id) }
      // Post the standalone success notice for a recording that landed in History.
      if case .recovered = outcome { onRecoverySucceeded?() }
      // A Discard ends the whole hold; remaining orphans (rare) wait for the next
      // launch. Every other outcome continues to the next orphan.
      if outcome == .aborted { break }
    }
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
