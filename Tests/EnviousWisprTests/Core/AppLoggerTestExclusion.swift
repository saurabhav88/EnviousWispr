import Foundation

/// Cross-SUITE exclusion for the process-wide `AppLogger.shared`.
///
/// `.serialized` orders tests within ONE suite and nothing more, but three
/// separate suites toggle this singleton — `AppLoggerPreSinkBufferTests`,
/// `AppLoggerLaunchSyncTests`, and `AppLoggerCompileOutTests`. Under the default
/// parallel run they interleave at every `await`, so one suite enabling the sink
/// can flush and empty another's pre-sink buffer, or restore a debug mode out
/// from under an assertion. Swift Testing has no cross-suite mutex, so this is
/// it.
///
/// Same family as `swift-patterns.md` RULE: tests-no-process-global-mutable-delegate:
/// a process global mutated across an `await` is not safe merely because each
/// test tidies up after itself.
///
/// Fair FIFO, so a suite cannot be starved by a busy neighbour.
actor AppLoggerTestExclusion {
  static let shared = AppLoggerTestExclusion()

  private var held = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  private init() {}

  func acquire() async {
    if !held {
      held = true
      return
    }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      waiters.append(continuation)
    }
  }

  func release() {
    if waiters.isEmpty {
      held = false
    } else {
      // Stays `held`; ownership passes straight to the next waiter.
      waiters.removeFirst().resume()
    }
  }

}

/// Runs `body` with exclusive access to `AppLogger.shared`.
///
/// Free function, NOT a method on the actor: as a method the caller's closure
/// would have to be sent across the actor boundary, and a `@MainActor` test body
/// is not `Sendable` ("sending value of non-Sendable type risks causing data
/// races"). Keeping only `acquire`/`release` on the actor lets `body` run in
/// whatever isolation the caller already has.
///
/// Releases on the throwing path too — a leaked hold would deadlock every other
/// AppLogger suite for the rest of the run.
/// `isolation: isolated (any Actor)? = #isolation` makes this INHERIT the
/// caller's isolation instead of hopping off it. Without it a `@MainActor` suite
/// (`AppLoggerLaunchSyncTests`) cannot pass its body at all: the closure is
/// MainActor-isolated, therefore non-Sendable, and sending it to a nonisolated
/// generic function is a Swift 6 error.
func withAppLoggerExclusion<T>(
  isolation: isolated (any Actor)? = #isolation,
  _ body: () async throws -> T
) async rethrows -> T {
  await AppLoggerTestExclusion.shared.acquire()
  do {
    let value = try await body()
    await AppLoggerTestExclusion.shared.release()
    return value
  } catch {
    await AppLoggerTestExclusion.shared.release()
    throw error
  }
}
