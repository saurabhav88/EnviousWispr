import EnviousWisprCore
import Foundation

@testable import EnviousWisprPipeline

/// Test-only `PipelineLogging` conformer that lets a test `await` a specific
/// log entry instead of polling for it.
///
/// `TextProcessingRunner` emits log calls from inside fire-and-forget
/// `Task { logger.log(...) }` envelopes. The previous `RecordingPipelineLogger`
/// forced tests to poll (`Task.sleep(10ms)` for up to 500ms) for those
/// envelopes to drain. Under a contended CI runner the envelopes can stall
/// past the 500ms window, so the poll-based assertion flaked (#794).
///
/// `waitForEntry(matching:)` resolves a `CheckedContinuation` the instant a
/// matching entry is logged — no real-time dependency. `@MainActor` isolation
/// makes the "already present?" check and the waiter append atomic, so no
/// entry can slip between them.
@MainActor
final class SignalPipelineLogger: PipelineLogging {
  struct Entry: Equatable {
    let message: String
    let level: DebugLogLevel
    let category: String
  }

  private struct Waiter {
    let id: UUID
    let predicate: (Entry) -> Bool
    let timeoutSeconds: Double
    let continuation: CheckedContinuation<Entry, Error>
  }

  private(set) var entries: [Entry] = []
  private var waiters: [Waiter] = []

  func log(_ message: String, level: DebugLogLevel, category: String) async {
    let entry = Entry(message: message, level: level, category: category)
    entries.append(entry)

    // Resume every waiter whose predicate now matches, removing them first so
    // a later entry cannot resume the same continuation twice.
    let matching = waiters.filter { $0.predicate(entry) }
    waiters.removeAll { waiter in matching.contains { $0.id == waiter.id } }
    for waiter in matching {
      waiter.continuation.resume(returning: entry)
    }
  }

  /// Await the next entry matching `predicate`. Resolves immediately if a
  /// matching entry already exists. Throws `TimeoutError` if no match arrives
  /// within `timeout`.
  func waitForEntry(
    matching predicate: @escaping (Entry) -> Bool,
    timeout: Duration = .seconds(5)
  ) async throws -> Entry {
    if let existing = entries.last(where: predicate) { return existing }

    let id = UUID()
    let seconds =
      Double(timeout.components.seconds)
      + Double(timeout.components.attoseconds) / 1e18
    return try await withCheckedThrowingContinuation { continuation in
      waiters.append(
        Waiter(id: id, predicate: predicate, timeoutSeconds: seconds, continuation: continuation)
      )
      Task { [weak self] in
        try? await Task.sleep(for: timeout)
        await self?.timeoutWaiter(id)
      }
    }
  }

  private func timeoutWaiter(_ id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
    let waiter = waiters.remove(at: index)
    waiter.continuation.resume(throwing: TimeoutError(seconds: waiter.timeoutSeconds))
  }
}
