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
  private func runOnStorageWorker<T: Sendable>(
    _ work: @escaping @Sendable () throws -> T
  ) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      storageWorker.async { continuation.resume(with: Result { try work() }) }
    }
  }

  // MARK: - History transaction queue (#4075 S1)

  /// One admitted History command. It prepares against the state earlier commands left, runs
  /// its storage work, publishes or handles its failure, and completes its own receipt. Only
  /// the drain runs it. A command never admits another command or waits for one.
  private typealias HistoryCommand = @MainActor () async -> Void

  /// Admitted commands not yet run, in admission order.
  private var commands: [HistoryCommand] = []
  /// The one retained task that runs `commands`, nil when idle. Not the caller: a caller
  /// cancelled after admission neither withdraws its command nor stops the drain.
  private var drain: Task<Void, Never>?

  /// A command's result, kept until its caller reads it, before or after the command ends.
  /// Internal, not private, so a test can drive this one implementation directly.
  ///
  /// Unsafe continuations on purpose (#3925): with `withCheckedContinuation` here, this `-O`
  /// module carried its own copy of that emit-into-client function, and the Release test lane
  /// crashed `LiveMediaPlaybackEffectsTests` (`-Onone`) inside its own call to it,
  /// `EXC_BAD_ACCESS`, on CI and locally (Xcode 27.1, 27A9275; PR #4095). `complete` resumes
  /// each waiter once and clears the list, so a waiter is never resumed twice.
  @MainActor final class Receipt<Value: Sendable> {
    private var value: Value?
    private var waiters: [UnsafeContinuation<Value, Never>] = []

    func complete(_ result: Value) {
      value = result
      let ready = waiters
      waiters = []
      for waiter in ready { waiter.resume(returning: result) }
    }

    func result() async -> Value {
      if let value { return value }
      return await withUnsafeContinuation { waiters.append($0) }
    }
  }

  /// Admits `body` behind every earlier command, synchronously, before the caller first
  /// suspends, and returns its result once it has run.
  func admit<Value: Sendable>(_ body: @escaping @MainActor () async -> Value) async
    -> Value
  {
    let receipt = Receipt<Value>()
    commands.append { receipt.complete(await body()) }
    if drain == nil {
      drain = Task { @MainActor [self] in
        while !commands.isEmpty {
          let head = commands.removeFirst()
          await head()
        }
        // The same turn as the empty check above, so nothing can be admitted in between.
        drain = nil
      }
    }
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
    var hasQueuedCommandsForTesting: Bool { drain != nil }
  #endif
}
