import Foundation
import Testing

@testable import EnviousWisprAppKit

#if DEBUG
  /// #4586 package I: a full re-check waits only for the History page reads that were already
  /// waiting when it asked, so the first page reaches the catalog first and a stream of later
  /// reads can never hold the re-check back.
  @MainActor
  @Suite(
    "History re-check waits only for page reads already waiting", .tags(.productOutcome),
    .timeLimit(.minutes(1)))
  struct HistoryPageReadsTests {
    @MainActor
    private final class Done {
      var value = false
    }

    private func waitUntilRegistered(_ reads: HistoryPageReads) async throws {
      while reads.waiterCountForTesting == 0 {
        try Task.checkCancellation()
        await Task.yield()
      }
    }

    private func waitUntil(_ done: Done) async throws {
      while done.value == false {
        try Task.checkCancellation()
        await Task.yield()
      }
    }

    @Test("Nothing waiting: the re-check goes at once")
    func emptySnapshot() async {
      let reads = HistoryPageReads()
      #expect(await reads.waitForActive() == false)
    }

    @Test("Reads finishing out of order release the re-check only after the last one")
    func outOfOrderCompletion() async throws {
      let reads = HistoryPageReads()
      let first = reads.begin()
      let second = reads.begin()
      let done = Done()
      let pass = Task {
        _ = await reads.waitForActive()
        done.value = true
      }
      defer { pass.cancel() }
      try await waitUntilRegistered(reads)
      reads.end(second)
      await Task.yield()
      #expect(done.value == false)
      reads.end(first)
      try await waitUntil(done)
      #expect(reads.waiterCountForTesting == 0)
    }

    @Test("A read that starts after the re-check asked does not hold it back")
    func laterReadExcluded() async throws {
      let reads = HistoryPageReads()
      let early = reads.begin()
      let done = Done()
      let pass = Task {
        _ = await reads.waitForActive()
        done.value = true
      }
      defer { pass.cancel() }
      try await waitUntilRegistered(reads)
      let late = reads.begin()
      reads.end(early)
      try await waitUntil(done)
      reads.end(late)
    }

    @Test("Cancelling the re-check ends its wait, before or after it registers")
    func cancellation() async throws {
      let reads = HistoryPageReads()
      let held = reads.begin()
      defer { reads.end(held) }

      let registered = Done()
      let after = Task {
        _ = await reads.waitForActive()
        registered.value = true
      }
      try await waitUntilRegistered(reads)
      after.cancel()
      try await waitUntil(registered)
      #expect(reads.waiterCountForTesting == 0)

      let early = Done()
      let before = Task {
        _ = await reads.waitForActive()
        early.value = true
      }
      before.cancel()
      try await waitUntil(early)
      #expect(reads.waiterCountForTesting == 0)
    }
  }
#endif
