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
/// inter-signal cadence using a monotonic clock. The trigger fires when both:
///
///   - silence > 800ms floor (matches `AVCaptureSessionSource` first-buffer
///     liveness latch, the only foreground-user-watching silence threshold
///     in our codebase).
///   - silence > 5x the worst inter-signal gap observed so far in this
///     attempt (statistical "definitely abnormal" ratio).
///
/// Threshold self-calibrates per-attempt to whatever cadence Parakeet's loader
/// naturally has on this machine, in this phase. Healthy fast loads stay well
/// below their own observed cadence ratio. A real wedge produces silence
/// orders of magnitude larger than anything observed during the same attempt.
///
/// Pre-first-signal coverage
/// =========================
/// If no progress signal is ever observed (XPC service crashes pre-listing),
/// the watcher does NOT fire. Today's indefinite-hang behavior persists.
/// Adding pre-first-signal coverage requires a defended first-signal-latency
/// duration, which we don't have data for. Deferred per plan §2.2.
///
/// Concurrency
/// ===========
/// `@MainActor`-isolated. All callers (proxy poll timer, pipeline race helper)
/// run on `@MainActor`. No actor hops. No Sendable boundary crossings.
@MainActor
public final class LoadProgressWatcher {
  /// Minimum silence (seconds) before the watcher can fire, even if the ratio
  /// gate is met. The 0.8s default matches `AVCaptureSessionSource`'s
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
  /// #1405: true while the last observed tick was an ACTIVE download phase, so
  /// the next non-download tick can reset the attempt once at the
  /// download->load boundary (clean load slate, deadline counts from there).
  private var wasInDownloadPhase = false
  private var continuation: CheckedContinuation<Void, Never>?
  /// Require two observed progress signals before ratio-based silence can fire.
  /// This keeps the 800ms floor from becoming a standalone timeout after only
  /// one lifecycle tick. XPC lifecycle operations keep this safer default:
  /// cold `startRunning()`, `AVAudioEngine.start()`, and large stop replies can
  /// legitimately stay quiet for longer than the floor before their next signal.
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

  /// #1405: phases whose stall detection the DOWNLOADER owns (via its request
  /// idle timeout), NOT this load-watchdog. While the observed phase is in this
  /// set the watcher stays parked — it never fires and keeps its attempt
  /// baseline fresh, so load-stall detection starts clean at the
  /// download->load transition. Empty (default) preserves the pure-load
  /// behavior for callers that never watch a download.
  private let downloadOwnedPhases: Set<String>

  public init(
    currentTime: @escaping @MainActor () -> TimeInterval = {
      ProcessInfo.processInfo.systemUptime
    },
    requiresObservedGap: Bool = true,
    listingPhase: String? = nil,
    listingStallDeadlineSeconds: TimeInterval? = nil,
    silenceFloorSeconds: TimeInterval = 0.8,
    downloadOwnedPhases: Set<String> = []
  ) {
    self.currentTime = currentTime
    self.requiresObservedGap = requiresObservedGap
    self.listingPhase = listingPhase
    self.listingStallDeadlineSeconds = listingStallDeadlineSeconds
    self.floorSeconds = silenceFloorSeconds
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

    // download -> load transition: the first non-download tick after a parked
    // download starts the LOAD attempt fresh. This gives load-stall detection a
    // clean slate (the long download does not bleed into its gates) and makes
    // the pre-first-signal deadline count from HERE — so a load that wedges
    // without ever writing progress after the download is still recovered.
    if wasInDownloadPhase {
      wasInDownloadPhase = false
      attemptStartedAt = now
      firstSignalAt = nil
      lastSignalAt = nil
      maxGapSeconds = 0
      signalCount = 0
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

  /// PROVISIONAL listing-stall deadline (plan §3a, issue #1339): fires only
  /// on ABSENCE of progress in the listing window (one signal then silence,
  /// or no signal at all) — never on a progressing transfer. Defended by
  /// production distribution: healthy listing→first-byte is seconds; the
  /// abandonment floor observed in production is 7 minutes (420s). Tuned
  /// post-ship via the `model_download.listing_ms` probe; source-aware
  /// deadlines (our-copy ~8-10s) arrive with the mirror-first source work.
  public static let listingStallDeadlineSeconds: TimeInterval = 120

  /// Minimum mid-stream silence before a download-watching ratio gate may
  /// fire. Defended by the 2026-07-05 Live UAT drill (#1339): a COLD edge
  /// read of the 445MB encoder object produced a legitimate multi-second
  /// first-byte gap, and the 0.8s XPC-beat floor let a ~2.5s ratio threshold
  /// kill a healthy fresh-install download. 15s comfortably clears observed
  /// cold-TTFB (~3-5s) while still surfacing a genuinely dead mid-stream
  /// transfer fast. PROVISIONAL — tuned post-ship from download telemetry.
  public static let transferSilenceFloorSeconds: TimeInterval = 15
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
