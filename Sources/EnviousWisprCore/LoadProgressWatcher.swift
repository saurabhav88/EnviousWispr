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
  /// gate is met. Matches `AVCaptureSessionSource` first-buffer liveness latch
  /// (800ms) — the only foreground-user-watching silence threshold in our
  /// codebase. Treats "user staring at screen waiting for state to advance"
  /// as the relevant analogue.
  private let floorSeconds: TimeInterval = 0.8

  /// Multiplier applied to the worst observed inter-signal gap to compute
  /// the ratio threshold. 5x is the statistical "definitely abnormal" ratio.
  /// (Audio liveness latch implicitly uses ~80x normal — buffers ~10ms,
  /// latch 800ms — but model-load phases run on a much slower beat so the
  /// abnormal-ratio is more conservative.)
  private let abnormalRatio: Double = 5.0

  // Per-attempt state. All using `ProcessInfo.processInfo.systemUptime`
  // (monotonic — survives wall-clock jumps from sleep/wake).
  private var attemptStartedAt: TimeInterval = 0
  private var firstSignalAt: TimeInterval?
  private var lastSignalAt: TimeInterval?
  private var lastObservedMtime: Date?
  private var lastObservedPhase: String = ""
  private var maxGapSeconds: TimeInterval = 0
  private var signalCount: Int = 0
  private var fired = false
  private var continuation: CheckedContinuation<Void, Never>?

  public init() {}

  /// Begin a new attempt. Resets all per-attempt state.
  /// Caller should pair with `stop()` after the attempt resolves.
  public func start() {
    attemptStartedAt = ProcessInfo.processInfo.systemUptime
    firstSignalAt = nil
    lastSignalAt = nil
    lastObservedMtime = nil
    lastObservedPhase = ""
    maxGapSeconds = 0
    signalCount = 0
    fired = false
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
    let now = ProcessInfo.processInfo.systemUptime

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
      // Pre-first-signal: do not fire. Coverage hole acknowledged in plan §2.2.
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
    guard maxGapSeconds > 0 else { return }
    let silence = now - (lastSignalAt ?? attemptStartedAt)
    let ratioThreshold = maxGapSeconds * abnormalRatio
    let threshold = max(floorSeconds, ratioThreshold)
    if silence > threshold {
      fired = true
      if let cont = continuation {
        continuation = nil
        cont.resume()
      }
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

  /// Snapshot of the watcher's per-attempt state. Used by the pipeline to
  /// stamp the `wedge_detected` telemetry payload with diagnostic context.
  public var snapshot: WatcherSnapshot {
    let now = ProcessInfo.processInfo.systemUptime
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
  /// Work threw before the watcher fired, OR the parent task that called
  /// `raceWithSignalWatcher` was cancelled. Caller cancellation surfaces as
  /// `CancellationError`.
  case threw(Error)
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
/// On parent-task cancellation, returns `.threw(CancellationError())`.
///
/// Caller must call `watcher.start()` before invoking this and `watcher.stop()`
/// after it returns (typically via `defer`). The race helper does NOT manage
/// the watcher's lifecycle.
public func raceWithSignalWatcher<T: Sendable>(
  watcher: LoadProgressWatcher,
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
    Task { await box.deliver(.threw(CancellationError())) }
    workTask.cancel()
    watcherTask.cancel()
  }
}
