import Foundation
import os

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
      onProgress: (@Sendable (Int64, Int64) -> Void)?)
    case free(ModelHandle)
  }

  private static func handleID(of work: Work) -> UUID? {
    switch work {
    case .load: nil
    case .detect(let handle, _), .transcribe(let handle, _, _, _), .free(let handle): handle.id
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
  private var heartQueue: [Request] = []
  private var previewQueue: [Request] = []
  private var active: Request?
  private(set) var counters = Counters()

  /// Queued request counts, for tests.
  struct QueueDepths: Sendable, Equatable {
    let heart: Int
    let preview: Int
    let running: Bool
  }

  var queueDepths: QueueDepths {
    QueueDepths(heart: heartQueue.count, preview: previewQueue.count, running: active != nil)
  }

  /// Test seam: announced synchronously on the actor whenever the queues or the running
  /// request change, so a test waits for the state itself instead of polling the actor.
  private var stateObserver: (@Sendable (QueueDepths) -> Void)?

  func setStateObserver(_ observer: (@Sendable (QueueDepths) -> Void)?) {
    stateObserver = observer
    observer?(queueDepths)
  }

  private func announce() { stateObserver?(queueDepths) }

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

  public func transcribe(
    _ handle: ModelHandle, samples: [Float], language: String?, lane: Lane,
    onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
  ) async throws -> TranscribeCppRunResult {
    guard
      case .transcribed(let result) = try await submit(
        Request(
          lane: lane,
          work: .transcribe(handle, samples: samples, language: language, onProgress: onProgress)))
    else { throw ExecutorError.modelUnavailable }
    return result
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
    let makeSession = makeSession
    queue.async {
      // The caller may leave after admission and before the queue reaches this block: then
      // native work never starts (a free is never cancelled, so teardown always runs).
      let outcome =
        next.isCancelled
        ? Outcome.failed(ExecutorError.cancelled)
        : Self.perform(work, session: session, makeSession: makeSession)
      Task { await self.complete(next, outcome) }
    }
  }

  private func complete(_ request: Request, _ outcome: Outcome) {
    active = nil
    announce()
    counters.completed += 1
    if case .freed = outcome { counters.freed += 1 }
    if request.isCancelled || request.preempted {
      counters.discardedResults += 1
      // A load that completed for a caller who left: free its session exactly once, never
      // leak it. The serial queue runs this close before any work `pump` admits next.
      if case .loaded(let orphan) = outcome { queue.async { orphan.close() } }
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
    _ work: Work, session: (any TranscribeCppEngineSession)?,
    makeSession: @Sendable (String) throws -> any TranscribeCppEngineSession
  ) -> Outcome {
    do {
      switch work {
      case .load(let path):
        return .loaded(try makeSession(path))
      case .detect(_, let samples):
        guard let session else { return .failed(ExecutorError.modelUnavailable) }
        return .detected(try session.detectLanguage(samples: samples))
      case .transcribe(_, let samples, let language, let onProgress):
        guard let session else { return .failed(ExecutorError.modelUnavailable) }
        return .transcribed(
          try session.run(samples: samples, language: language, onProgress: onProgress))
      case .free:
        session?.close()
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
    samples: [Float], language: String?, onProgress: ((Int64, Int64) -> Void)?
  ) throws -> TranscribeCppRunResult
  func close()
}

extension TranscribeCppSession: TranscribeCppEngineSession {}
