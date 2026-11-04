import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprLLM

/// #4353 D6: the synchronous list menus and telemetry read.
///
/// When this fails a menu shows rules from a list the app no longer uses, an older answer
/// replaces a newer one on screen, or a refresh failure empties the list.
@Suite("Cloud model list holder (#4353)", .tags(.productOutcome), .timeLimit(.minutes(1)))
@MainActor
struct CloudModelListHolderTests {
  private typealias Fixtures = CloudModelListStoreTests

  @MainActor final class Lines { var all: [String] = [] }

  @Test("starts from the store's launch choice, then publishes a newer fetch whole")
  func publishesNewerSnapshot() async throws {
    let folder = Fixtures.Folder()
    defer { folder.remove() }
    let bundled = Fixtures.document(updated: "2026-11-01")
    let fetched = try Fixtures.list(Fixtures.document(updated: "2026-11-05", ids: ["claude-row-z"]))
    let store = Fixtures.store(
      bundled: bundled, folder: folder, fetch: Fixtures.FakeFetch([.success(fetched)]))
    let lines = Lines()
    let holder = CloudModelListHolder(store: store, log: { lines.all.append($0) })

    #expect(holder.snapshot == store.initialSnapshot)
    #expect(holder.snapshot?.source == .bundled)
    let held = try #require(holder.snapshot)

    await holder.refresh()
    #expect(holder.snapshot?.source == .fresh)
    #expect(holder.snapshot?.list.revision == fetched.revision)
    #expect(held.list.documentBytes == bundled, "an earlier capture keeps its list")
    #expect(lines.all.contains { $0.contains("fetched revision=\(fetched.revision)") })
  }

  @Test("a failed refresh keeps the list on screen and an older publication is refused")
  func failureAndStaleOutcomesKeepTheShownList() async throws {
    let folder = Fixtures.Folder()
    defer { folder.remove() }
    let store = Fixtures.store(
      bundled: Fixtures.document(updated: "2026-11-01"), folder: folder,
      fetch: Fixtures.FakeFetch([.failure(CloudModelListClient.FetchError.httpStatus(503))]))
    let lines = Lines()
    let holder = CloudModelListHolder(store: store, log: { lines.all.append($0) })
    let shown = holder.snapshot

    await holder.refresh()
    #expect(holder.snapshot == shown)
    #expect(lines.all.contains { $0.contains("fetch failed, keeping bundled") })

    let newer = CloudModelListSnapshot(
      list: try Fixtures.list(Fixtures.document(updated: "2026-11-09")), source: .fresh,
      sequence: 5)
    holder.apply(.init(snapshot: newer, result: .fetched(.written)))
    let older = CloudModelListSnapshot(
      list: try Fixtures.list(Fixtures.document(updated: "2026-11-02")), source: .fresh,
      sequence: 4)
    holder.apply(.init(snapshot: older, result: .fetched(.written)))
    #expect(holder.snapshot == newer)
  }

  @Test("start logs the local choice once and returns without waiting for the network")
  func startReturnsAtOnce() async throws {
    let folder = Fixtures.Folder()
    defer { folder.remove() }
    let gate = Fixtures.Gate()
    let fetch = Fixtures.FakeFetch(
      [.success(try Fixtures.list(Fixtures.document(updated: "2026-11-05")))], gate: gate)
    let store = Fixtures.store(
      bundled: Fixtures.document(updated: "2026-11-01"), folder: folder, fetch: fetch)
    let lines = Lines()
    let holder = CloudModelListHolder(store: store, log: { lines.all.append($0) })
    let center = NotificationCenter()

    holder.start(notificationCenter: center)
    // The launch fetch is still held open, so start() returned before the network answered.
    #expect(holder.snapshot?.source == .bundled)
    #expect(lines.all.first?.hasPrefix("cloud model list: source=bundled") == true)
    await gate.waitUntilEntered()
    await gate.release()
    #expect(fetch.count == 1)
  }
}
