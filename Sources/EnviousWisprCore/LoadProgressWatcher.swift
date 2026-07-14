import Foundation

/// Issue #445: signal-based wedge detector for the model-load `await`.
///
/// Replaces the prior wall-clock `raceWithTimeout(20s)` design after the
/// founder course-correction (no-arbitrary-timeouts.md): a duration deadline
/// requires either grep-cited precedent for an analogous wedge OR p99 across
/// >=30 samples. The 20s number had neither (single-sample-plus-headroom
/// over a 14s cold-load reference, which the rule explicitly forbids).
///
/// Mechanism
/// =========
/// The watcher consumes the existing 8Hz progress polling stream from
/// `ASRManagerProxy.startProgressPolling`. On every tick it tracks per-attempt
/// inter-signal cadence using a monotonic clock. The post-signal silence gate
/// ("gate B") fires when both:
///
///   - silence > 800ms floor (matches the capture sources' first-buffer
///     liveness latch, the only foreground-user-watching silence threshold
///     in our codebase).
///   - silence > 5x the worst inter-signal gap observed so far in this
///     attempt (statistical "definitely abnormal" ratio).
///
/// Where the self-calibration premise holds — and where it does not (#1388)
/// ========================================================================
/// The per-attempt ratio assumes the phase's work units are roughly
/// homogeneous, so observed cadence predicts future cadence. That holds for
/// the XPC-operation MILESTONE stream (`XPCOperationSignalWatcher`) — our own
/// service emits signals at points we choose, on a ~ms beat. It does NOT hold
/// for work-progress streams with heterogeneous units: the CoreML install
/// phase emits ~52 ticks ~1.5s apart for the small models, then goes silent
/// for one ~445MB encoder taking ~20x longer — the ratio is trained on the
/// wrong distribution, the floor becomes the sole trigger, and every fire is
/// a false positive (126/126 in production, #1388). Callers watching such a
/// stream pass `postSignalSilenceGateEnabled: false` and keep only gate (A):
/// the pre-first-signal / single-signal listing deadline, which detects "the
/// service reported nothing whatsoever" — a real, unambiguous condition.
///
/// Concurrency
/// ===========
/// `@MainActor`-isolated. All callers (proxy poll timer, pipeline race helper)
/// run on `@MainActor`. No actor hops. No Sendable boundary crossings.
@MainActor
public final class LoadProgressWatcher {
  /// Minimum silence (seconds) before the watcher can fire, even if the ratio
  /// gate is met. The 0.8s default matches the capture sources'
  /// first-buffer liveness latch — the right beat for XPC lifecycle signals.
  ///
  /// #1339 made this injectable: for INTERNET TRANSFER watching the 0.8s beat
  /// is wrong — the 2026-07-05 Live UAT drill showed a cold edge read of the
  /// 445MB encoder object producing a legitimate multi-second first-byte gap,
  /// and a ratio threshold derived from the dense small-file ticks before it
  /// (~2.5s) killed a HEALTHY fresh-install download. Download watchers pass
  /// `ModelLoadStallPolicy.transferSilenceFloorSeconds` instead.
  private let floorSeconds: TimeInterval

  /// Multiplier applied to the worst observed inter-signal gap to compute
  /// the ratio threshold. 5x is the statistical "definitely abnormal" ratio.
  /// (Audio liveness latch implicitly uses ~80x normal — buffers ~10ms,
  /// latch 800ms — but model-load phases run on a much slower beat so the
  /// abnormal-ratio is more conservative.)
  private let abnormalRatio: Double = 5.0

  // Per-attempt state. Time source is monotonic in production
  // (`ProcessInfo.processInfo.systemUptime`, survives wall-clock jumps from
  // sleep/wake). The `currentTime` seam below makes the source injectable so
  // tests can drive deterministic time without coupling to the CI scheduler.
  // See issue #782.
  private var attemptStartedAt: TimeInterval = 0
  private var firstSignalAt: TimeInterval?
  private var lastSignalAt: TimeInterval?
  private var lastObservedMtime: Date?
  private var lastObservedPhase: String = ""
  private var maxGapSeconds: TimeInterval = 0
  private var signalCount: Int = 0
  private var fired = false
  private var continuation: CheckedContinuation<Void, Never>?

  /// #1388: install-phase observation (telemetry ONLY — no gate reads these).
  /// Tracks when the injected `installPhase` first/last produced a signal and
  /// the longest gap between its signals, so the warm-up success event can
  /// record the true install duration and its longest internal silence —
  /// the distribution gate (B) used to truncate at 15s.
  private var installFirstSignalAt: TimeInterval?
  private var installLastSignalAt: TimeInterval?
  private var installMaxGapSeconds: TimeInterval = 0
  /// Require two observed progress signals before ratio-based silence can fire.
  /// This keeps the 800ms floor from becoming a standalone timeout after only
  /// one lifecycle tick. XPC lifecycle operations keep this safer default:
  /// cold `startRunning()`, capture-source `prepare()`, and large stop replies
  /// can legitimately stay quiet for longer than the floor before their next signal.
  private let requiresObservedGap: Bool

  /// Monotonic clock source. Production uses `ProcessInfo.processInfo.systemUptime`
  /// via the default; tests inject a `ManualClock` for deterministic timing.
  /// `@MainActor` on the closure type records the actual isolation contract —
  /// the watcher is `@MainActor`-isolated and all call sites already run on
  /// `@MainActor`.
  private let currentTime: @MainActor () -> TimeInterval

  /// Issue #1339: phase-aware listing-stall gate. The one wedge shape the
  /// ratio gate deliberately cannot catch is the first-run listing stall —
  /// exactly one signal ("Preparing download..." at fraction 0), then silence
  /// while the remote host's repo-listing call hangs. `requiresObservedGap`
  /// correctly refuses to fire the 800ms floor on a single signal, so that
  /// stall previously hung forever (the #445-deferred hole).
  ///
  /// When BOTH `listingPhase` and `listingStallDeadlineSeconds` are injected,
  /// two additional defended firings unlock:
  ///   - single-signal: last observed phase == `listingPhase` and silence
  ///     since that signal exceeds the deadline;
  ///   - pre-first-signal: no signal ever observed and time since `start()`
  ///     exceeds the deadline (service never wrote progress at all).
  /// The deadline is a PROVISIONAL dial (production-tuned via the
  /// `model_download.listing_ms` probe, plan §3a): healthy listing→first-byte
  /// is seconds; the abandonment floor observed in production is 7 minutes.
  /// Byte-transfer/compile phases (signalCount >= 2) stay governed by the
  /// existing ratio gate, unchanged.
  private let listingPhase: String?
  private let listingStallDeadlineSeconds: TimeInterval?

  /// #1388: whether the post-signal silence gates (gate B — the floor + ratio
  /// evaluation) run at all. Default `true` preserves the XPC-operation
  /// watcher's behavior byte-for-byte. The model-load guard passes `false`:
  /// its signal is a heterogeneous work-progress stream where the
  /// self-calibration premise fails (see the header), so it keeps only
  /// gate (A) — the pre-first-signal / single-signal listing deadline.
  private let postSignalSilenceGateEnabled: Bool

  /// #1388: the exact phase string of the CoreML install ("compiling") phase,
  /// for the install observation above. Observation only — never a gate input.
  private let installPhase: String?

  /// #1405 (retained through #1388 — Codex r2 P1): phases OWNED by the
  /// download fetcher, whose own request idle timeout is the stall authority.
  /// While the observed phase is in this set (with a FRESH signal), the
  /// watcher is parked — it never fires and does not accumulate load-attempt
  /// state; the first non-download tick after a parked download RESETS the
  /// attempt so gate (A)'s pre-first-signal deadline counts from the
  /// download→load boundary. #1388's first cut deleted this with gate (B),
  /// which silently blinded gate (A) on fresh installs: download ticks
  /// counted as load signals, so a service that hung before its first LOAD
  /// signal was undetectable. Parking protects gate (A), not just gate (B).
  private let downloadOwnedPhases: Set<String>

  /// #1405: true while the last observed tick was an ACTIVE download phase, so
  /// the next non-download tick can reset the attempt once at the
  /// download→load boundary (clean load slate, deadline counts from there).
  private var wasInDownloadPhase = false

  public init(
    currentTime: @escaping @MainActor () -> TimeInterval = {
      ProcessInfo.processInfo.systemUptime
    },
    requiresObservedGap: Bool = true,
    listingPhase: String? = nil,
    listingStallDeadlineSeconds: TimeInterval? = nil,
    silenceFloorSeconds: TimeInterval = 0.8,
    postSignalSilenceGateEnabled: Bool = true,
    installPhase: String? = nil,
    downloadOwnedPhases: Set<String> = []
  ) {
    self.currentTime = currentTime
    self.requiresObservedGap = requiresObservedGap
    self.listingPhase = listingPhase
    self.listingStallDeadlineSeconds = listingStallDeadlineSeconds
    self.floorSeconds = silenceFloorSeconds
    self.postSignalSilenceGateEnabled = postSignalSilenceGateEnabled
    self.installPhase = installPhase
    self.downloadOwnedPhases = downloadOwnedPhases
  }

  /// Begin a new attempt. Resets all per-attempt state.
  /// Caller should pair with `stop()` after the attempt resolves.
  public func start() {
    attemptStartedAt = currentTime()
    firstSignalAt = nil
    lastSignalAt = nil
    lastObservedMtime = nil
    lastObservedPhase = ""
    maxGapSeconds = 0
    signalCount = 0
    fired = false
    installFirstSignalAt = nil
    installLastSignalAt = nil
    installMaxGapSeconds = 0
    wasInDownloadPhase = false
    // continuation intentionally left untouched: a prior consumer may still be
    // awaiting wedged() and must be resumed by the caller before start().
  }

  /// Mark the attempt as resolved. Resumes any pending `wedged()` consumer
  /// without firing the trigger. Idempotent.
  public func stop() {
    fired = true
    if let cont = continuation {
      continuation = nil
      cont.resume()
    }
  }

  /// Feed one tick from the progress polling timer. Called even when no
  /// new file content arrived — the watcher still needs to evaluate silence
  /// against the elapsed time.
  ///
  /// `observedMtime` is the file's modification timestamp; mtime-advance
  /// (rather than content-hash) is the signal-detection key so identical-
  /// content writes still count as signals. `nil` means the file does not
  /// exist (pre-first-write).
  public func observeTick(observedMtime: Date?, observedPhase: String) {
    guard !fired else { return }
    let now = currentTime()

    // #1405: while an ACTIVE download is in flight, the fetcher owns
    // transfer-stall (its own request idle timeout), so the load-watchdog must
    // not judge it. "Active" requires a FRESH signal (observedMtime != nil):
    // a STALE progress file left on the download phase by a prior interrupted
    // attempt passes observedMtime == nil and must NOT park — otherwise a new
    // warm-up that hangs before writing would be suppressed forever
    // (code-diff review). Park = never fire; do not touch the attempt baseline
    // here, so a slow multi-minute download cannot false-fire the deadline.
    if observedMtime != nil, downloadOwnedPhases.contains(observedPhase) {
      wasInDownloadPhase = true
      lastObservedMtime = observedMtime
      return
    }

    // download → load transition: the first non-download tick after a parked
    // download starts the LOAD attempt fresh. This gives load-stall detection a
    // clean slate (the long download does not bleed into its gates) and makes
    // the pre-first-signal deadline count from HERE — so a load that wedges
    // without ever writing progress after the download is still recovered
    // (gate A; Codex r2 P1 on #1388).
    if wasInDownloadPhase {
      wasInDownloadPhase = false
      attemptStartedAt = now
      firstSignalAt = nil
      lastSignalAt = nil
      maxGapSeconds = 0
      signalCount = 0
      installFirstSignalAt = nil
      installLastSignalAt = nil
      installMaxGapSeconds = 0
      lastObservedMtime = observedMtime
      lastObservedPhase = observedPhase
      return
    }

    // Detect a "real" signal by mtime advance.
    if let mtime = observedMtime, mtime != lastObservedMtime {
      if let last = lastSignalAt {
        let gap = now - last
        if gap > maxGapSeconds {
          maxGapSeconds = gap
        }
      }
      lastSignalAt = now
      if firstSignalAt == nil { firstSignalAt = now }
      lastObservedMtime = mtime
      lastObservedPhase = observedPhase
      signalCount += 1
      // #1388: install-phase observation (telemetry only, never a gate input).
      if let install = installPhase, observedPhase == install {
        if let last = installLastSignalAt {
          let gap = now - last
          if gap > installMaxGapSeconds { installMaxGapSeconds = gap }
        }
        if installFirstSignalAt == nil { installFirstSignalAt = now }
        installLastSignalAt = now
      }
      return
    }

    // No new signal this tick — evaluate silence against gates.
    guard lastSignalAt != nil else {
      // Pre-first-signal. With the #1339 listing deadline injected, a load
      // whose service never writes a single progress signal (dead service,
      // pre-listing crash) fires after the defended deadline instead of
      // hanging forever. Without the deadline, the original #445 deferral
      // stands: do not fire.
      if let deadline = listingStallDeadlineSeconds,
        now - attemptStartedAt > deadline
      {
        fire()
      }
      return
    }

    // #1339 single-signal listing-stall gate: exactly one signal observed,
    // and it was the listing phase — the remote repo-listing call is hanging.
    // Fires on the defended deadline; healthy loads leave listing in seconds.
    if signalCount == 1,
      let deadline = listingStallDeadlineSeconds,
      let listing = listingPhase,
      lastObservedPhase == listing,
      now - (lastSignalAt ?? attemptStartedAt) > deadline
    {
      fire()
      return
    }
    // #1388: everything below is gate (B) — the post-signal silence
    // evaluation. Disabled for the model-load guard (heterogeneous work
    // units break the self-calibration premise; see the header). Gate (A)
    // above remains that caller's only detector, so a load that goes quiet
    // AFTER its first signal, with the service alive, is deliberately no
    // longer auto-detected — the user-facing control for a long wait is
    // Cancel, and the install telemetry now records the real distribution.
    guard postSignalSilenceGateEnabled else { return }

    // Codex finding (2026-05-07): require at least one observed inter-signal
    // gap before the ratio gate is meaningful. With only one signal observed,
    // `maxGapSeconds == 0` and the threshold collapses to the floor alone —
    // which would false-positive on a normal long gap between the first
    // phase signal and the second (e.g. listing → 5s → downloading).
    // Pre-second-signal wedges are uncovered (extension of the pre-first-signal
    // non-goal; in practice the wedge symptom sits inside compile phase, after
    // many signals have accumulated, so this restriction does not lose coverage
    // for the targeted defect).
    guard maxGapSeconds > 0 else {
      guard !requiresObservedGap else { return }
      let silence = now - (lastSignalAt ?? attemptStartedAt)
      if silence > floorSeconds {
        fire()
      }
      return
    }
    let silence = now - (lastSignalAt ?? attemptStartedAt)
    let ratioThreshold = maxGapSeconds * abnormalRatio
    let threshold = max(floorSeconds, ratioThreshold)
    if silence > threshold {
      fire()
    }
  }

  /// Single fire path: latches `fired` and resumes any pending `wedged()`
  /// consumer. All observeTick gates funnel here.
  private func fire() {
    fired = true
    if let cont = continuation {
      continuation = nil
      cont.resume()
    }
  }

  /// Suspends until the watcher fires `wedged`. If the watcher already fired
  /// before the caller awaits, returns immediately. If `stop()` is called
  /// while a caller is awaiting, the suspension resumes without firing.
  /// Cancellation: cancellation of the awaiting task resumes the continuation
  /// without setting `fired` (caller's responsibility to handle).
  public func wedged() async {
    if fired { return }
    await withTaskCancellationHandler {
      await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        if fired {
          cont.resume()
        } else {
          continuation = cont
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        guard let self else { return }
        if let cont = self.continuation {
          self.continuation = nil
          cont.resume()
        }
      }
    }
  }

  /// Whether the trigger has fired this attempt. Stays `true` until `start()`
  /// resets the watcher. Useful for deterministic assertions in tests
  /// (instead of awaiting `wedged()` and hoping the scheduler resumes it
  /// within the test runner's deadline).
  // periphery:ignore - test seam
  public var hasFired: Bool { fired }

  /// #1388: the install-phase observation for the warm-up success telemetry.
  /// `nil` until the injected `installPhase` produced at least one signal.
  /// `silenceMaxMs` is tail-inclusive — the longest silence is often BETWEEN
  /// the last install tick and completion (the large encoder is the final
  /// work unit and emits nothing after), so the gap from the last install
  /// signal to the read time competes with the observed inter-signal max.
  /// Read at warm-up completion; reading later would overstate the tail.
  public var installObservation: InstallPhaseObservation? {
    guard let first = installFirstSignalAt, let last = installLastSignalAt else { return nil }
    let now = currentTime()
    return InstallPhaseObservation(
      durationMs: Int((now - first) * 1000),
      silenceMaxMs: Int(max(installMaxGapSeconds, now - last) * 1000)
    )
  }

  /// Snapshot of the watcher's per-attempt state. Used by the pipeline to
  /// stamp the `wedge_detected` telemetry payload with diagnostic context.
  public var snapshot: WatcherSnapshot {
    let now = currentTime()
    let silenceMs: Int = {
      if let last = lastSignalAt {
        return Int((now - last) * 1000)
      }
      return Int((now - attemptStartedAt) * 1000)
    }()
    let firstLatencyMs: Int? = {
      guard let first = firstSignalAt else { return nil }
      return Int((first - attemptStartedAt) * 1000)
    }()
    return WatcherSnapshot(
      lastObservedPhase: lastObservedPhase,
      silenceMs: silenceMs,
      maxGapMs: Int(maxGapSeconds * 1000),
      signalCountTotal: signalCount,
      firstSignalLatencyMs: firstLatencyMs,
      totalAttemptDurationMs: Int((now - attemptStartedAt) * 1000)
    )
  }
}

/// Shared model-download stall policy (#1339). Single authority for the
/// listing-phase token and the listing-stall deadline so the service-side
/// phase writer (`ParakeetBackend`), the host-side progress seam
/// (`ASRManagerProxy`), and the sessionless wedge guard
/// (`KernelDictationDriver`) can never drift apart on the literal or the dial.
public enum ModelLoadStallPolicy {
  /// The exact phase string the XPC service writes to the shared progress
  /// file while the remote host's repo-file-listing call is in flight. The
  /// wedge guard keys its single-signal stall gate on this token.
  public static let listingPhase = "Preparing download..."

  /// The exact phase string the delivery layer writes while the model files
  /// are actively downloading (the whole HEAD+GET+retry+failover fetch runs
  /// under this one state). #1405: the fetcher owns its own stall detection
  /// via its request idle timeout (`ManifestFetchTask.requestTimeout`), so the
  /// sessionless wedge guard must NOT judge this phase — it would fight the
  /// fetcher's legitimate retry/backoff/Retry-After waits (the P2 cascade).
  /// The guard passes this to `downloadOwnedPhases`; single authority so the
  /// phase writer (`ParakeetModelDelivery.bridgeToProgressFile`) and the guard
  /// can never drift on the literal.
  public static let downloadingPhase = "Downloading speech model..."

  /// The exact phase string the delivery layer writes while validating an
  /// existing cache (`.preparing(validating: true)`), and while SHA-verifying
  /// a completed download (`.verifying`). #1388 (Codex r4): these are
  /// delivery-owned work like the download — their ticks must PARK the
  /// sessionless wedge guard, not count as load signals, or a service that
  /// hangs after `.admitted` clears the file is undetectable on the
  /// cache/validation path (no download phase ever ran to trigger the
  /// boundary reset). Local hashing has no watchdog of its own — a hang
  /// inside these phases is accepted-undetected (disk-level pathology; the
  /// removed gate (B) only ever covered it by accident), and gate (A)
  /// re-arms at the boundary reset the moment the phase moves on.
  public static let validatingCachePhase = "Checking speech model files..."
  public static let verifyingDownloadPhase = "Verifying download..."

  /// Every delivery-owned phase the sessionless wedge guard parks on. The
  /// listing phase is deliberately NOT here: gate (A)'s single-signal listing
  /// deadline exists precisely to judge a hanging listing (#1339).
  public static var deliveryParkedPhases: Set<String> {
    [downloadingPhase, validatingCachePhase, verifyingDownloadPhase]
  }

  /// The exact phase string the XPC service writes while CoreML compiles the
  /// downloaded model (the "install" the onboarding checklist shows).
  /// #1388: the watcher's install OBSERVATION keys on this token to record
  /// install duration + longest internal silence on the warm-up success
  /// event. Observation only — no gate reads it. Single authority with the
  /// phase writer (`ParakeetBackend`).
  public static let installPhase = "Installing model..."

  /// PROVISIONAL listing-stall deadline (plan §3a, issue #1339): fires only
  /// on ABSENCE of progress in the listing window (one signal then silence,
  /// or no signal at all) — never on a progressing transfer. Defended by
  /// production distribution: healthy listing→first-byte is seconds; the
  /// abandonment floor observed in production is 7 minutes (420s). Tuned
  /// post-ship via the `model_download.listing_ms` probe; source-aware
  /// deadlines (our-copy ~8-10s) arrive with the mirror-first source work.
  ///
  /// #1388 removed `transferSilenceFloorSeconds` (the 15s gate-B floor): the
  /// post-signal silence gate no longer runs on the model-load path at all,
  /// so the constant lost its only consumer. This deadline is the surviving
  /// duration dial.
  public static let listingStallDeadlineSeconds: TimeInterval = 120
}

/// #1388: install-phase observation captured by `LoadProgressWatcher` for the
/// warm-up success telemetry (`install_duration_ms` / `install_silence_max_ms`
/// on `coldstart.warmup_completed`). Pure observation — nothing gates on it.
public struct InstallPhaseObservation: Sendable {
  public let durationMs: Int
  public let silenceMaxMs: Int

  public init(durationMs: Int, silenceMaxMs: Int) {
    self.durationMs = durationMs
    self.silenceMaxMs = silenceMaxMs
  }
}

/// Diagnostic snapshot of a `LoadProgressWatcher`'s per-attempt state.
/// Sent in the `wedge_detected` telemetry payload so the follow-up analysis
/// can correlate silence patterns to phases and load durations.
public struct WatcherSnapshot: Sendable {
  public let lastObservedPhase: String
  public let silenceMs: Int
  public let maxGapMs: Int
  public let signalCountTotal: Int
  public let firstSignalLatencyMs: Int?
  public let totalAttemptDurationMs: Int

  public init(
    lastObservedPhase: String, silenceMs: Int, maxGapMs: Int,
    signalCountTotal: Int, firstSignalLatencyMs: Int?, totalAttemptDurationMs: Int
  ) {
    self.lastObservedPhase = lastObservedPhase
    self.silenceMs = silenceMs
    self.maxGapMs = maxGapMs
    self.signalCountTotal = signalCountTotal
    self.firstSignalLatencyMs = firstSignalLatencyMs
    self.totalAttemptDurationMs = totalAttemptDurationMs
  }
}

/// Outcome of `raceWithSignalWatcher`. Three terminal cases the caller must
/// handle. Renamed from `TimeoutOutcome` to surface the conceptual change:
/// the trigger is now signal-based, not deadline-based.
public enum WatcherOutcome<T: Sendable>: Sendable {
  /// Work returned a value before the watcher fired.
  case completed(T)
  /// Watcher fired before work returned. The work task was cancelled
  /// cooperatively. Note: Swift cancellation is cooperative — non-cooperative
  /// work (XPC blocking calls, CoreML `MLModel.load`) continues in the
  /// background. The function returns regardless; the caller's state machine
  /// must reset cleanly without depending on the work actually stopping.
  case wedged
  /// Work threw before the watcher fired. With the default parent-cancellation
  /// behavior, caller cancellation also surfaces here as `CancellationError`.
  case threw(Error)
}

/// Parent-task cancellation policy for `raceWithSignalWatcher`.
public enum WatcherParentCancellationBehavior: Sendable {
  /// Surface caller cancellation as `.threw(CancellationError())` and cancel
  /// the raced work best-effort. This is the normal behavior for foreground
  /// operations whose caller is no longer interested in the result.
  case returnCancellation
  /// Ignore parent-task cancellation and keep awaiting the real operation result
  /// or the signal watcher. Cleanup awaits use this so a cancelled forward-path
  /// task cannot mark resources released before the service actually stops.
  case waitForResolution
}

/// At-most-once outcome delivery. First sender wins; subsequent senders are
/// dropped. Mirror of `OutcomeBox` from the deleted `Timeout.swift` so the
/// race shape stays familiar to readers.
private actor OutcomeBox<T: Sendable> {
  private var outcome: WatcherOutcome<T>?
  private var waiter: CheckedContinuation<WatcherOutcome<T>, Never>?

  func deliver(_ value: WatcherOutcome<T>) {
    guard outcome == nil else { return }
    outcome = value
    if let waiter {
      self.waiter = nil
      waiter.resume(returning: value)
    }
  }

  func wait() async -> WatcherOutcome<T> {
    if let outcome { return outcome }
    return await withCheckedContinuation { cont in
      waiter = cont
    }
  }
}

/// Race an async operation against a signal-based wedge watcher.
///
/// The work runs on a detached task so a non-cooperative wedge (XPC stuck,
/// `MLModel.load` stuck) cannot pin the parent's structured concurrency scope.
/// Returns as soon as the watcher fires or the work completes, whichever
/// resolves first.
///
/// On wedge, the work task is `cancel()`ed (best-effort, cooperative).
///
/// On parent-task cancellation, returns `.threw(CancellationError())` by
/// default. Cleanup callers can opt into `.waitForResolution` when returning
/// before the real operation resolves would violate a release contract.
///
/// Caller must call `watcher.start()` before invoking this and `watcher.stop()`
/// after it returns (typically via `defer`). The race helper does NOT manage
/// the watcher's lifecycle.
public func raceWithSignalWatcher<T: Sendable>(
  watcher: LoadProgressWatcher,
  parentCancellationBehavior: WatcherParentCancellationBehavior = .returnCancellation,
  _ work: @Sendable @escaping () async throws -> T
) async -> WatcherOutcome<T> {
  let box = OutcomeBox<T>()

  // Detached so a wedged `work` cannot block the parent's structured scope.
  let workTask = Task.detached {
    do {
      let value = try await work()
      await box.deliver(.completed(value))
    } catch {
      await box.deliver(.threw(error))
    }
  }

  // Watcher waiter. Stays on `@MainActor` because `LoadProgressWatcher` is
  // MainActor-isolated. If the watcher fires, this delivers `.wedged`; if
  // the work wins first, this task is cancelled and `wedged()`'s cancellation
  // handler unblocks the continuation.
  let watcherTask = Task { @MainActor in
    await watcher.wedged()
    await box.deliver(.wedged)
  }

  return await withTaskCancellationHandler {
    let result = await box.wait()
    watcherTask.cancel()
    if case .wedged = result {
      workTask.cancel()
    }
    return result
  } onCancel: {
    switch parentCancellationBehavior {
    case .returnCancellation:
      Task { await box.deliver(.threw(CancellationError())) }
      workTask.cancel()
      watcherTask.cancel()
    case .waitForResolution:
      break
    }
  }
}
