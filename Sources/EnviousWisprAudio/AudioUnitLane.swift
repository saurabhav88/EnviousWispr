import Foundation
import os

/// Every audio-unit lifecycle call, one at a time, off the main actor (#4601 §3.1).
///
/// A third-party audio driver can stop answering an AUHAL call (`AudioOutputUnitStart`,
/// `AudioOutputUnitStop`, `AudioComponentInstanceDispose`, a HAL property read): the call then
/// blocks in `mach_msg` with no timeout and no way to cancel it (OBS #13902, cubeb PR 284, our
/// #4021 captures). Made from the main actor, it froze the app.
///
/// One process-wide serial queue keeps today's global order (dictation and meeting audio units
/// were all serialized on the main thread), so an old unit's release always finishes before a
/// later open starts. Mechanics are ported from `CoreAudioQueryLane` (dispatch-timer deadlines,
/// single-resume latch, hooks, DEBUG one-shot stall) with a different admission rule:
///
/// - Ordinary queued or running work makes a new caller WAIT (within its own deadline). A normal
///   release before a reopen, or a meeting open beside a dictation, is contention, not a fault.
/// - The lane is **wedged** only while a job that ran past its own operation limit has not
///   returned. Then new reads and opens are refused at once; retirement is never refused.
/// - A caller's deadline bounds the CALLER's wait, never the native call. A queued job whose
///   caller left (deadline, cancellation, explicit abandonment) runs no native work. A running job
///   whose caller left keeps running; if it was an open that succeeded, the lane disposes its
///   result in the same queue turn, before any later job.
/// - The single-resume latch is the resource-transfer point: whoever claims it first owns the
///   outcome. The worker claiming it hands the value to the caller; a deadline or abandonment
///   claiming it first leaves the value with the lane, which disposes it.
package final class AudioUnitLane: Sendable {
  /// What a caller gets. `.timedOut`, `.wedged` and `.abandoned` mean "no answer", never "nothing".
  package enum Outcome<Value: Sendable>: Sendable {
    case value(Value)
    /// The caller's deadline passed first.
    case timedOut
    /// Refused at admission: a job past its own operation limit has not returned.
    case wedged
    /// The caller was cancelled or its attempt was abandoned.
    case abandoned
  }

  /// Which operation a job is, for the DEBUG stall and for hooks.
  package enum Operation: Equatable, Sendable {
    case open
    case retire
    case read(String)
  }

  /// Per-operation limits: past this, a running job wedges the lane (§3.1, §3a).
  package static let readLimit: Duration = .seconds(1)
  package static let openLimit: Duration = .seconds(5)
  package static let retireLimit: Duration = .seconds(5)

  /// Reported by the composition root (this module cannot reach telemetry). Hooks run outside the
  /// lane's lock and must not block. `id` identifies one job across its hooks.
  package struct Hooks: Sendable {
    /// A running job passed its own operation limit (the lane is now wedged). Once per job.
    package var operationTimedOut:
      @Sendable (_ id: UInt64, _ name: String, _ limit: Duration) -> Void
    /// A job that had passed its operation limit finally returned. Once per such job.
    package var operationRecovered:
      @Sendable (_ id: UInt64, _ name: String, _ after: Duration, _ limit: Duration) -> Void
    /// Every job that ran, with how long it ran (DEBUG logging).
    package var completed: @Sendable (_ id: UInt64, _ name: String, _ duration: Duration) -> Void
    /// DEBUG only: an armed stall is about to block this job.
    package var debugStallFired: @Sendable (_ id: UInt64, _ name: String, _ stall: Duration) -> Void

    package init(
      operationTimedOut: @escaping @Sendable (UInt64, String, Duration) -> Void = { _, _, _ in },
      operationRecovered: @escaping @Sendable (UInt64, String, Duration, Duration) -> Void = {
        _, _, _, _ in
      },
      completed: @escaping @Sendable (UInt64, String, Duration) -> Void = { _, _, _ in },
      debugStallFired: @escaping @Sendable (UInt64, String, Duration) -> Void = { _, _, _ in }
    ) {
      self.operationTimedOut = operationTimedOut
      self.operationRecovered = operationRecovered
      self.completed = completed
      self.debugStallFired = debugStallFired
    }
  }

  /// One admitted job. Its mutable fields are touched only under the lane's lock (`phase`,
  /// `callerGone`, `exceeded`, `abandonCaller`) or through its own latch, which is why the
  /// unchecked `Sendable` holds: there is no unguarded shared mutation.
  private final class Job: @unchecked Sendable {
    enum Phase { case queued, running, finished }
    let id: UInt64
    let name: String
    let operation: Operation
    let attempt: UInt64?
    var phase: Phase = .queued
    /// The caller stopped waiting (deadline, cancellation, abandonment).
    var callerGone = false
    /// The running job passed its operation limit.
    var exceeded = false
    /// Resumes the caller with `.abandoned`; set once the continuation exists.
    var abandonCaller: (@Sendable () -> Void)?
    /// Set if abandonment arrived before `abandonCaller` existed.
    var abandonedEarly = false
    private let latch = OSAllocatedUnfairLock(initialState: false)

    init(id: UInt64, name: String, operation: Operation, attempt: UInt64?) {
      self.id = id
      self.name = name
      self.operation = operation
      self.attempt = attempt
    }

    /// True for exactly one caller: the transfer point.
    func claim() -> Bool {
      latch.withLock { taken -> Bool in
        if taken { return false }
        taken = true
        return true
      }
    }
  }

  private struct State {
    var nextID: UInt64 = 1
    var outstanding: [UInt64: Job] = [:]
    var running: Job?
    var waiters: [@Sendable () -> Void] = []
    var isWedged: Bool { running?.exceeded == true }
    var isIdle: Bool { outstanding.isEmpty }
  }

  /// The process-wide lane.
  package static let shared = AudioUnitLane()

  private let queue: DispatchQueue
  private let state = OSAllocatedUnfairLock(initialState: State())
  private let schedule: @Sendable (Duration, @escaping @Sendable () -> Void) -> Void
  private let now: @Sendable () -> ContinuousClock.Instant
  private let hooks: Hooks
  #if DEBUG
    private let stallArm = OSAllocatedUnfairLock<(Operation, Duration)?>(initialState: nil)
    private let stallExecutor: @Sendable (Duration) -> Void
  #endif

  package convenience init(
    label: String = "com.enviouswispr.audio.unit-lane", hooks: Hooks = Hooks()
  ) {
    self.init(
      label: label,
      schedule: { delay, fire in
        // A timer, not a task: it fires even when every worker thread is busy and never
        // depends on the main actor.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
          deadline: .now() + Self.seconds(delay), execute: fire)
      },
      now: { ContinuousClock.now },
      hooks: hooks)
  }

  /// Test seam: timers and clock are injectable so tests fire deadlines themselves; the DEBUG
  /// `stallExecutor` lets a test gate an armed stall instead of sleeping.
  package init(
    label: String,
    schedule: @escaping @Sendable (Duration, @escaping @Sendable () -> Void) -> Void,
    now: @escaping @Sendable () -> ContinuousClock.Instant,
    hooks: Hooks = Hooks(),
    stallExecutor: @escaping @Sendable (Duration) -> Void = { stall in
      Thread.sleep(forTimeInterval: AudioUnitLane.seconds(stall))
    }
  ) {
    self.queue = DispatchQueue(label: label, qos: .userInitiated)
    self.schedule = schedule
    self.now = now
    self.hooks = hooks
    #if DEBUG
      self.stallExecutor = stallExecutor
    #endif
  }

  // MARK: - Caller operations

  /// A pure read on the lane. A late value is dropped.
  package func run<Value: Sendable>(
    _ name: String, deadline: ContinuousClock.Instant? = nil,
    _ read: @escaping @Sendable () -> Value
  ) async -> Outcome<Value> {
    await submitAwaiting(
      name, operation: .read(name), attempt: nil, deadline: deadline, limit: Self.readLimit,
      work: read, disposeLate: { _ in })
  }

  /// An open whose value carries resources. If the caller is gone when it returns, `disposeLate`
  /// runs on the lane in the same turn (before any later job). One outstanding open per attempt.
  package func open<Value: Sendable>(
    _ name: String, attempt: UInt64, deadline: ContinuousClock.Instant?,
    _ work: @escaping @Sendable () -> Value,
    disposeLate: @escaping @Sendable (Value) -> Void
  ) async -> Outcome<Value> {
    let duplicate = state.withLock { state in
      state.outstanding.values.contains { $0.attempt == attempt && !$0.callerGone }
    }
    if duplicate {
      assertionFailure("AudioUnitLane: a second open for attempt \(attempt) (#4601)")
      return .abandoned
    }
    return await submitAwaiting(
      name, operation: .open, attempt: attempt, deadline: deadline, limit: Self.openLimit,
      work: work, disposeLate: disposeLate)
  }

  /// Queues a retirement and returns at once. Never refused, even while wedged; stays ordered
  /// before every later job.
  package func retire(_ name: String = "microphone_release", _ work: @escaping @Sendable () -> Void)
  {
    _ = submitDetached(name, work)
  }

  /// Queues a retirement and waits for it at most until `deadline` (quit only). Returns whether it
  /// finished in time. Never waits on the main actor and never waits without a bound.
  @discardableResult
  package func retireAndWait(
    _ name: String = "microphone_release", deadline: ContinuousClock.Instant,
    _ work: @escaping @Sendable () -> Void
  ) -> Bool {
    let done = DispatchSemaphore(value: 0)
    _ = submitDetached(name) {
      work()
      done.signal()
    }
    let remaining = deadline - now()
    guard remaining > .zero else { return false }
    return done.wait(timeout: .now() + Self.seconds(remaining)) == .success
  }

  /// Abandons every outstanding job of `attempt`: a waiting caller resumes at once with
  /// `.abandoned`; a queued job runs no native work; a running open's late value is disposed.
  package func abandon(attempt: UInt64) {
    let resumes = state.withLock { state -> [@Sendable () -> Void] in
      var resumes: [@Sendable () -> Void] = []
      for job in state.outstanding.values where job.attempt == attempt && !job.callerGone {
        job.callerGone = true
        if let resume = job.abandonCaller {
          resumes.append(resume)
        } else {
          job.abandonedEarly = true
        }
      }
      return resumes
    }
    for resume in resumes { resume() }
  }

  /// Calls `callback` once the lane has nothing outstanding: at once when idle now, otherwise right
  /// after the last job (and any late disposal it required) finishes. Level-triggered.
  package func whenAvailable(_ callback: @escaping @Sendable () -> Void) {
    let runNow = state.withLock { state -> Bool in
      if state.isIdle { return true }
      state.waiters.append(callback)
      return false
    }
    if runNow { callback() }
  }

  /// Whether a job past its own operation limit has not returned.
  package var isWedged: Bool { state.withLock { $0.isWedged } }

  #if DEBUG
    /// UAT seam (DEBUG only, reported through `Hooks.debugStallFired`): the next job of
    /// `operation` that actually begins blocks for `stall` first. Refused or withdrawn jobs, and
    /// jobs of other operations, leave the arm in place.
    package func armStall(for operation: Operation, _ stall: Duration) {
      stallArm.withLock { $0 = (operation, stall) }
    }

    private func takeStallArm(matching operation: Operation) -> Duration? {
      stallArm.withLock { arm -> Duration? in
        guard let current = arm, current.0 == operation else { return nil }
        arm = nil
        return current.1
      }
    }

    /// Test seam: waits until the lane is idle.
    package func drainForTesting() async {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        whenAvailable { continuation.resume() }
      }
    }
  #endif

  // MARK: - Internals

  private func admit(
    _ name: String, _ operation: Operation, _ attempt: UInt64?, refuseIfWedged: Bool
  )
    -> Job?
  {
    state.withLock { state -> Job? in
      if refuseIfWedged && state.isWedged { return nil }
      let job = Job(id: state.nextID, name: name, operation: operation, attempt: attempt)
      state.nextID += 1
      state.outstanding[job.id] = job
      return job
    }
  }

  private func submitAwaiting<Value: Sendable>(
    _ name: String, operation: Operation, attempt: UInt64?, deadline: ContinuousClock.Instant?,
    limit: Duration, work: @escaping @Sendable () -> Value,
    disposeLate: @escaping @Sendable (Value) -> Void
  ) async -> Outcome<Value> {
    guard let job = admit(name, operation, attempt, refuseIfWedged: true) else { return .wedged }
    let admittedAt = now()
    // The caller never waits past its own deadline nor past this operation's limit.
    let limitDeadline = admittedAt + limit
    let callerDeadline = deadline.map { min($0, limitDeadline) } ?? limitDeadline
    return await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Outcome<Value>, Never>) in
        let resume: @Sendable (Outcome<Value>) -> Bool = { outcome in
          guard job.claim() else { return false }
          continuation.resume(returning: outcome)
          return true
        }
        let abandonedAlready = state.withLock { _ -> Bool in
          job.abandonCaller = { _ = resume(.abandoned) }
          return job.abandonedEarly
        }
        if abandonedAlready { _ = resume(.abandoned) }
        queue.async { [self] in
          runJob(job, limit: limit) {
            let value = work()
            // Transfer point: the caller takes the value, or the lane disposes it now.
            if !resume(.value(value)) { disposeLate(value) }
          }
        }
        let wait = callerDeadline - admittedAt
        schedule(max(wait, .zero)) { [self] in
          guard resume(.timedOut) else { return }
          state.withLock { _ in job.callerGone = true }
        }
      }
    } onCancel: {
      abandonJob(job)
    }
  }

  private func submitDetached(_ name: String, _ work: @escaping @Sendable () -> Void) -> Job {
    // Retirement is never refused.
    let job = admit(name, .retire, nil, refuseIfWedged: false)!
    queue.async { [self] in runJob(job, limit: Self.retireLimit, work) }
    return job
  }

  private func abandonJob(_ job: Job) {
    let resume = state.withLock { _ -> (@Sendable () -> Void)? in
      job.callerGone = true
      if job.abandonCaller == nil { job.abandonedEarly = true }
      return job.abandonCaller
    }
    resume?()
  }

  /// Runs one job on the lane queue. The queued-to-running transition is decided under the lock:
  /// a job whose caller already left runs no native work.
  private func runJob(_ job: Job, limit: Duration, _ body: @Sendable () -> Void) {
    let proceed = state.withLock { state -> Bool in
      if job.callerGone && job.operation != .retire {
        job.phase = .finished
        state.outstanding[job.id] = nil
        return false
      }
      job.phase = .running
      state.running = job
      return true
    }
    guard proceed else {
      finishWaiters()
      return
    }
    let started = now()
    schedule(limit) { [self] in
      let fired = state.withLock { state -> Bool in
        guard state.running === job, job.phase == .running, !job.exceeded else { return false }
        job.exceeded = true
        return true
      }
      if fired { hooks.operationTimedOut(job.id, job.name, limit) }
    }
    #if DEBUG
      if let stall = takeStallArm(matching: job.operation) {
        hooks.debugStallFired(job.id, job.name, stall)
        stallExecutor(stall)
      }
    #endif
    body()
    let elapsed = now() - started
    let recovered = state.withLock { state -> Bool in
      job.phase = .finished
      if state.running === job { state.running = nil }
      state.outstanding[job.id] = nil
      return job.exceeded
    }
    hooks.completed(job.id, job.name, elapsed)
    if recovered { hooks.operationRecovered(job.id, job.name, elapsed, limit) }
    finishWaiters()
  }

  private func finishWaiters() {
    let waiters = state.withLock { state -> [@Sendable () -> Void] in
      guard state.isIdle else { return [] }
      let waiters = state.waiters
      state.waiters = []
      return waiters
    }
    for waiter in waiters { waiter() }
  }

  package static func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
  }
}
