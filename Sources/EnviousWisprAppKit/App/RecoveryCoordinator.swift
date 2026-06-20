import EnviousWisprCore
import EnviousWisprServices
import EnviousWisprStorage
import Foundation

/// Host-side owner of the crash-recovery limb (#1063 PR1).
///
/// Responsibilities in PR1:
/// - **Arm** a recording: mint a durable per-recording id, generate + DURABLY
///   store the per-session key, snapshot record-time settings, and produce the
///   opaque directive the audio helper writes the encrypted spool from.
/// - **Clean up on success:** once a recording's transcript is durably saved,
///   delete that session's spool file + key.
/// - **Purge on launch:** sweep every orphan spool + key (PR1 does NOT recover
///   yet — that lands PR2; purging keeps zero recoverable audio on disk so
///   shipping PR1 before PR2 leaks nothing).
///
/// It is a strict LIMB: every path fails open (returns nil / best-effort delete)
/// and never touches the heart path. Bootstrapper-owned, a sibling of
/// `DiagnosticsCoordinator`. Not `@Observable` in PR1 — it has no view-facing
/// state until the PR2 recovery banner.
@MainActor
final class RecoveryCoordinator {
  private let keyStore: RecoveryKeyStore
  /// Factory for a `RecoverySpoolStore` — constructing one prepares the spool
  /// directory (0700, Spotlight/backup-excluded), so we make a fresh value at
  /// each use rather than hold one. Injectable for tests.
  private let makeSpoolStore: @Sendable () -> RecoverySpoolStore
  /// The recovery session armed for the CURRENT recording, or nil. Set BEFORE
  /// the directive's key is durably stored (so the launch purge can never delete
  /// a key it snapshots mid-arm); cleared if that store fails, when the session's
  /// spool + key are deleted (durable save), or when the recording ends WITHOUT a
  /// durable save. Lets the non-saved-terminal cleanup target the live session
  /// and lets the launch purge protect it from a concurrent-arm race. MainActor-confined
  /// (sequential recordings — one kernel FSM — so a single slot suffices; the
  /// rare concurrent double-arm is backstopped by the launch purge). (#1063 PR1.)
  private var armedSessionID: String?

  init(
    keyStore: RecoveryKeyStore = RecoveryKeyStore(),
    makeSpoolStore: @escaping @Sendable () -> RecoverySpoolStore = { RecoverySpoolStore() }
  ) {
    self.keyStore = keyStore
    self.makeSpoolStore = makeSpoolStore
  }

  private enum RecoveryArmError: Error { case keyStoreFailed }

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

    let resolvedModel: String = {
      switch settings.llmProvider {
      case .appleIntelligence: return "apple-intelligence"
      case .ollama: return settings.ollamaModel
      default: return settings.llmModel
      }
    }()
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

    // Protect this id from the launch purge BEFORE the key can land on disk.
    // Ordering invariant: `armedSessionID` is set (synchronously, on the
    // MainActor) no later than the key hits disk. The purge reads `armed` AFTER
    // snapshotting the on-disk keys, so any key it could have snapshotted was
    // stored after this assignment and is therefore already protected — closing
    // the mid-arm gap where a purge snapshot saw the key but a nil `armed`
    // (Codex code-diff r4 P2). Cleared below if the durable store fails.
    // (A concurrent double-arm overwrites this; the loser's key is an orphan the
    // launch purge sweeps — harmless in PR1, no recovery.)
    armedSessionID = recoverySessionID

    // Durably store the key off the MainActor BEFORE returning an enabled
    // payload. Fail-open: a store failure disables recovery for this take.
    let keyStore = self.keyStore
    let stored: Bool = await Task.detached(priority: .utility) {
      (try? keyStore.store(keyData: keyData, for: recoverySessionID)) != nil
    }.value
    guard stored else {
      // No durable key landed — un-protect so the purge isn't guarding a phantom
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

  /// A recording's transcript was durably saved — delete that session's spool +
  /// key. Best-effort, off the user's path, idempotent. Returns the detached
  /// work so tests can await it; callers discard it.
  @discardableResult
  func handleDurableSave(recoverySessionID id: String) -> Task<Void, Never> {
    if armedSessionID == id { armedSessionID = nil }
    let keyStore = self.keyStore
    let makeSpoolStore = self.makeSpoolStore
    return Task.detached(priority: .utility) {
      try? makeSpoolStore().delete(recoverySessionID: id)
      try? keyStore.delete(for: id)
    }
  }

  /// A recording ended WITHOUT a durable transcript save — cancel, no-speech,
  /// too-short discard, pipeline error, helper-crash-while-app-alive, or a
  /// pre-session abort after the key was armed. The app is ALIVE, so this is NOT
  /// a crash orphan (a real crash kills the app before this can run, leaving the
  /// spool for the launch purge / PR2 recovery); delete the armed spool + key
  /// NOW instead of letting non-saved recordings accumulate on a long-running
  /// menu-bar app. Idempotent + best-effort; a no-op when nothing is armed.
  /// Returns the detached work so tests can await it. (#1063 PR1, Codex r3 P1.)
  @discardableResult
  func handleRecordingEndedWithoutDurableSave() -> Task<Void, Never>? {
    guard let id = armedSessionID else { return nil }
    armedSessionID = nil
    let keyStore = self.keyStore
    let makeSpoolStore = self.makeSpoolStore
    return Task.detached(priority: .utility) {
      try? makeSpoolStore().delete(recoverySessionID: id)
      try? keyStore.delete(for: id)
    }
  }

  /// On launch, purge every orphan spool + key. PR1 does NOT recover — purging
  /// guarantees no recoverable audio is left on disk. (PR2 replaces this with
  /// scan → recover → save → delete.) Returns the detached work so tests can
  /// await it; callers discard it.
  @discardableResult
  func purgeOrphansOnLaunch() -> Task<Void, Never> {
    let keyStore = self.keyStore
    let makeSpoolStore = self.makeSpoolStore
    return Task.detached(priority: .utility) { [weak self] in
      let store = makeSpoolStore()
      // Snapshot the orphan set UP FRONT — both the spool ids and the key
      // account ids — before deleting anything. A recording that arms
      // concurrently with this fire-and-forget purge mints a fresh UUID +
      // stores its key; snapshotting first means the deletion can never catch
      // a key armed AFTER the snapshot (Codex code-diff r2 P1). PR1 recovers
      // nothing, so every spool present now is an orphan, and `keyIDs` already
      // covers every armed key (one per spool) PLUS any orphan key with no
      // spool — e.g. a recording that armed then aborted before the first frame.
      let spoolIDs = (try? store.listSpoolSessionIDs()) ?? []
      let keyIDs = keyStore.listAccountIDs()
      // Hotkeys go live BEFORE this purge (it is fire-and-forget), so a recording
      // can arm in the snapshot window with its key already in `keyIDs`. Read the
      // live armed id (set on the MainActor in `makeDirective`) AFTER snapshotting
      // and PROTECT it — deleting a live key would make its spool unrecoverable
      // (Codex code-diff r3 P2). A recording armed after this read is excluded
      // from the snapshots already.
      let armed = await MainActor.run { self?.armedSessionID }
      for id in spoolIDs where id != armed {
        try? store.delete(recoverySessionID: id)
      }
      for id in keyIDs where id != armed {
        try? keyStore.delete(for: id)
      }
    }
  }
}
