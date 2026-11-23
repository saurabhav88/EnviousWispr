import EnviousWisprAppKitTestSupport
import Foundation
import Testing
import os

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprStorage

/// #4008 F11: when these fail, History shows a meeting state that is not on disk, an older
/// save answer overwrites a newer one, a failed save leaves the wrong state on screen, or a
/// deleted meeting comes back.
@MainActor
@Suite("MeetingRecordPersistence", .tags(.productOutcome), .timeLimit(.minutes(1)))
struct MeetingRecordPersistenceTests {
  /// What the owner reported, and a write function a test can make fail by title.
  @MainActor
  final class Rig {
    var published = 0
    var failures = 0
    let failTitles = OSAllocatedUnfairLock<Set<String>>(initialState: [])
    let persistence: MeetingRecordPersistence

    init() {
      let failTitles = failTitles
      let store = MeetingStore(
        root: TestTemporaryDirectory.url.appendingPathComponent(
          "MeetingRecordPersistenceTests-\(UUID().uuidString)", isDirectory: true))
      let writer = MeetingFileWriter(
        store: store,
        writeRecord: { _, record in
          if failTitles.withLock({ $0.contains(record.title ?? "") }) {
            throw CocoaError(.fileWriteNoPermission)
          }
        })
      // The events close over the rig, which exists only after the owner; fill them in after.
      var onPublished: @MainActor () -> Void = {}
      var onFailed: @MainActor () -> Void = {}
      persistence = MeetingRecordPersistence(
        writer: writer,
        events: .init(
          published: { onPublished() }, failed: { _ in onFailed() },
          stillRunning: {}))
      onPublished = { [unowned self] in published += 1 }
      onFailed = { [unowned self] in failures += 1 }
    }
  }

  private static func record(_ id: UUID = UUID(), title: String) -> MeetingRecord {
    MeetingRecord(id: id, title: title, engine: .parakeet, trackStatus: [.microphone: .captured])
  }

  @Test("a saved record is shown, and both copies agree")
  func savedRecordIsShown() async {
    let rig = Rig()
    let first = Self.record(title: "First")
    #expect(await rig.persistence.save(first))
    #expect(rig.persistence.records[first.id] == first)
    #expect(rig.persistence.live[first.id] == first)
    #expect(rig.published == 1)
    #expect(rig.failures == 0)
  }

  @Test("a failed save rolls the live copy back to what is on disk and reports once")
  func failedSaveRollsBack() async {
    let rig = Rig()
    let first = Self.record(title: "First")
    #expect(await rig.persistence.save(first))
    var second = first
    second.title = "Second"
    rig.failTitles.withLock { $0 = ["Second"] }
    #expect(await rig.persistence.save(second) == false)
    #expect(rig.persistence.records[first.id]?.title == "First")
    #expect(rig.persistence.live[first.id]?.title == "First")
    #expect(rig.failures == 1)
    #expect(rig.published == 1)
  }

  #if DEBUG
    @Test("an older answer that resumes after a newer write was shown does not replace it")
    func olderAnswerDoesNotOverwriteNewer() async {
      let rig = Rig()
      let first = Self.record(title: "Older")
      var newer = first
      newer.title = "Newer"
      let held = HeldAnswer()
      rig.persistence.writeWillAnswerForTesting = { record in
        if record.title == "Older" { await held.wait() }
      }
      let older = Task { await rig.persistence.save(first) }
      await held.waitUntilParked()
      #expect(held.parked, "the held write never reached its answer")
      #expect(await rig.persistence.save(newer))
      held.open()
      #expect(await older.value)
      #expect(rig.persistence.records[first.id]?.title == "Newer")
      #expect(rig.persistence.live[first.id]?.title == "Newer")
      #expect(rig.published == 1, "the older answer was not shown")
    }

    @Test("a meeting removed while its save is unanswered is not brought back")
    func removedMeetingStaysRemoved() async {
      let rig = Rig()
      let first = Self.record(title: "Gone")
      let held = HeldAnswer()
      rig.persistence.writeWillAnswerForTesting = { _ in await held.wait() }
      let saving = Task { await rig.persistence.save(first) }
      await held.waitUntilParked()
      #expect(held.parked, "the held write never reached its answer")
      rig.persistence.remove(first.id)
      held.open()
      _ = await saving.value
      #expect(rig.persistence.records[first.id] == nil)
      #expect(rig.persistence.live[first.id] == nil)
    }
  #endif

  @Test("a bounded save that lands in time is shown; one that fails rolls back")
  func boundedSaveLandsOrRollsBack() async {
    let rig = Rig()
    let first = Self.record(title: "First")
    let landed = rig.persistence.saveBounded(first, until: .now() + 5)
    #expect(landed)
    #expect(rig.persistence.records[first.id]?.title == "First")
    var second = first
    second.title = "Second"
    rig.failTitles.withLock { $0 = ["Second"] }
    let failed = await rig.persistence.saveWithin(second, until: .now() + 5)
    #expect(failed == false)
    #expect(rig.persistence.live[first.id]?.title == "First")
    #expect(rig.failures == 1)
  }

  @Test("adopt sets both copies and remove clears both")
  func adoptAndRemove() {
    let rig = Rig()
    let record = Self.record(title: "Listed")
    rig.persistence.adopt(record)
    #expect(rig.persistence.live[record.id] == record)
    #expect(rig.persistence.records[record.id] == record)
    rig.persistence.remove(record.id)
    #expect(rig.persistence.live[record.id] == nil)
    #expect(rig.persistence.records[record.id] == nil)
  }

  /// Holds an answer until the test opens it.
  @MainActor
  final class HeldAnswer {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    private(set) var parked = false

    private var parkedWaiter: CheckedContinuation<Void, Never>?

    func wait() async {
      if opened { return }
      await withCheckedContinuation { continuation in
        self.continuation = continuation
        parked = true
        parkedWaiter?.resume()
        parkedWaiter = nil
      }
    }

    /// Returns once `wait()` has parked, by the parker's own signal. A hook that never arrives
    /// ends the wait after a hang guard (not a measured time); the caller then fails on
    /// `parked`.
    func waitUntilParked() async {
      if parked { return }
      await withCheckedContinuation { continuation in
        parkedWaiter = continuation
        Task { [weak self] in
          try? await Task.sleep(for: .seconds(20))
          self?.parkedWaiter?.resume()
          self?.parkedWaiter = nil
        }
      }
    }

    func open() {
      opened = true
      continuation?.resume()
      continuation = nil
    }
  }
}
