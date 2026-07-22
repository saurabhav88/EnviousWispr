import Foundation

/// States in the WhisperKit model setup flow.
public enum WhisperKitSetupState: Equatable {
  case checking  // initial detection
  case notDownloaded  // model not on disk
  case downloading(progress: Double, status: String)  // actively downloading
  /// Cancelled mid-download with resumable partials on disk (founder ruling
  /// 2026-07-17: mirror the Parakeet row — paused, Resume anytime; the shared
  /// controller keeps the staging partials either way).
  case paused
  case ready  // model cached locally, ready to use
  case error(String)
}

/// 2c: the Remove press's inline outcome, rendered in the Settings row that
/// owns the button (never an overlay — gotchas-audio RULE:
/// in-panel-notice-not-new-overlay-intent).
public enum WhisperKitRemoveNotice: Equatable {
  /// Founder ruling 2.5.4: Remove REFUSES during a dictation — no defer, no
  /// queue; the user presses again after the dictation ends.
  case refusedDictationInFlight
  case failed
}

/// Presents WhisperKit model setup in Settings. Downloads happen there — NEVER
/// auto-triggered on first record.
///
/// #1386 PR-2 hollowed this out. It used to own a `WhisperKit.download()` task
/// pointed at a folder we do not control, and treat a 3-artifact directory probe
/// as proof a model existed. Both are gone: availability is controller admission
/// alone, and fetching goes through the verified delivery path. What remains is
/// presentation — the same `downloadModel()` / `cancelDownload()` surface the
/// Settings view already calls, now delegating to injected actions so this type
/// holds no download task and no cache truth of its own.
@MainActor
@Observable
public final class WhisperKitSetupService {

  // MARK: - Public State

  public private(set) var setupState: WhisperKitSetupState = .checking

  /// Model variant. Source of truth: `WhisperKitBackend.defaultModelVariant()`.
  // BRAIN: gotcha id=model-name-format
  public let modelVariant: String = WhisperKitBackend.defaultModelVariant()

  /// Reads current availability: `.ready` when an admitted verified model exists,
  /// admission truth alone; a refused foreign copy is simply not an installed model.
  /// `.notDownloaded` otherwise. Injected by the composition root over the
  /// delivery handle + relocation coordinator — ASR imports neither Pipeline nor
  /// ModelDelivery, so the dependency arrives as a closure.
  private let readAvailability: @MainActor () async -> WhisperKitSetupState
  /// The explicit Download action (controller-backed). Returns whether the
  /// request was ACCEPTED — false means refused (kill switch off, no wiring)
  /// and no delivery state will ever arrive for it.
  private let startDownload: @MainActor () async -> Bool
  /// The explicit Cancel action (controller-backed; drains the active fetch).
  /// Returns whether the cancel was ACCEPTED — false means the coordinator
  /// refused it (a failed marker clear, L1) and the fetch is still running.
  private let cancelActiveDownload: @MainActor () async -> Bool
  /// 2c: the explicit Remove action. nil notice = removed; a notice = refused
  /// or failed, rendered inline.
  private let removeModelAction: @MainActor () async -> WhisperKitRemoveNotice?

  /// #1707 Phase 3 (§3.2, rows 9/10) / #1741 Chunk 4 — the mutation-side
  /// capability guarding Download/Cancel/Remove's engine-touching work, none
  /// of which routes through `ensureEngineWarm()`. Required at construction
  /// (no default) — replaces the old defaulted `tryBeginEngineMutation`/
  /// `endEngineMutation`/`wakeRecoveryIfOwed` closure triplet. `package`, not
  /// `public`: `EnviousWisprASR` is an exported library product and
  /// `EngineMutationScope` is itself only `package`-visible, so a wider
  /// property could not hold it.
  package let engineMutationScope: EngineMutationScope

  /// The default wiring reports "not downloaded" and does nothing: a build with
  /// no delivery wiring must offer no fetch at all rather than quietly resurrect
  /// an unverified one.
  package init(
    engineMutationScope: EngineMutationScope,
    readAvailability: @escaping @MainActor () async -> WhisperKitSetupState = { .notDownloaded },
    startDownload: @escaping @MainActor () async -> Bool = { false },
    cancelActiveDownload: @escaping @MainActor () async -> Bool = { false },
    removeModelAction: @escaping @MainActor () async -> WhisperKitRemoveNotice? = { .failed }
  ) {
    self.engineMutationScope = engineMutationScope
    self.readAvailability = readAvailability
    self.startDownload = startDownload
    self.cancelActiveDownload = cancelActiveDownload
    self.removeModelAction = removeModelAction
  }

  // MARK: - Detection

  private var lastDetectTime: Date?

  /// Refresh from delivery truth. Never downloads. Caches for 5s so tab switches
  /// do not re-ask on every appearance.
  public func detectState() async {
    if let lastTime = lastDetectTime,
      Date().timeIntervalSince(lastTime) < 5.0,
      setupState != .checking
    {
      return
    }
    setupState = .checking
    setupState = await readAvailability()
    lastDetectTime = Date()
  }

  /// Force a fresh state check, ignoring the cache.
  public func forceDetectState() async {
    lastDetectTime = nil
    await detectState()
  }

  /// Apply a delivery-state projection pushed by the composition root (the
  /// download's live progress). Kept separate from `detectState()` so a push
  /// never fights the 5s read cache.
  public func applyDeliveryState(_ state: WhisperKitSetupState) {
    setupState = state
    if case .ready = state { lastDetectTime = Date() }
  }

  // MARK: - Download

  /// Monotonic download intent. A Cancel bumps it, so a download task whose
  /// body has not yet run notices its intent is stale and never starts the
  /// multi-GB fetch (cloud review P2 on PR #1606: an instant Cancel could
  /// outrun the untracked task and find nothing to cancel). MainActor-serial,
  /// so the epoch comparison is deterministic.
  private var downloadIntentEpoch = 0

  /// The user asked for the model. Delegates to the verified delivery path; the
  /// state projection drives progress from there. A REFUSED request re-detects
  /// instead — no delivery state will ever arrive for it, and leaving the
  /// optimistic "Starting download..." up would stick forever (Codex 2b-r1 P2).
  public func downloadModel() {
    removeNotice = nil
    setupState = .downloading(progress: 0, status: "Starting download...")
    downloadIntentEpoch += 1
    let epoch = downloadIntentEpoch
    Task { [startDownload, weak self] in
      guard let self, self.downloadIntentEpoch == epoch else {
        // A Cancel outran this task: the download never starts, so no delivery
        // state will arrive — re-detect to disk truth (paused when partials
        // exist) instead of leaving "Starting download..." up.
        await self?.forceDetectState()
        return
      }
      // #1707 Phase 3 (§3.2, row 9) / #1741 Chunk 4: hold a mutation claim for
      // the FULL download — a Settings-initiated fetch must never race crash
      // recovery on the shared engine.
      let outcome = await self.engineMutationScope.withClaim(site: "whisperKitDownload") {
        if await startDownload() == false {
          await self.forceDetectState()
        }
      }
      if case .refused = outcome {
        await self.forceDetectState()
      }
    }
  }

  /// Cancel an in-progress download. Acknowledgment is instant by design — the
  /// controller's cancel resolves only after its drain. A REFUSED cancel (L1:
  /// the owed marker would not clear) re-detects NOTHING: the fetch is still
  /// running and the live state stream keeps showing it (Codex 2b-r3 P2).
  public func cancelDownload() {
    // Invalidate any download intent whose task has not run yet — cancelling
    // downstream cannot reach a request that has not been made.
    downloadIntentEpoch += 1
    Task { [cancelActiveDownload, weak self] in
      guard let self else { return }
      // #1707 Phase 3 (§3.2, row 10) / #1741 Chunk 4: hold a mutation claim
      // for the FULL cancel-drain — same reasoning as Download above. A
      // denied claim (recovery holds the engine) skips this attempt; the
      // fetch keeps running and the user can press Cancel again.
      //
      // No re-detect on an accepted cancel: the delivery-state projection
      // publishes the terminal (paused/cancelled) state, and detection would
      // wipe it back to not-downloaded (Codex 2c-r7 P2). A REFUSED cancel
      // (gate or coordinator) changes nothing either way.
      _ = await self.engineMutationScope.withClaim(site: "whisperKitCancelDownload") {
        _ = await cancelActiveDownload()
      }
    }
  }

  // MARK: - Remove (2c)

  /// The Remove press's inline notice; cleared on the next Remove/Download.
  public private(set) var removeNotice: WhisperKitRemoveNotice?

  /// True while a removal drain runs (founder ruling 2026-07-17): the row shows
  /// "Removing model..." and the button is gone, so Remove cannot be spammed at
  /// the UI (the coordinator already joins duplicates mechanically).
  public private(set) var isRemoving = false

  /// 2c: session authority, wired by the composition root from the class that
  /// owns both kernel drivers. nil (not yet wired) REFUSES — fail safe: a
  /// Remove that cannot prove no dictation is running does not run.
  public var isDictationInFlight: (@MainActor () -> Bool)?

  /// The user pressed Remove. The refusal check and L1 ordering live behind
  /// the injected action (wiring -> coordinator); this method only renders:
  /// success re-detects to Download, refusal/failure shows the inline notice
  /// and changes nothing else.
  public func removeModel() {
    removeNotice = nil
    // Founder ruling 2.5.4: REFUSE during a dictation — no defer, no queue,
    // nothing else changes; the user presses again after it ends.
    //
    // The check-then-act window is ACCEPTED, not a gap (plan §5c.3, founder-
    // ruled twice — reviewers keep re-deriving this; do not "fix" it without a
    // new founder decision). Re-checking at the destructive boundary or an
    // atomic reservation is a press-path gate: the thing L7 removed. The
    // seconds-long drain case cannot host a session at all — a live fetch
    // implies no admitted model, so a press lands on the honest cold-press
    // pill and never mints a WhisperKit session. What remains is a
    // milliseconds window no human can aim at.
    if isDictationInFlight?() != false {
      removeNotice = .refusedDictationInFlight
      return
    }
    guard !isRemoving else { return }
    isRemoving = true
    Task { [removeModelAction, weak self] in
      guard let self else { return }
      // #1707 Phase 3 (§3.2, row 10) / #1741 Chunk 4: hold a mutation claim
      // for the FULL removal drain — same reasoning as Download/Cancel above.
      let outcome = await self.engineMutationScope.withClaim(site: "whisperKitRemove") {
        let notice = await removeModelAction()
        self.isRemoving = false
        self.removeNotice = notice
        if notice == nil {
          // Successful removal is authoritative terminal delivery truth on its
          // own — probing the controller again would call adoptIfPresent(),
          // which republishes .notReady and re-enters this exact removal
          // completion through the delivery observer (the live infinite-loop
          // bug: Remove -> .notReady -> forceDetectState -> adoptIfPresent ->
          // .notReady -> repeat forever, pinning the main actor). Apply the
          // known terminal state directly instead.
          self.applyDeliveryState(.notDownloaded)
        } else {
          // A failure may have partially deleted (marker gone, bytes
          // remaining), and the row must show disk truth while the notice
          // above it explains the failure (Codex 2c-r1 P2 — the notice now
          // survives state flips by rendering outside the state switch).
          await self.forceDetectState()
        }
      }
      if case .refused = outcome {
        self.isRemoving = false
        self.removeNotice = .failed
      }
    }
  }
}
