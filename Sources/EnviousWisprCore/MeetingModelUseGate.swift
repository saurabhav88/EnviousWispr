import Foundation

/// Keeps a Parakeet install's files from being replaced or deleted while EnviousMeet's own
/// engine uses them (#3972 R26).
///
/// Keyed by install directory (`key(forInstallDirectory:)`), so a meeting using one model never
/// delays a change to another one (retiring Ultra while a meeting reads v3, for example).
///
/// Per key, two groups that exclude each other: meeting USE (from before the meeting engine
/// loads until after it unloads) and install MUTATION (validation removal, promotion, legacy
/// migration, retirement, Remove). Members of one group never exclude each other, so a mutation
/// that waits on another mutation's drain can never deadlock here; serializing mutations against
/// each other stays the delivery controller's job. A mutation closes meeting admission for its
/// key the moment it asks (before it waits for current use to end), so no new meeting load can
/// start between "unloaded" and the change. A waiting mutation can be cancelled (a user's Cancel
/// must not hang behind a meeting); its claim is withdrawn and meeting admission reopens.
public actor MeetingModelUseGate {
  private var uses: [String: Int] = [:]
  private var mutations: [String: Int] = [:]
  private var mutationsWaiting: [String: Int] = [:]
  private var useWaiters: [UUID: (key: String, continuation: CheckedContinuation<Void, Never>)] = [:]
  private var mutationWaiters:
    [UUID: (key: String, continuation: CheckedContinuation<Void, Never>)] =
      [:]
  private var mutationRequestWatchers: [CheckedContinuation<Void, Never>] = []

  public init() {}

  /// The key for an install directory: its standardized path.
  public static func key(forInstallDirectory directory: URL) -> String {
    directory.standardizedFileURL.path
  }

  /// Waits while any mutation of `key` runs or is waiting, then counts one use. Throws
  /// `CancellationError` when the caller is cancelled before the use is granted; nothing is then
  /// counted. A caller cancelled after this returned holds the use and must end it.
  public func beginUse(_ key: String) async throws {
    try Task.checkCancellation()
    while (mutations[key] ?? 0) > 0 || (mutationsWaiting[key] ?? 0) > 0 {
      let id = UUID()
      await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
          useWaiters[id] = (key, continuation)
        }
      } onCancel: {
        Task { await self.resumeUseWaiter(id) }
      }
      try Task.checkCancellation()
    }
    uses[key, default: 0] += 1
  }

  public func endUse(_ key: String) {
    guard let count = uses[key], count > 0 else { return }
    uses[key] = count - 1
    if count == 1 { resumeMutationWaiters(for: key) }
  }

  /// Closes meeting admission for `key` at once, waits for its current use to end, then counts
  /// one mutation. Throws `CancellationError` when cancelled while waiting; the claim is then
  /// withdrawn as if it had never been made.
  public func beginMutation(_ key: String) async throws {
    try Task.checkCancellation()
    mutationsWaiting[key, default: 0] += 1
    let watchers = mutationRequestWatchers
    mutationRequestWatchers.removeAll()
    watchers.forEach { $0.resume() }
    while (uses[key] ?? 0) > 0 {
      if Task.isCancelled {
        withdrawWaitingMutation(key)
        throw CancellationError()
      }
      let id = UUID()
      await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
          mutationWaiters[id] = (key, continuation)
        }
      } onCancel: {
        Task { await self.resumeMutationWaiter(id) }
      }
    }
    // The last use can end in the same moment the caller is cancelled: never grant then.
    if Task.isCancelled {
      withdrawWaitingMutation(key)
      throw CancellationError()
    }
    mutationsWaiting[key, default: 0] -= 1
    mutations[key, default: 0] += 1
  }

  public func endMutation(_ key: String) {
    guard let count = mutations[key], count > 0 else { return }
    mutations[key] = count - 1
    reopenUseIfClear(key)
  }

  public func isInUse(_ key: String) -> Bool { (uses[key] ?? 0) > 0 }

  /// Returns once any mutation has asked for the gate (waiting or running). Tests use it to know
  /// a change is parked behind a meeting's use without polling.
  public func waitForMutationRequest() async {
    while mutationsWaiting.values.allSatisfy({ $0 == 0 })
      && mutations.values.allSatisfy({ $0 == 0 })
    {
      await withCheckedContinuation { mutationRequestWatchers.append($0) }
    }
  }

  private func withdrawWaitingMutation(_ key: String) {
    mutationsWaiting[key, default: 0] -= 1
    reopenUseIfClear(key)
  }

  private func reopenUseIfClear(_ key: String) {
    guard (mutations[key] ?? 0) == 0, (mutationsWaiting[key] ?? 0) == 0 else { return }
    let ready = useWaiters.filter { $0.value.key == key }
    for (id, waiter) in ready {
      useWaiters.removeValue(forKey: id)
      waiter.continuation.resume()
    }
  }

  private func resumeMutationWaiters(for key: String) {
    let ready = mutationWaiters.filter { $0.value.key == key }
    for (id, waiter) in ready {
      mutationWaiters.removeValue(forKey: id)
      waiter.continuation.resume()
    }
  }

  private func resumeUseWaiter(_ id: UUID) {
    useWaiters.removeValue(forKey: id)?.continuation.resume()
  }

  private func resumeMutationWaiter(_ id: UUID) {
    mutationWaiters.removeValue(forKey: id)?.continuation.resume()
  }
}
