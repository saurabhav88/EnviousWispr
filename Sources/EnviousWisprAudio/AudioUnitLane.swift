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
///   A job's own operation limit starts when it starts RUNNING: time spent waiting its turn counts
///   only against the caller's deadline (a slow but healthy Bluetooth release ahead of a route read
///   is not a stuck microphone).
/// - The lane is **wedged** only while a job that ran past its own operation limit has not
///   returned. Then new reads and opens are refused at once, and reads and opens already queued
///   behind it are answered `.wedged` at once; retirement is never refused.
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

  /// One caller's attempt (#4601 §5). Cancelling it works in every state: before admission
  /// (the open is refused `.abandoned` with no native work), queued (withdrawn), running (the
  /// caller resumes at once and a late value is disposed) and after the fact (no effect). The
  /// token is an object, so no table of cancelled ids is kept. `id` keys the one-outstanding-
  /// open-per-attempt rule.
  package final class Attempt: Sendable {
    package let id: UInt64
    private let state = OSAllocatedUnfairLock<(cancelled: Bool, onCancel: (@Sendable () -> Void)?)>(
      initialState: (false, nil))

    package init(id: UInt64) { self.id = id }

    private static let counter = OSAllocatedUnfairLock(initialState: UInt64(0))

    /// A token with a process-unique id, for any owner (a source's open, a manager's reads), so
    /// the one-outstanding-open-per-attempt rule never confuses two owners.
    package static func make() -> Attempt {
      Attempt(id: counter.withLock { value -> UInt64 in
        value &+= 1
        return value
      })
    }

    package func cancel() {
      let action = state.withLock { state -> (@Sendable () -> Void)? in
        if state.cancelled { return nil }
        state.cancelled = true
        defer { state.onCancel = nil }
        return state.onCancel
      }
      action?()
    }

    package var isCancelled: Bool { state.withLock { $0.cancelled } }

    /// Installs the lane's abandon action; false (and nothing installed) if already cancelled.
    fileprivate func register(_ onCancel: @escaping @Sendable () -> Void) -> Bool {
      state.withLock { state -> Bool in
        if state.cancelled { return false }
        state.onCancel = onCancel
        return true
      }
    }
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

  /// One job. Its mutable fields are touched only under the lane's lock, which is why the
  /// unchecked `Sendable` holds: there is no unguarded shared mutation. The latch is claimed
  /// exactly once and is the resource-transfer point; terminal claims (deadline, abandonment,
  /// withdrawal, refusal) happen under the lane's lock together with `callerGone`.
  private final class Job: @unchecked Sendable {
    enum Phase { case queued, running, finished }
    let id: UInt64
    let name: String
    let operation: Operation
    let attempt: UInt64?
    var phase: Phase = .queued
    /// Absolute caller deadline (nil for a retirement nobody waits on).
    var callerDeadline: ContinuousClock.Instant?
    /// The caller stopped waiting (deadline, cancellation, abandonment).
    var callerGone = false
    /// The running job passed its operation limit.
    var exceeded = false
    /// Resume the waiting caller; set when its continuation exists.
    var deliverTimedOut: (@Sendable () -> Void)?
    var deliverAbandoned: (@Sendable () -> Void)?
    var deliverWedged: (@Sendable () -> Void)?
    /// Runs once at the first terminal decision (deadline, abandonment, withdrawal), under the
    /// lane's lock and before the caller is resumed: lets the caller freeze what was known then.
    var onTerminal: (@Sendable () -> Void)?
    private var claimed = false

    init(id: UInt64, name: String, operation: Operation, attempt: UInt64?) {
      self.id = id
      self.name = name
      self.operation = operation
      self.attempt = attempt
    }

    /// True for exactly one claimant. Called under the lane's lock.
    func claim() -> Bool {
      if claimed { return false }
      claimed = true
      return true
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
  /// Installable once the app's reporting exists (the process-wide lane is built before it).
  private let hookStore: OSAllocatedUnfairLock<Hooks>
  private var hooks: Hooks { hookStore.withLock { $0 } }
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
    self.hookStore = OSAllocatedUnfairLock(initialState: hooks)
    #if DEBUG
      self.stallExecutor = stallExecutor
    #endif
  }

  /// Installs the hooks the composition root builds (#4601 §3.8: stuck-operation telemetry and
  /// DEBUG logging). Replaces any earlier set; later jobs report through the new hooks.
  package func installHooks(_ hooks: Hooks) {
    hookStore.withLock { $0 = hooks }
  }

  // MARK: - Caller operations

  /// A pure read on the lane. A late value is dropped.
  /// `attempt` (optional) lets its owner abandon the read from outside, like an open: cancelled
  /// before admission it runs nothing; queued it is withdrawn; running, the caller resumes at once
  /// with `.abandoned` and the late value is dropped. Use a fresh token per read.
  package func run<Value: Sendable>(
    _ name: String, deadline: ContinuousClock.Instant? = nil, attempt: Attempt? = nil,
    _ read: @escaping @Sendable () -> Value
  ) async -> Outcome<Value> {
    await submitAwaiting(
      name, operation: .read(name), attempt: attempt, deadline: deadline, limit: Self.readLimit,
      onTerminal: {}, work: read, disposeLate: { _ in })
  }

  /// An open whose value carries resources. If the caller is gone when it returns, `disposeLate`
  /// runs on the lane in the same turn (before any later job). One outstanding open per attempt:
  /// a second open for an attempt whose caller is still waiting is answered `.abandoned`.
  package func open<Value: Sendable>(
    _ name: String, attempt: Attempt, deadline: ContinuousClock.Instant?,
    onTerminal: @escaping @Sendable () -> Void = {},
    _ work: @escaping @Sendable () -> Value,
    disposeLate: @escaping @Sendable (Value) -> Void
  ) async -> Outcome<Value> {
    await submitAwaiting(
      name, operation: .open, attempt: attempt, deadline: deadline, limit: Self.openLimit,
      onTerminal: onTerminal, work: work, disposeLate: disposeLate)
  }

  /// Queues a retirement and returns at once. Never refused, even while wedged; stays ordered
  /// before every later job.
  package func retire(_ name: String = "microphone_release", _ work: @escaping @Sendable () -> Void) {
    submitDetached(name, work)
  }

  /// Queues a retirement and waits for it at most until `deadline` (quit only). Returns whether it
  /// finished in time. Never waits on the main actor and never waits without a bound.
  @discardableResult
  package func retireAndWait(
    _ name: String = "microphone_release", deadline: ContinuousClock.Instant,
    _ work: @escaping @Sendable () -> Void
  ) -> Bool {
    let done = DispatchSemaphore(value: 0)
    submitDetached(name) {
      work()
      done.signal()
    }
    let remaining = deadline - now()
    guard remaining > .zero else { return false }
    return done.wait(timeout: .now() + Self.seconds(remaining)) == .success
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

  private func makeJob(_ name: String, _ operation: Operation, _ attempt: UInt64?) -> Job {
    state.withLock { state in
      defer { state.nextID += 1 }
      return Job(id: state.nextID, name: name, operation: operation, attempt: attempt)
    }
  }

  /// Under the lane's lock: claims the job's latch for a terminal outcome, marks the caller gone,
  /// and returns the delivery to run after the lock (nil if someone already claimed it, or the
  /// continuation does not exist yet, in which case it sees `callerGone` when it does).
  private static func terminate(_ job: Job, with deliver: (@Sendable () -> Void)?)
    -> (@Sendable () -> Void)?
  {
    job.callerGone = true
    guard let deliver, job.claim() else { return nil }
    job.onTerminal?()
    return deliver
  }

  /// THE deadline rule, used at every decision that can see a passed caller deadline before its
  /// timer fires (the queued-to-running check and the worker's hand-over): under the lane's lock,
  /// an unclaimed job whose absolute caller deadline has passed is terminated as timed out.
  /// Returns nil when the deadline has not passed; otherwise the (possibly empty) delivery.
  private func expiredDelivery(_ job: Job) -> (@Sendable () -> Void)?? {
    guard let deadline = job.callerDeadline, now() >= deadline else { return nil }
    return .some(Self.terminate(job, with: job.deliverTimedOut))
  }

  private enum Refusal { case wedged, duplicate, abandoned }

  private func submitAwaiting<Value: Sendable>(
    _ name: String, operation: Operation, attempt: Attempt?, deadline: ContinuousClock.Instant?,
    limit: Duration, onTerminal: @escaping @Sendable () -> Void,
    work: @escaping @Sendable () -> Value,
    disposeLate: @escaping @Sendable (Value) -> Void
  ) async -> Outcome<Value> {
    let job = makeJob(name, operation, attempt?.id)
    job.onTerminal = onTerminal
    return await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Outcome<Value>, Never>) in
        // Admission, the duplicate-attempt check and queue insertion are ONE decision under the
        // lane's lock, so admission order is execution order (§3.1).
        let refusal = state.withLock { state -> Refusal? in
          job.deliverTimedOut = { continuation.resume(returning: .timedOut) }
          job.deliverAbandoned = { continuation.resume(returning: .abandoned) }
          job.deliverWedged = { continuation.resume(returning: .wedged) }
          if job.callerGone { return job.claim() ? .abandoned : nil }
          if state.isWedged { return job.claim() ? .wedged : nil }
          if let attempt,
            state.outstanding.values.contains(where: { $0.attempt == attempt.id && !$0.callerGone })
          {
            return job.claim() ? .duplicate : nil
          }
          // An attempt cancelled before admission runs nothing; otherwise its cancellation
          // abandons this job from now on.
          if let attempt,
            !attempt.register({ [weak self] in
              guard let self else { return }
              let deliver = self.state.withLock { _ in Self.terminate(job, with: job.deliverAbandoned) }
              deliver?()
            })
          {
            return job.claim() ? .abandoned : nil
          }
          // Queued, the caller waits within its own deadline only; the operation limit joins it
          // when the job starts running (`runJob`).
          job.callerDeadline = deadline
          state.outstanding[job.id] = job
          queue.async { [self] in
            runJob(job, limit: limit) {
              let value = work()
              // Transfer point: the caller takes the value, or the lane disposes it now. A
              // passed caller deadline wins even when its timer has not fired yet.
              let (handOver, timedOut) = self.state.withLock {
                _ -> (Bool, (@Sendable () -> Void)?) in
                if let expired = self.expiredDelivery(job) { return (false, expired) }
                return (job.claim(), nil)
              }
              timedOut?()
              if handOver {
                continuation.resume(returning: .value(value))
              } else {
                disposeLate(value)
              }
            }
          }
          return nil
        }
        switch refusal {
        case .wedged?: continuation.resume(returning: .wedged)
        case .duplicate?, .abandoned?: continuation.resume(returning: .abandoned)
        case nil:
          guard let callerDeadline = state.withLock({ _ in job.callerDeadline }) else { return }
          scheduleCallerDeadline(job, callerDeadline)
        }
      }
    } onCancel: {
      let deliver = state.withLock { _ in Self.terminate(job, with: job.deliverAbandoned) }
      deliver?()
    }
  }

  /// Times the caller out at `deadline` (remaining time from the current clock). The
  /// queued-to-running check and the hand-over also enforce it, so a late timer cannot let an
  /// expired job start or hand over.
  private func scheduleCallerDeadline(_ job: Job, _ deadline: ContinuousClock.Instant) {
    schedule(max(deadline - now(), .zero)) { [self] in
      let deliver = state.withLock { _ in Self.terminate(job, with: job.deliverTimedOut) }
      deliver?()
    }
  }

  private func submitDetached(_ name: String, _ work: @escaping @Sendable () -> Void) {
    let job = makeJob(name, .retire, nil)
    // Never refused; admitted and queued in one decision like every other job.
    state.withLock { state in
      state.outstanding[job.id] = job
      queue.async { [self] in runJob(job, limit: Self.retireLimit, work) }
    }
  }

  /// Runs one job on the lane queue. The queued-to-running transition is decided under the lock:
  /// a job whose caller left, or whose caller deadline has passed (even if its timer has not
  /// fired yet), runs no native work.
  private func runJob(_ job: Job, limit: Duration, _ body: @Sendable () -> Void) {
    let (proceed, lateDelivery, limitDeadline) = state.withLock {
      state -> (Bool, (@Sendable () -> Void)?, ContinuousClock.Instant?) in
      if job.operation != .retire {
        var delivery: (@Sendable () -> Void)?
        var withdraw = job.callerGone
        if !withdraw, let expired = expiredDelivery(job) {
          withdraw = true
          delivery = expired
        }
        if withdraw {
          job.phase = .finished
          state.outstanding[job.id] = nil
          return (false, delivery, nil)
        }
      }
      job.phase = .running
      state.running = job
      // A waiting caller never waits past this operation's limit, counted from now (§3.1:
      // queued time is ordinary contention, charged only to the caller's own deadline).
      if job.operation != .retire, !job.callerGone {
        let limitEnd = now() + limit
        if job.callerDeadline.map({ limitEnd < $0 }) ?? true {
          job.callerDeadline = limitEnd
          return (true, nil, limitEnd)
        }
      }
      return (true, nil, nil)
    }
    lateDelivery?()
    guard proceed else {
      finishWaiters()
      return
    }
    if let limitDeadline { scheduleCallerDeadline(job, limitDeadline) }
    let started = now()
    schedule(limit) { [self] in
      let (fired, queuedDeliveries) = state.withLock { state -> (Bool, [@Sendable () -> Void]) in
        guard state.running === job, job.phase == .running, !job.exceeded else { return (false, []) }
        job.exceeded = true
        // The lane is wedged: reads and opens still waiting their turn behind this job get the
        // same answer a new one gets, at once (a caller with no deadline would otherwise wait
        // for as long as the driver stays stuck). Retirements stay queued.
        let deliveries = state.outstanding.values
          .filter { $0.phase == .queued && $0.operation != .retire }
          .compactMap { Self.terminate($0, with: $0.deliverWedged) }
        return (true, deliveries)
      }
      if fired { hooks.operationTimedOut(job.id, job.name, limit) }
      for deliver in queuedDeliveries { deliver() }
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
