import Foundation

/// One FIFO of complete main-actor commands, shared by History (#4075 S1) and the
/// dictionary (#4086). A command prepares against the state earlier commands left, runs
/// its storage work, publishes or handles its failure, and completes its own receipt
/// before the next one starts. Only the drain runs commands. A command never admits
/// another command or waits for one: that would wait on itself.
@MainActor final class SerialCommandDrain {
  private typealias Command = @MainActor () async -> Void

  /// Admitted commands not yet run, in admission order.
  private var commands: [Command] = []
  /// The one retained task that runs `commands`, nil when idle. Not the caller: a caller
  /// cancelled after admission neither withdraws its command nor stops the drain.
  private var drain: Task<Void, Never>?
  /// Callers of `untilIdle()` waiting for the queue to empty.
  private var idleWaiters: [UnsafeContinuation<Void, Never>] = []

  /// Whether a command is running or waiting.
  var isBusy: Bool { drain != nil }

  /// A command's result, kept until its caller reads it, before or after the command ends.
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
  func admit<Value: Sendable>(_ body: @escaping @MainActor () async -> Value) async -> Value {
    await enqueue(body).result()
  }

  /// The synchronous half of `admit`: queues `body` now and returns its receipt, so a
  /// caller can act in the same turn as the admission before it waits.
  func enqueue<Value: Sendable>(_ body: @escaping @MainActor () async -> Value) -> Receipt<Value> {
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
        let waiting = idleWaiters
        idleWaiters = []
        for waiter in waiting { waiter.resume() }
      }
    }
    return receipt
  }

  /// Returns once no command is running or waiting. Commands admitted while this waits
  /// are waited for too: it returns only when the queue is really empty.
  func untilIdle() async {
    guard drain != nil else { return }
    await withUnsafeContinuation { idleWaiters.append($0) }
  }
}
