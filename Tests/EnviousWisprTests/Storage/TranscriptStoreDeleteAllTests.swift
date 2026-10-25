import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprStorage

/// Delete All moves the History folder away instead of removing it on the main actor (#4001 H7).
/// Every store here lives in a PRIVATE parent folder, because Delete All works on the parent's
/// children and the start-up cleanup lists them.
@MainActor
@Suite(
  "Delete All renames the History folder away and removes it in the background (#4001 H7)",
  .tags(.productOutcome))
struct TranscriptStoreDeleteAllTests {

  // Every test needs the Debug-only fault, pause and await hooks.
  #if DEBUG

    private struct Sandbox {
      let parent: URL
      var directory: URL { parent.appendingPathComponent("transcripts", isDirectory: true) }
      var pending: URL {
        directory.appendingPathComponent(AppConstants.pendingTranscriptsDir, isDirectory: true)
      }

      init() {
        parent = FileManager.default.temporaryDirectory
          .appendingPathComponent("4001-deleteall-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
      }

      @MainActor func store(cleansLeftovers: Bool = false) -> TranscriptStore {
        TranscriptStore(directory: directory, cleansLeftovers: cleansLeftovers)
      }

      func siblings() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? [])
          .filter { $0 != "transcripts" && $0 != AppConstants.transcriptsDeleteAllLockName }
          .sorted()
      }

      func jsonNames(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
          .filter { $0.hasSuffix(".json") }.sorted()
      }

      func remove() {
        try? FileManager.default.removeItem(at: parent)
      }
    }

    private static func row(_ text: String = "hello") -> Transcript {
      Transcript(text: text, processingTime: 0.1, backendType: .parakeet, createdAt: Date())
    }

    private static func heldRow() -> Transcript {
      let now = Date()
      return Transcript(
        text: "held", createdAt: now, escapeRecoveredAt: now, escapeRecoveryTakeID: "TAKE-1")
    }

    private func seeded(_ box: Sandbox) throws -> (TranscriptStore, [String]) {
      let store = box.store()
      let rows = [Self.row("one"), Self.row("two")]
      for row in rows { try store.save(row) }
      try store.savePending(Self.heldRow())
      return (store, rows.map { "\($0.id.uuidString).json" }.sorted())
    }

    // MARK: - Success

    @Test(
      "Delete All leaves an empty, private folder at once, and the old one goes in the background")
    func deleteAllEmptiesAndCleansUp() async throws {
      let box = Sandbox()
      defer { box.remove() }
      let (store, _) = try seeded(box)

      try store.deleteAll()

      #expect(box.jsonNames(in: box.directory).isEmpty)
      #expect(!FileManager.default.fileExists(atPath: box.pending.path))
      let attributes = try FileManager.default.attributesOfItem(atPath: box.directory.path)
      #expect((attributes[.posixPermissions] as? Int) == 0o700)
      #expect(
        FileManager.default.fileExists(
          atPath: box.directory.appendingPathComponent(".metadata_never_index").path))
      #expect(try await store.loadAll().isEmpty)
      #expect(try await store.loadPending().isEmpty)
      await store.deletionCleanupForTesting?.value
      #expect(box.siblings().isEmpty, "the deleting folder is gone once its removal finishes")
    }

    @Test("a row saved right after Delete All survives the background removal")
    func saveAfterDeleteAllSurvives() async throws {
      let box = Sandbox()
      defer { box.remove() }
      let (store, _) = try seeded(box)
      try store.deleteAll()
      let kept = Self.row("after")
      try store.save(kept)
      await store.deletionCleanupForTesting?.value
      #expect(try await store.loadAll().map(\.id) == [kept.id])
    }

    @Test("Delete All with no folder does nothing")
    func missingFolderIsNoOp() throws {
      let box = Sandbox()
      defer { box.remove() }
      let store = box.store()
      try FileManager.default.removeItem(at: box.directory)
      try store.deleteAll()
      #expect(box.siblings().isEmpty)
      #expect(!FileManager.default.fileExists(atPath: box.directory.path))
    }

    @Test("two Delete Alls in a row each finish")
    func repeatedDeleteAll() async throws {
      let box = Sandbox()
      defer { box.remove() }
      let (store, _) = try seeded(box)
      try store.deleteAll()
      let first = store.deletionCleanupForTesting
      try store.save(Self.row())
      try store.deleteAll()
      await first?.value
      await store.deletionCleanupForTesting?.value
      #expect(box.jsonNames(in: box.directory).isEmpty)
      #expect(box.siblings().isEmpty)
    }

    // MARK: - Failures

    @Test("the first rename failing throws and changes nothing")
    func handoffFailureChangesNothing() async throws {
      let box = Sandbox()
      defer { box.remove() }
      let (store, names) = try seeded(box)
      store.deleteAllFaultsForTesting = [.handoff]
      #expect(throws: (any Error).self) { try store.deleteAll() }
      #expect(box.jsonNames(in: box.directory) == names)
      #expect(box.jsonNames(in: box.pending).count == 1)
      #expect(box.siblings().isEmpty)
    }

    @Test("the empty folder failing puts the old folder back and throws")
    func replacementFailureRestores() throws {
      let box = Sandbox()
      defer { box.remove() }
      let (store, names) = try seeded(box)
      store.deleteAllFaultsForTesting = [.replacement]
      #expect(throws: (any Error).self) { try store.deleteAll() }
      #expect(box.jsonNames(in: box.directory) == names)
      #expect(box.jsonNames(in: box.pending).count == 1)
      #expect(box.siblings().isEmpty, "no handoff left behind")
    }

    @Test("clearing for removal failing takes the empty folder away and puts the rows back")
    func clearForRemovalFailureRestores() throws {
      let box = Sandbox()
      defer { box.remove() }
      let (store, names) = try seeded(box)
      store.deleteAllFaultsForTesting = [.clearForRemoval]
      #expect(throws: (any Error).self) { try store.deleteAll() }
      #expect(box.jsonNames(in: box.directory) == names)
      #expect(box.jsonNames(in: box.pending).count == 1)
      #expect(box.siblings().isEmpty)
    }

    @Test(
      "when a row lands in the empty folder first, the next start removes the old rows and keeps the new one"
    )
    func clearForRemovalFailureWithNewRowKeepsBoth() async throws {
      let box = Sandbox()
      defer { box.remove() }
      let (store, names) = try seeded(box)
      let newRow = Self.row("new")
      store.deleteAllFaultsForTesting = [.clearForRemoval]
      store.deleteAllReplacementReadyForTesting = { try? store.save(newRow) }
      #expect(throws: (any Error).self) { try store.deleteAll() }

      #expect(box.jsonNames(in: box.directory) == ["\(newRow.id.uuidString).json"])
      let handoffs = box.siblings().filter { $0.hasPrefix(AppConstants.transcriptsHandoffPrefix) }
      #expect(handoffs.count == 1)
      let handoff = box.parent.appendingPathComponent(handoffs[0], isDirectory: true)
      #expect(box.jsonNames(in: handoff) == names)

      // #4075 G1: the user confirmed Delete All, so the next start finishes it.
      let restarted = box.store(cleansLeftovers: true)
      await restarted.leftoverCleanupForTesting?.value
      #expect(!FileManager.default.fileExists(atPath: handoff.path))
      #expect(box.siblings().isEmpty)
      #expect(box.jsonNames(in: box.directory) == ["\(newRow.id.uuidString).json"])
    }

    @Test(
      "when the empty folder and the way back both fail, the next start removes the handoff folder")
    func restoreFailureKeepsHandoff() async throws {
      let box = Sandbox()
      defer { box.remove() }
      let (store, names) = try seeded(box)
      store.deleteAllFaultsForTesting = [.replacement, .restore]
      #expect(throws: (any Error).self) { try store.deleteAll() }
      let handoffs = box.siblings().filter { $0.hasPrefix(AppConstants.transcriptsHandoffPrefix) }
      #expect(handoffs.count == 1)
      let handoff = box.parent.appendingPathComponent(handoffs[0], isDirectory: true)
      #expect(box.jsonNames(in: handoff) == names)

      let restarted = box.store(cleansLeftovers: true)
      await restarted.leftoverCleanupForTesting?.value
      #expect(!FileManager.default.fileExists(atPath: handoff.path))
      #expect(box.siblings().isEmpty)
      #expect(box.jsonNames(in: box.directory).isEmpty, "History opens empty, as confirmed")
    }

    @Test("while another copy holds the Delete All lock, start-up keeps the handoff and Delete All refuses")
    func startupSkipsHandoffWhileLocked() async throws {
      let box = Sandbox()
      defer { box.remove() }
      let (active, names) = try seeded(box)
      let fm = FileManager.default
      let handoff = box.parent.appendingPathComponent(
        AppConstants.transcriptsHandoffPrefix + UUID().uuidString, isDirectory: true)
      try fm.createDirectory(at: handoff, withIntermediateDirectories: false)
      try Data("x".utf8).write(to: handoff.appendingPathComponent("a.json"))
      // Another app copy's Delete All: the same lock file, taken through a separate open.
      let lockPath = box.parent.appendingPathComponent(
        AppConstants.transcriptsDeleteAllLockName
      ).path
      let holder = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
      try #require(holder >= 0)
      var holderIsOpen = true
      defer {
        if holderIsOpen { close(holder) }
      }
      try #require(flock(holder, LOCK_EX | LOCK_NB) == 0)

      let store = box.store(cleansLeftovers: true)
      await store.leftoverCleanupForTesting?.value
      #expect(fm.fileExists(atPath: handoff.appendingPathComponent("a.json").path))
      // Delete All refuses while the lock is held, before changing anything.
      #expect(throws: (any Error).self) { try active.deleteAll() }
      #expect(box.jsonNames(in: box.directory) == names)
      #expect(box.jsonNames(in: box.pending).count == 1)

      // Released, Delete All works and the next start finishes the leftover handoff.
      close(holder)
      holderIsOpen = false
      try active.deleteAll()
      await active.deletionCleanupForTesting?.value
      #expect(box.jsonNames(in: box.directory).isEmpty)
      let restarted = box.store(cleansLeftovers: true)
      await restarted.leftoverCleanupForTesting?.value
      #expect(!fm.fileExists(atPath: handoff.path))
    }

    // MARK: - Start-up cleanup

    @Test("start-up removes only real folders named exactly like a Delete All's folders")
    func startupCleanupIsStrict() async throws {
      let box = Sandbox()
      defer { box.remove() }
      let fm = FileManager.default
      func folder(_ name: String, withFile: Bool = true) throws -> URL {
        let url = box.parent.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: false)
        if withFile { try Data("x".utf8).write(to: url.appendingPathComponent("a.json")) }
        return url
      }
      let cleared = try folder(AppConstants.transcriptsDeletingPrefix + UUID().uuidString)
      let malformed = try folder(AppConstants.transcriptsDeletingPrefix + "not-a-uuid")
      let malformedHandoff = try folder(AppConstants.transcriptsHandoffPrefix + "not-a-uuid")
      let handoff = try folder(AppConstants.transcriptsHandoffPrefix + UUID().uuidString)
      let unrelated = try folder("Meetings")
      let target = try folder("link-target")
      let link = box.parent.appendingPathComponent(
        AppConstants.transcriptsDeletingPrefix + UUID().uuidString)
      try fm.createSymbolicLink(at: link, withDestinationURL: target)
      let handoffLink = box.parent.appendingPathComponent(
        AppConstants.transcriptsHandoffPrefix + UUID().uuidString)
      try fm.createSymbolicLink(at: handoffLink, withDestinationURL: target)

      let store = box.store(cleansLeftovers: true)
      await store.leftoverCleanupForTesting?.value

      #expect(!fm.fileExists(atPath: cleared.path))
      #expect(!fm.fileExists(atPath: handoff.path), "a leftover handoff is finished (#4075 G1)")
      for kept in [malformed, malformedHandoff, unrelated, target] {
        #expect(
          fm.fileExists(atPath: kept.appendingPathComponent("a.json").path),
          "\(kept.lastPathComponent)")
      }
      #expect(
        (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil,
        "the link is not followed or removed")
      #expect(
        (try? fm.destinationOfSymbolicLink(atPath: handoffLink.path)) != nil,
        "a handoff-named link is not followed or removed")
      #expect(fm.fileExists(atPath: box.directory.path), "the live folder is never touched")
    }

    // MARK: - A meeting write in flight

    @Test(
      "a durable write held open across Delete All fails, and its row reaches neither disk nor History"
    )
    func durableWriteHeldAcrossDeleteAll() async throws {
      let box = Sandbox()
      defer { box.remove() }
      let store = box.store()
      try store.save(Self.row("old"))
      let coordinator = TranscriptCoordinator(store: store)
      coordinator.load()
      await coordinator.waitForLoadForTesting()

      let opened = DispatchSemaphore(value: 0)
      let release = DispatchSemaphore(value: 0)
      store.durableWriteDidOpenForTesting = {
        opened.signal()
        release.wait()
      }
      let meetingRow = Self.row("meeting")
      let write = Task { try await coordinator.saveAndShowDurably(meetingRow) }
      await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().async {
          opened.wait()
          done.resume()
        }
      }

      coordinator.deleteAll()
      await store.deletionCleanupForTesting?.value
      release.signal()

      await #expect(throws: (any Error).self) { try await write.value }
      #expect(coordinator.currentRow(id: meetingRow.id) == nil)
      #expect(coordinator.filteredTranscripts.isEmpty)
      #expect(box.jsonNames(in: box.directory).isEmpty)
      #expect(box.siblings().isEmpty)
    }

  #endif
}
