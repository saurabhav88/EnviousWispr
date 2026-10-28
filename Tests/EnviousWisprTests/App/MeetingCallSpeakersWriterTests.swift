import Dispatch
import EnviousWisprAppKitTestSupport
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprStorage

/// #4013 r2 item 3: the call-speaker evidence goes through the one meeting file queue. When these
/// fail, a save that waited behind Delete meeting or Delete audio brings the evidence back.
/// Serialized: it holds the one process-wide writer queue with a gate.
@Suite("Meeting call-speaker evidence on the file queue", .serialized, .tags(.productOutcome))
struct MeetingCallSpeakersWriterTests {

  /// Holds the writer queue until released; `entered` says the hold has started.
  private final class Gate: Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    func hold() {
      entered.signal()
      // settle: deadline fallback only; a failing test must not strand the shared queue.
      _ = release.wait(timeout: .now() + 10)
    }

    func waitEntered() async -> Bool {
      // settle: deadline fallback around the gated block's own `entered` signal.
      await Task.detached { [entered] in Self.waitBlocking(entered) == .success }.value
    }

    /// A synchronous wait, called only from a detached task so no actor is blocked.
    // settle: deadline fallback around a semaphore the gated block signals.
    nonisolated static func waitBlocking(_ semaphore: DispatchSemaphore) -> DispatchTimeoutResult {
      semaphore.wait(timeout: .now() + 10)
    }
  }

  /// Results of blocks queued in a fixed order behind the gate.
  private final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Result<Void, Error>] = [:]
    func set(_ key: String, _ body: () throws -> Void) {
      let result = Result { try body() }
      lock.withLock { values[key] = result }
    }
    func get(_ key: String) -> Result<Void, Error>? { lock.withLock { values[key] } }
  }

  private static let log = CallSpeakerLog(
    surface: .zoomApp, source: .app, status: .observed, lag: nil, rules: nil,
    roster: CallSpeakerRoster(names: ["Alex Rivera"], selfNames: []),
    rosterFromParticipantList: true,
    observations: [CallSpeakerObservation(observationMs: 400, speaking: ["Alex Rivera"])])

  private func makeMeeting() throws -> (MeetingFileWriter, MeetingRecord) {
    let root = TestTemporaryDirectory.url
      .appendingPathComponent("ew-4013-writer-\(UUID().uuidString)", isDirectory: true)
    let store = MeetingStore(root: root)
    let record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    try store.create(record)
    return (MeetingFileWriter(store: store, writeRecord: { try $0.save($1) }), record)
  }

  @Test("a save queued before Delete meeting lands first; a later save cannot recreate the folder")
  func saveRacingDeleteMeeting() async throws {
    let (writer, record) = try makeMeeting()
    let gate = Gate()
    MeetingFileWriter.queue.async { gate.hold() }
    try #require(await gate.waitEntered(), "the queue was never held")

    // Queued directly, so the order behind the gate is exactly this one.
    let store = writer.store
    let results = Results()
    MeetingFileWriter.queue.async {
      results.set("save") { try store.saveCallSpeakers(Self.log, meeting: record.id) }
    }
    MeetingFileWriter.queue.async {
      results.set("delete") { try store.deleteFolder(meeting: record.id) }
    }
    gate.release.signal()
    _ = try await writer.run { _ in }
    #expect((try? results.get("save")?.get()) != nil, "the earlier save landed")
    #expect((try? results.get("delete")?.get()) != nil)

    let folder = writer.store.folder(for: record.id)
    #expect(FileManager.default.fileExists(atPath: folder.path) == false)
    await #expect(throws: MeetingStore.CallSpeakersError.meetingMissing) {
      try await writer.saveCallSpeakers(Self.log, meeting: record.id)
    }
    #expect(FileManager.default.fileExists(atPath: folder.path) == false)
    #expect(try await writer.loadCallSpeakers(meeting: record.id) == .absent)
  }

  @Test("after Delete audio is saved and done, a waiting save is refused and leaves nothing")
  func saveAfterDeleteAudio() async throws {
    let (writer, record) = try makeMeeting()
    try await writer.saveCallSpeakers(Self.log, meeting: record.id)

    let gate = Gate()
    MeetingFileWriter.queue.async { gate.hold() }
    try #require(await gate.waitEntered(), "the queue was never held")
    // The coordinator's order: the record says the audio is gone, then the files go; a flush
    // that was waiting comes after both.
    let marked = {
      var copy = record
      copy.audioKept = false
      return copy
    }()
    let store = writer.store
    let results = Results()
    MeetingFileWriter.queue.async { results.set("mark") { try store.save(marked) } }
    MeetingFileWriter.queue.async {
      results.set("remove") { try store.deleteAudio(meeting: record.id) }
    }
    MeetingFileWriter.queue.async {
      results.set("late") { try store.saveCallSpeakers(Self.log, meeting: record.id) }
    }
    gate.release.signal()
    _ = try await writer.run { _ in }
    #expect((try? results.get("mark")?.get()) != nil)
    #expect((try? results.get("remove")?.get()) != nil)
    #expect(throws: MeetingStore.CallSpeakersError.audioDeleted) {
      try results.get("late")?.get()
    }

    #expect(try await writer.loadCallSpeakers(meeting: record.id) == .absent)
    #expect(FileManager.default.fileExists(atPath: writer.store.recordURL(for: record.id).path))
  }
}
