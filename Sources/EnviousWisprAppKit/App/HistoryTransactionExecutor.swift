import EnviousWisprCore
import EnviousWisprStorage
import Foundation

@MainActor final class HistoryTransactionExecutor {
  private let store: TranscriptStore
  /// #4075 S1: the one serial queue History's blocking file work runs on, off the main actor
  /// and in the order it was asked for. Work sent here captures only Sendable values and
  /// storage operations, never `store` itself, which is main-actor state.
  private let storageWorker = DispatchQueue(label: "com.enviouswispr.history.files", qos: .utility)

  /// #3972 C4a: a row whose durable meeting write is in flight. Ordinary writes to it are
  /// refused until it lands, so neither write can publish over the other on disk or in the list.
  private var durableWritesInFlight: Set<UUID> = []

  init(store: TranscriptStore) {
    self.store = store
  }

  func isDurableWriteInFlight(_ id: UUID) -> Bool {
    durableWritesInFlight.contains(id)
  }

  func reserveDurableWrite(_ id: UUID) {
    durableWritesInFlight.insert(id)
  }

  func finishDurableWrite(_ id: UUID) {
    durableWritesInFlight.remove(id)
  }

  func write(_ transcript: Transcript) async throws {
    let operations = store.operations()
    #if DEBUG
      let willWrite = ordinaryWriteWillStartForTesting
    #endif
    #if DEBUG
      let didWrite = ordinaryWriteDidFinishForTesting
    #endif
    try await runOnStorageWorker {
      #if DEBUG
        willWrite?()
      #endif
      try operations.save(transcript)
      #if DEBUG
        didWrite?()
      #endif
    }
  }

  func writeDurably(_ transcript: Transcript) async throws {
    let write = store.durableWriter()
    #if DEBUG
      let willWrite = durableWriteWillStartForTesting
    #endif
    // On the storage worker, not a plain Task: this type is @MainActor and a plain Task inherits
    // it, while the write encodes and blocks on two disk flushes. Awaited at once, so it neither
    // outlives nor reorders the commit. Once sent it runs to its end, so a cancelled caller
    // still gets the real result and the bookkeeping below.
    try await runOnStorageWorker {
      #if DEBUG
        willWrite?()
      #endif
      try write(transcript)
    }
  }

  func remove(id: UUID) async throws -> Bool {
    let operations = store.operations()
    return try await runOnStorageWorker { try operations.remove(id: id) }
  }

  func promote(id: UUID, now: Date) async throws -> Promotion? {
    let operations = store.operations()
    return try await runOnStorageWorker {
      try operations.promote(id: id, now: now).map { Promotion($0.pending, $0.promoted) }
    }
  }

  func deleteAll() throws {
    try store.deleteAll()
  }

  /// What a Keep's storage work confirmed: the pending row it judged live, and the permanent
  /// row it wrote.
  struct Promotion: Sendable {
    let pending: Transcript
    let promoted: Transcript
    init(_ pending: Transcript, _ promoted: Transcript) {
      self.pending = pending
      self.promoted = promoted
    }
  }

  /// Runs `work` on the storage worker and resumes with its result. The main actor is never
  /// blocked waiting for it, and caller cancellation does not withdraw work already sent.
  /// #3973 C2: one permanent row as its file holds it now (`TranscriptStore.rowReader`).
  func readRow(id: UUID) async throws -> Transcript? {
    let read = store.rowReader()
    return try await runOnStorageWorker { try read(id) }
  }

  private func runOnStorageWorker<T: Sendable>(
    _ work: @escaping @Sendable () throws -> T
  ) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      storageWorker.async { continuation.resume(with: Result { try work() }) }
    }
  }

  // MARK: - History transaction queue (#4075 S1)

  /// The FIFO every History command runs through. Its mechanism and reasons live in
  /// `SerialCommandDrain`, shared with the dictionary (#4086).
  private let commands = SerialCommandDrain()

  /// Admits `body` behind every earlier command, synchronously, before the caller first
  /// suspends, and returns its result once it has run.
  func admit<Value: Sendable>(_ body: @escaping @MainActor () async -> Value) async
    -> Value
  {
    let receipt = commands.enqueue(body)
    #if DEBUG
      commandsAdmittedForTesting += 1
      didAdmitForTesting?(commandsAdmittedForTesting)
    #endif
    return await receipt.result()
  }

  func capture<Value: Sendable>(_ work: () async throws -> Value) async -> Result<
    Value, any Error
  > {
    do { return .success(try await work()) } catch { return .failure(error) }
  }

  #if DEBUG
    /// Runs on the durable write's worker thread just before it writes, so a test can hold a
    /// write while it is registered in flight.
    var durableWriteWillStartForTesting: (@Sendable () -> Void)?
    /// Commands admitted so far, so a test knows a caller reached the queue.
    private(set) var commandsAdmittedForTesting = 0
    /// Told the new count after each admission, so a test waits on the admission itself.
    var didAdmitForTesting: (@MainActor (Int) -> Void)?
    /// Runs on the storage worker just before an ordinary write, so a test can hold one.
    var ordinaryWriteWillStartForTesting: (@Sendable () -> Void)?
    /// Runs on the storage worker just after an ordinary write's file landed, before its
    /// publication, so a test can hold that window.
    var ordinaryWriteDidFinishForTesting: (@Sendable () -> Void)?
    /// Whether a command is running or waiting.
    var hasQueuedCommandsForTesting: Bool { commands.isBusy }
  #endif
}
