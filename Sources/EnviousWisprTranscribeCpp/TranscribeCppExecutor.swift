import Foundation
import os

#if DEBUG
  /// #3849 Live UAT evidence that a native load was running when the app quit. Content-free.
  private let logger = Logger(subsystem: "com.enviouswispr.app", category: "TranscribeCpp")
#endif

/// #3735 plan §3.2a: the ONE owner of every transcribe.cpp compute call, across every model.
///
/// transcribe.cpp 0.x allows one `transcribe_run` in flight per model and calls on a session
/// one thread at a time; whether two models may compute at once is not established. So this
/// executor admits exactly one native operation at a time across all models (heart turbo and
/// preview small), on a dedicated serial queue, while the actor itself stays responsive.
///
/// Lanes and priority (plan §3.2a, live-preview.md RULE: universal-preview-engine-safety
/// invariants 3 and 4):
/// - Heart work never waits behind preview work. On heart admission queued preview requests
///   end `.preempted`, an active preview run is asked to abort out of band, and the heart
///   request runs after that run has physically returned. A preempted preview never publishes
///   a result, even if its native call returned success before it saw the abort.
/// - Preview admission is refused while any heart request is queued or running.
/// - Heart requests run in FIFO order.
///
/// Every request ends exactly once: its result, an error, `.cancelled` or `.preempted`.
/// Native occupancy is held until the native call returns, whatever the caller does; a
/// cancelled caller is released at once and its late result is discarded.
///
/// Teardown order: abort, await the native return, free the session (which frees its model).
/// A closing model accepts no new work; repeated unloads coalesce onto one teardown.
///
/// #3849: every native session must be freed before the process exits. ggml's Metal device is
/// a function-local static whose destructor, run by `exit()`, asserts that no residency set is
/// still alive (`GGML_ASSERT([rsets->data count] == 0)`), so a live session turns every quit
/// into a crash. `live` below is the executor's physical truth about which sessions exist, and
/// `releaseAllForTermination(timeout:)` empties it synchronously from the quit path.
public actor TranscribeCppExecutor {
  /// The one executor in the process. Every model and every feature shares it, so the
  /// one-native-call-at-a-time promise holds across the whole app, not per caller.
  public static let shared = TranscribeCppExecutor()

  public enum Lane: Sendable, Equatable { case heart, preview }

  /// A loaded model owned by this executor. Opaque: native handles never leave the executor.
  public struct ModelHandle: Hashable, Sendable {
    public let id: UUID
    public let modelPath: String
  }

  public enum ExecutorError: Error, Equatable, Sendable {
    case cancelled
    /// A preview request lost to heart work (queued and dropped, or aborted while running).
    case preempted
    /// A preview request refused because heart work is queued or running.
    case heartBusy
    /// The model is unloading or was never loaded by this executor.
    case modelUnavailable
  }

  /// #3849: the quit release's outcome. Only `.released` means every session was freed.
  package enum TerminationRelease: Sendable, Equatable {
    /// Every live session was freed; `sessions` counts them, `waitedMs` is the time spent
    /// waiting for a running native call to return plus the frees.
    case released(sessions: Int, waitedMs: Int)
    /// A native call did not return within the bound; `sessions` were alive when it began.
    case timedOut(sessions: Int)
    /// A release already began: it says nothing about whether that one has finished.
    case alreadyStarted
  }

  /// #3849: a session from the moment `transcribe_open` returned until its `close()` returned,
  /// tagged with the lane its load ran on (the heart and the preview each load on one lane).
  struct LiveSession: Sendable {
    let session: any TranscribeCppEngineSession
    let lane: Lane
  }

  /// #3849: shared by the actor and the native queue; read and written only under `native`.
  struct NativeState: Sendable {
    /// One-way. Once set, no native load, detection or decode starts in this executor.
    var terminating = false
    var live: [ObjectIdentifier: LiveSession] = [:]
  }

  /// Observable counters for tests. Not app policy.
  struct Counters: Sendable, Equatable {
    var admitted = 0
    var completed = 0
    var discardedResults = 0
    var peakOccupancy = 0
    var freed = 0
  }

  private enum Work {
    case load(path: String)
    case detect(ModelHandle, samples: [Float])
    case transcribe(
      ModelHandle, samples: [Float], language: String?,
      onProgress: (@Sendable (Int64, Int64) -> Void)?,
      onInferenceEntered: (@Sendable () -> Void)?)
    case free(ModelHandle)

    var isFree: Bool {
      if case .free = self { return true }
      return false
    }
  }

  private static func handleID(of work: Work) -> UUID? {
    switch work {
    case .load: nil
    case .detect(let handle, _), .transcribe(let handle, _, _, _, _), .free(let handle): handle.id
    }
  }

  /// Unchecked: `failed` carries a non-Sendable `any Error`. Each outcome is built once on
  /// the native queue and handed once to the actor; nothing reads or mutates it concurrently.
  private enum Outcome: @unchecked Sendable {
    case loaded(any TranscribeCppEngineSession)
    case detected(TranscribeCppLanguageObservation)
    case transcribed(TranscribeCppRunResult)
    case freed
    case failed(any Error)
  }

  /// Unchecked: `continuation` and `preempted` are read and written only on the actor;
  /// `lane` and `work` are immutable; the cancellation latch is lock-protected because
  /// `onCancel` and the native queue read or set it off the actor.
  private final class Request: @unchecked Sendable {
    let id = UUID()
    let lane: Lane
    let work: Work
    var continuation: CheckedContinuation<Outcome, any Error>?
    var preempted = false
    private let cancelLatch = OSAllocatedUnfairLock(initialState: false)
    init(lane: Lane, work: Work) {
      self.lane = lane
      self.work = work
    }
    var isLoad: Bool {
      if case .load = work { return true }
      return false
    }
    /// Set synchronously by the caller's cancellation, before any hop to the actor, so no
    /// later admission step can miss it.
    var isCancelled: Bool { cancelLatch.withLock { $0 } }
    func markCancelled() { cancelLatch.withLock { $0 = true } }
    func finish(_ result: Result<Outcome, any Error>) {
      guard let continuation else { return }  // exactly once
      self.continuation = nil
      continuation.resume(with: result)
    }
  }

  private let makeSession: @Sendable (String) throws -> any TranscribeCppEngineSession
  private let queue = DispatchQueue(
    label: "com.enviouswispr.transcribecpp.executor", qos: .userInitiated)
  private var sessions: [UUID: any TranscribeCppEngineSession] = [:]
  private var closing: Set<UUID> = []
  private var unloadWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
  private var drainWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
  private var heartQueue: [Request] = []
  private var previewQueue: [Request] = []
  private var active: Request?
  private(set) var counters = Counters()
  /// #3849: callers of `awaitSettled(openedOn:)` waiting for their lane to hold no session.
  private var settleWaiters: [(lane: Lane, continuation: CheckedContinuation<Int, Never>)] = []
  /// #3849: the physical lifetime registry and the termination latch.
  private let native = OSAllocatedUnfairLock(initialState: NativeState())

  /// Queued request counts, for tests.
  struct QueueDepths: Sendable, Equatable {
    let heart: Int
    let preview: Int
    let running: Bool
    /// #3849: parked `awaitSettled(openedOn:)` callers.
    var settleWaiting = 0
  }

  var queueDepths: QueueDepths {
    QueueDepths(
      heart: heartQueue.count, preview: previewQueue.count, running: active != nil,
      settleWaiting: settleWaiters.count)
  }

  /// Test seam: announced synchronously on the actor whenever the queues or the running
  /// request change, so a test waits for the state itself instead of polling the actor.
  private var stateObserver: (@Sendable (QueueDepths) -> Void)?

  func setStateObserver(_ observer: (@Sendable (QueueDepths) -> Void)?) {
    stateObserver = observer
    observer?(queueDepths)
  }

  /// Every queue or active-request change passes here, so settle waiters re-check on each.
  private func announce() {
    stateObserver?(queueDepths)
    resumeSettledWaiters()
  }

  /// - Parameter makeSession: opens one native session that owns its model. Production uses
  ///   `TranscribeCppSession.init(modelPath:)` through `shared`; tests inject controlled fakes.
  init(
    makeSession: @escaping @Sendable (String) throws -> any TranscribeCppEngineSession = {
      try TranscribeCppSession(modelPath: $0)
    }
  ) {
    self.makeSession = makeSession
  }

  // MARK: - Public operations

  public func load(modelPath: String, lane: Lane) async throws -> ModelHandle {
    guard
      case .loaded(let session) = try await submit(
        Request(lane: lane, work: .load(path: modelPath)))
    else { throw ExecutorError.modelUnavailable }
    let handle = ModelHandle(id: UUID(), modelPath: modelPath)
    sessions[handle.id] = session
    return handle
  }

  public func detectLanguage(
    _ handle: ModelHandle, samples: [Float], lane: Lane
  ) async throws -> TranscribeCppLanguageObservation {
    guard
      case .detected(let observation) = try await submit(
        Request(lane: lane, work: .detect(handle, samples: samples)))
    else { throw ExecutorError.modelUnavailable }
    return observation
  }

  /// - Parameter onInferenceEntered: called synchronously on the native thread immediately
  ///   before `transcribe_run`. Never called while the request only waits in a queue, nor
  ///   for a request cancelled before its native work starts.
  public func transcribe(
    _ handle: ModelHandle, samples: [Float], language: String?, lane: Lane,
    onProgress: (@Sendable (Int64, Int64) -> Void)? = nil,
    onInferenceEntered: (@Sendable () -> Void)? = nil
  ) async throws -> TranscribeCppRunResult {
    guard
      case .transcribed(let result) = try await submit(
        Request(
          lane: lane,
          work: .transcribe(
            handle, samples: samples, language: language, onProgress: onProgress,
            onInferenceEntered: onInferenceEntered)))
    else { throw ExecutorError.modelUnavailable }
    return result
  }

  /// Returns once no native work for `handle` is running. A caller that cancelled keeps the
  /// native call running until it returns; this waits for that return. It never frees
  /// anything and never blocks admission of new work.
  public func waitForDrain(_ handle: ModelHandle) async {
    guard let active, Self.handleID(of: active.work) == handle.id else { return }
    await withCheckedContinuation { drainWaiters[handle.id, default: []].append($0) }
  }

  /// Aborts and drains any work on `handle`, then frees it. Coalesces: concurrent callers
  /// wait for the one teardown. Unknown or already-freed handles return at once.
  public func unload(_ handle: ModelHandle) async {
    if closing.contains(handle.id) {
      await withCheckedContinuation { unloadWaiters[handle.id, default: []].append($0) }
      return
    }
    guard sessions[handle.id] != nil else { return }
    closing.insert(handle.id)
    // Drop queued work for this model and abort its running work out of band.
    for request in (heartQueue + previewQueue) where Self.handleID(of: request.work) == handle.id {
      request.finish(.failure(ExecutorError.modelUnavailable))
    }
    heartQueue.removeAll { Self.handleID(of: $0.work) == handle.id }
    previewQueue.removeAll { Self.handleID(of: $0.work) == handle.id }
    if let active, Self.handleID(of: active.work) == handle.id {
      sessions[handle.id]?.requestAbort()
    }
    // The free runs as heart-lane work so it is not starved; it waits for the active run.
    // Its continuation and its queue slot are installed in one actor step, so a run that
    // completes meanwhile can never find the free queued without a caller and drop it.
    // No cancellation handler: a caller that stops waiting must not leave the model half
    // closed, so the teardown always runs to the end.
    let free = Request(lane: .heart, work: .free(handle))
    _ = try? await withCheckedThrowingContinuation { continuation in
      free.continuation = continuation
      heartQueue.insert(free, at: 0)
      announce()
      pump()
    }
    sessions[handle.id] = nil
    closing.remove(handle.id)
    for waiter in unloadWaiters.removeValue(forKey: handle.id) ?? [] { waiter.resume() }
  }

  /// #3849: returns once no load opened on `lane` is queued or running and no session that a
  /// load on `lane` opened is still alive, whoever frees it (an unload, an orphan close, the
  /// quit release). The returned count is read under the registry lock: 0.
  ///
  /// Call only after releasing every handle you own on that lane, with your own admission
  /// closed; otherwise this waits for your own resident handle. A free scheduled for a
  /// preview handle runs on the heart lane but does not count: sessions belong to the lane
  /// their load ran on.
  package func awaitSettled(openedOn lane: Lane) async -> Int {
    // The check and the install happen in one actor step, so no change can fall between them.
    await withCheckedContinuation { continuation in
      if let remaining = settledCount(lane) {
        continuation.resume(returning: remaining)
      } else {
        settleWaiters.append((lane, continuation))
        stateObserver?(queueDepths)  // test seam: a parked settle is observable state
      }
    }
  }

  /// #3849: the quit path's synchronous release. Sets the one-way latch, asks every live
  /// session to abort, and frees every live session on the native queue, behind whichever
  /// native call is running; waits at most `timeout` for that.
  ///
  /// After it, no native load, detection or decode starts in this executor; frees still run.
  /// Never frees a session whose native call is still running: on `.timedOut` that call still
  /// owns its session, and the caller must end the process without running `exit()`.
  package nonisolated func releaseAllForTermination(timeout: Duration) -> TerminationRelease {
    let native = native
    let started: [any TranscribeCppEngineSession]? = native.withLock { state in
      guard !state.terminating else { return nil }
      state.terminating = true
      return state.live.values.map(\.session)
    }
    guard let started else { return .alreadyStarted }
    for session in started { session.requestAbort() }
    let start = ContinuousClock.now
    let freed = OSAllocatedUnfairLock(initialState: 0)
    let done = DispatchSemaphore(value: 0)
    // Serial queue: this runs after the running native call returns. `live` is snapshotted,
    // not cleared, so a concurrent check still sees every session whose close has not
    // returned. A load that returns after the latch registered its session first and closed
    // it at once, so the snapshot cannot miss a live one.
    queue.async {
      let remaining = native.withLock { state in state.live.values.map(\.session) }
      for session in remaining { Self.closeAndUnregister(session, native: native) }
      freed.withLock { $0 = remaining.count }
      done.signal()
      Task { await self.nativeLifetimeChanged() }
    }
    guard done.wait(timeout: .now() + Self.dispatchInterval(timeout)) == .success else {
      return .timedOut(sessions: started.count)
    }
    let waitedMs = Int(((ContinuousClock.now - start) / .milliseconds(1)).rounded())
    return .released(sessions: freed.withLock { $0 }, waitedMs: waitedMs)
  }

  /// The native open, bracketed in DEBUG by content-free markers that also mark a throwing
  /// return: Live UAT's evidence that a load was inside native code when the app quit.
  private static func openSession(
    _ path: String, lane: Lane,
    makeSession: @Sendable (String) throws -> any TranscribeCppEngineSession
  ) throws -> any TranscribeCppEngineSession {
    #if DEBUG
      let label = lane == .heart ? "heart" : "preview"
      logger.notice("transcribe.cpp native load enter lane=\(label, privacy: .public)")
      defer { logger.notice("transcribe.cpp native load return lane=\(label, privacy: .public)") }
    #endif
    return try makeSession(path)
  }

  private static func dispatchInterval(_ duration: Duration) -> DispatchTimeInterval {
    let (seconds, attoseconds) = duration.components
    return .nanoseconds(Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
  }

  // MARK: - Physical lifetime (#3849)

  /// The one free path: ordinary free, orphan close, late-load refusal and the quit release.
  /// Runs on the native queue only. A session is freed at most once; it stays in `live` until
  /// its `close()` has returned.
  private static func closeAndUnregister(
    _ session: any TranscribeCppEngineSession,
    native: OSAllocatedUnfairLock<NativeState>
  ) {
    let id = ObjectIdentifier(session)
    guard native.withLock({ $0.live[id] != nil }) else { return }
    session.close()
    native.withLock { _ = $0.live.removeValue(forKey: id) }
  }

  /// Settle waiters re-check after a free that no request completion announces.
  private func nativeLifetimeChanged() { resumeSettledWaiters() }

  private func settledCount(_ lane: Lane) -> Int? {
    if let active, active.lane == lane, active.isLoad { return nil }
    if heartQueue.contains(where: { $0.lane == lane && $0.isLoad })
      || previewQueue.contains(where: { $0.lane == lane && $0.isLoad })
    {
      return nil
    }
    let remaining = native.withLock { state in state.live.values.filter { $0.lane == lane }.count }
    return remaining == 0 ? remaining : nil
  }

  private func resumeSettledWaiters() {
    guard !settleWaiters.isEmpty else { return }
    var ready: [(CheckedContinuation<Int, Never>, Int)] = []
    settleWaiters.removeAll { waiter in
      guard let remaining = settledCount(waiter.lane) else { return false }
      ready.append((waiter.continuation, remaining))
      return true
    }
    for (continuation, remaining) in ready { continuation.resume(returning: remaining) }
  }

  // MARK: - Scheduling

  private func submit(_ request: Request) async throws -> Outcome {
    // An already-cancelled caller ends before any lane side effect: a cancelled heart
    // request must never preempt a preview.
    guard !Task.isCancelled else { throw ExecutorError.cancelled }
    if let handleID = Self.handleID(of: request.work) {
      guard sessions[handleID] != nil, !closing.contains(handleID) else {
        throw ExecutorError.modelUnavailable
      }
    }
    if request.lane == .preview, active?.lane == .heart || !heartQueue.isEmpty {
      throw ExecutorError.heartBusy
    }
    return try await enqueueAndWait(request)
  }

  /// Parks the caller until its request ends. Cancelling the caller releases it at once;
  /// a running request keeps occupancy until its native call returns.
  private func enqueueAndWait(_ request: Request) async throws -> Outcome {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        // Runs on the actor with no suspension since `submit`'s checks. A cancellation that
        // landed in between has set the latch (`onCancel` runs at once for a cancelled task).
        if Task.isCancelled || request.isCancelled {
          continuation.resume(throwing: ExecutorError.cancelled)
          return
        }
        request.continuation = continuation
        admit(request)
        pump()
      }
    } onCancel: {
      request.markCancelled()
      Task { await self.cancel(request) }
    }
  }

  /// Queues a live request with its lane's side effects, in the same actor step that
  /// installed its continuation.
  private func admit(_ request: Request) {
    switch request.lane {
    case .preview:
      previewQueue.append(request)
    case .heart:
      for queued in previewQueue {
        queued.preempted = true
        queued.finish(.failure(ExecutorError.preempted))
      }
      previewQueue.removeAll()
      if let active, active.lane == .preview, !active.preempted {
        active.preempted = true
        if let id = Self.handleID(of: active.work) { sessions[id]?.requestAbort() }
      }
      heartQueue.append(request)
    }
    announce()
  }

  private func cancel(_ request: Request) {
    guard request.continuation != nil else { return }
    if heartQueue.contains(where: { $0 === request })
      || previewQueue.contains(where: { $0 === request })
    {
      heartQueue.removeAll { $0 === request }
      previewQueue.removeAll { $0 === request }
      request.finish(.failure(ExecutorError.cancelled))
      announce()
      return
    }
    if active === request {
      if let id = Self.handleID(of: request.work) { sessions[id]?.requestAbort() }
      // Release the caller now; occupancy stays until the native return in `complete`.
      request.finish(.failure(ExecutorError.cancelled))
    }
  }

  private func pump() {
    guard active == nil else { return }
    let next: Request
    if !heartQueue.isEmpty {
      next = heartQueue.removeFirst()
    } else if !previewQueue.isEmpty {
      next = previewQueue.removeFirst()
    } else {
      return
    }
    // A request whose caller already left never runs, even if `cancel` has not reached the
    // actor yet: the latch is set synchronously by the cancellation.
    if next.isCancelled || next.continuation == nil {
      next.finish(.failure(ExecutorError.cancelled))
      announce()
      pump()
      return
    }
    active = next
    announce()
    counters.admitted += 1
    counters.peakOccupancy = max(counters.peakOccupancy, 1)
    let session = Self.handleID(of: next.work).flatMap { sessions[$0] }
    // Clear a stale abort only here: the previous run on this queue has returned, and this
    // request's own cancellation has not happened yet (it would have removed it above).
    session?.clearAbort()
    let work = next.work
    let lane = next.lane
    let makeSession = makeSession
    let native = native
    queue.async {
      // The caller may leave after admission and before the queue reaches this block: then
      // native work never starts (a free is never cancelled, so teardown always runs).
      let outcome =
        next.isCancelled
        ? Outcome.failed(ExecutorError.cancelled)
        : Self.perform(
          work, lane: lane, session: session, makeSession: makeSession, native: native,
          shouldStop: { next.isCancelled })
      Task { await self.complete(next, outcome) }
    }
  }

  private func complete(_ request: Request, _ outcome: Outcome) {
    active = nil
    announce()
    if let id = Self.handleID(of: request.work) {
      for waiter in drainWaiters.removeValue(forKey: id) ?? [] { waiter.resume() }
    }
    counters.completed += 1
    if case .freed = outcome { counters.freed += 1 }
    if request.isCancelled || request.preempted {
      counters.discardedResults += 1
      // A load that completed for a caller who left: free its session exactly once, never
      // leak it. The serial queue runs this close before any work `pump` admits next.
      if case .loaded(let orphan) = outcome {
        let native = native
        queue.async {
          Self.closeAndUnregister(orphan, native: native)
          // #3849: settle waiters re-check after the physical free, not before it.
          Task { await self.nativeLifetimeChanged() }
        }
      }
      request.finish(
        .failure(request.preempted ? ExecutorError.preempted : ExecutorError.cancelled))
    } else if case .failed(let error) = outcome {
      request.finish(.failure(error))
    } else {
      request.finish(.success(outcome))
    }
    pump()
  }

  /// Runs on the dedicated queue: the only place native work happens.
  private static func perform(
    _ work: Work, lane: Lane, session: (any TranscribeCppEngineSession)?,
    makeSession: @Sendable (String) throws -> any TranscribeCppEngineSession,
    native: OSAllocatedUnfairLock<NativeState>,
    shouldStop: @escaping () -> Bool
  ) -> Outcome {
    // #3849: after the quit release began, no native entry; frees still run (idempotent).
    if !work.isFree, native.withLock({ $0.terminating }) {
      return .failed(ExecutorError.modelUnavailable)
    }
    do {
      switch work {
      case .load(let path):
        let opened = try openSession(path, lane: lane, makeSession: makeSession)
        // Registered before anything can close it, so `live` never misses a live session. A
        // load that returns after the quit release began is freed here at once.
        let refused = native.withLock { state -> Bool in
          state.live[ObjectIdentifier(opened)] = LiveSession(session: opened, lane: lane)
          return state.terminating
        }
        guard !refused else {
          closeAndUnregister(opened, native: native)
          return .failed(ExecutorError.modelUnavailable)
        }
        return .loaded(opened)
      case .detect(_, let samples):
        guard let session else { return .failed(ExecutorError.modelUnavailable) }
        return .detected(try session.detectLanguage(samples: samples))
      case .transcribe(_, let samples, let language, let onProgress, let onInferenceEntered):
        guard let session else { return .failed(ExecutorError.modelUnavailable) }
        return .transcribed(
          try session.run(
            samples: samples, language: language, onProgress: onProgress,
            onInferenceEntered: onInferenceEntered, shouldStop: shouldStop))
      case .free:
        if let session { closeAndUnregister(session, native: native) }
        return .freed
      }
    } catch {
      return .failed(error)
    }
  }
}

/// The native operations the executor drives. `TranscribeCppSession` is the production
/// conformer; `requestAbort()` is the only member callable while another call is in flight.
protocol TranscribeCppEngineSession: AnyObject, Sendable {
  func requestAbort()
  func clearAbort()
  func detectLanguage(samples: [Float]) throws -> TranscribeCppLanguageObservation
  func run(
    samples: [Float], language: String?, onProgress: ((Int64, Int64) -> Void)?,
    onInferenceEntered: (() -> Void)?, shouldStop: (() -> Bool)?
  ) throws -> TranscribeCppRunResult
  func close()
}

extension TranscribeCppSession: TranscribeCppEngineSession {}
