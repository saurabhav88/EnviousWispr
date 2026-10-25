import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprStorage
import EnviousWisprAppKitTestSupport

/// `TranscriptCoordinator.historyReadFinished` (#4001 H12): what lets a ready meeting's pane say
/// "loading" until History's first read attempt ends, and "could not be opened" after it.
/// Real stores in temp directories.
@MainActor
@Suite("History says when its first read attempt has ended (#4001 H12)", .tags(.productOutcome))
struct HistoryReadFinishedTests {

  private static func makeTempDir() -> URL {
    TestTemporaryDirectory.url
      .appendingPathComponent("4001-readfinished-\(UUID().uuidString)", isDirectory: true)
  }

  @Test("false before any read, true once a read ends")
  func setByAReadThatEnds() async throws {
    let dir = Self.makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try TranscriptStore(directory: dir).save(
      Transcript(text: "one", processingTime: 0.1, backendType: .parakeet, createdAt: Date()))
    let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
    #expect(!coordinator.historyReadFinished)
    coordinator.loadIfNeeded()
    #expect(!coordinator.historyReadFinished, "not while the read is still running")
    await coordinator.waitForLoadForTesting()
    #expect(coordinator.historyReadFinished)
  }

  #if DEBUG
    @Test("a read that throws still ends the attempt")
    func setByAFailedRead() async throws {
      let dir = Self.makeTempDir()
      defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
      }
      let store = TranscriptStore(directory: dir)
      try store.save(
        Transcript(text: "one", processingTime: 0.1, backendType: .parakeet, createdAt: Date()))
      // A folder that cannot be listed makes the read throw.
      try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.path)
      let coordinator = TranscriptCoordinator(store: store)
      coordinator.load()
      await coordinator.waitForLoadForTesting()
      // The read really failed: it published nothing and never reached the merge.
      #expect(coordinator.historyFullReadsForTesting == 0)
      #expect(coordinator.filteredTranscripts.isEmpty)
      #expect(coordinator.historyReadFinished)
    }
  #endif

  @Test("an open that reuses the rows keeps it true")
  func cacheHitKeepsIt() async throws {
    let dir = Self.makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
    coordinator.loadIfNeeded()
    await coordinator.waitForLoadForTesting()
    coordinator.loadIfNeeded()
    await coordinator.waitForLoadForTesting()
    #expect(coordinator.historyReadFinished)
  }

  #if DEBUG
    @Test("a read replaced by a newer one does not end the attempt; only the newer one does")
    func supersededReadDoesNotSetIt() async throws {
      let dir = Self.makeTempDir()
      defer { try? FileManager.default.removeItem(at: dir) }
      let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
      coordinator.load()
      coordinator.load()
      #expect(!coordinator.historyReadFinished)
      await coordinator.waitForLoadForTesting()
      #expect(coordinator.historyReadFinished)
      #expect(coordinator.historyReadEndsForTesting == 1, "the replaced read never counted")
    }
  #endif
}
