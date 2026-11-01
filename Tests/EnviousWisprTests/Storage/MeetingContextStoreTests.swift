import EnviousWisprAppKitTestSupport
import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprStorage

/// #4286: when these fail, a meeting's saved invite facts are lost or changed, a damaged
/// `context.json` is overwritten, or a late save recreates a deleted meeting's files.
@Suite("Meeting context storage (#4286)", .tags(.productOutcome))
struct MeetingContextStoreTests {

  private func makeStore() -> MeetingStore {
    MeetingStore(
      root: TestTemporaryDirectory.url
        .appendingPathComponent("MeetingContextStoreTests-\(UUID().uuidString)", isDirectory: true))
  }

  private func makeMeeting(_ store: MeetingStore) throws -> MeetingRecord {
    let record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    try store.create(record)
    return record
  }

  private let at = Date(timeIntervalSinceReferenceDate: 815_000_000.5)

  private func attendee(_ name: String) -> MeetingFact {
    AttendeeFact(
      name: name, email: nil, role: .required, status: .accepted, isSelf: false,
      isOrganizer: false
    ).fact(source: MeetingFact.eventKitSource, capturedAt: at)
  }

  private func jsonObject(_ url: URL) throws -> [String: Any] {
    try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  }

  @Test("a meeting with no context reads as absent and nothing is written")
  func absentWritesNothing() throws {
    let store = makeStore()
    let record = try makeMeeting(store)
    #expect(store.loadContext(meeting: record.id) == .absent)
    #expect(FileManager.default.fileExists(atPath: store.contextURL(for: record.id).path) == false)
  }

  @Test("the first append creates the file; a later one keeps earlier facts in order")
  func appendKeepsOrder() throws {
    let store = makeStore()
    let record = try makeMeeting(store)
    try store.appendFacts([attendee("Ana")], meeting: record.id)
    try store.appendFacts([attendee("Bo"), attendee("Cy")], meeting: record.id)
    guard case .loaded(let context) = store.loadContext(meeting: record.id) else {
      Issue.record("context did not load")
      return
    }
    #expect(context.formatVersion == 1)
    #expect(context.attendees.map(\.name) == ["Ana", "Bo", "Cy"])
  }

  @Test("capturedAt and event times are stored as exact seconds since the reference date")
  func dateRepresentation() throws {
    let store = makeStore()
    let record = try makeMeeting(store)
    let event = CalendarEventFact(
      title: "Acme renewal", start: Date(timeIntervalSinceReferenceDate: 815_001_000),
      end: Date(timeIntervalSinceReferenceDate: 815_003_700))
    try store.appendFacts(
      [event.fact(source: MeetingFact.eventKitSource, capturedAt: at)], meeting: record.id)
    let raw = try jsonObject(store.contextURL(for: record.id))
    let fact = try #require((raw["facts"] as? [[String: Any]])?.first)
    #expect(fact["capturedAt"] as? Double == 815_000_000.5)
    let value = try #require(fact["value"] as? [String: Any])
    #expect(value["start"] as? Double == 815_001_000)
    #expect(value["end"] as? Double == 815_003_700)
    guard case .loaded(let context) = store.loadContext(meeting: record.id) else {
      Issue.record("context did not load")
      return
    }
    #expect(context.calendarEvents == [event])
    #expect(context.facts.first?.capturedAt == at)
  }

  @Test("an unknown fact and unknown keys survive an append on disk; another version still appends")
  func unknownContentSurvivesOnDisk() throws {
    let store = makeStore()
    let record = try makeMeeting(store)
    let existing = """
      {"formatVersion": 3, "facts": [
       {"kind": "futureThing", "source": "calendar.google", "capturedAt": 1, "value": {"deep": [true, null, {"x": "y"}]}},
       {"kind": "calendarEvent", "source": "calendar.eventkit", "capturedAt": 2,
        "value": {"title": "T", "start": 10, "end": 20, "location": "Room 4"}}]}
      """
    try Data(existing.utf8).write(to: store.contextURL(for: record.id))
    try store.appendFacts([attendee("Ana")], meeting: record.id)

    let raw = try jsonObject(store.contextURL(for: record.id))
    #expect(raw["formatVersion"] as? Int == 3)
    let facts = try #require(raw["facts"] as? [[String: Any]])
    #expect(facts.count == 3)
    #expect(facts[0]["kind"] as? String == "futureThing")
    #expect(facts[0]["source"] as? String == "calendar.google")
    let deep = try #require((facts[0]["value"] as? [String: Any])?["deep"] as? [Any])
    #expect(deep.count == 3)
    #expect((deep[0] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } == true)
    #expect(deep[1] is NSNull)
    #expect((deep[2] as? [String: String]) == ["x": "y"])
    #expect((facts[1]["value"] as? [String: Any])?["location"] as? String == "Room 4")
    #expect(facts[2]["kind"] as? String == "attendee")
  }

  @Test("damaged JSON or a folder at the path reads as unreadable; append refuses and keeps it")
  func unreadableIsKept() throws {
    let store = makeStore()
    let damaged = try makeMeeting(store)
    let damagedBytes = Data("{not json".utf8)
    try damagedBytes.write(to: store.contextURL(for: damaged.id))
    #expect(store.loadContext(meeting: damaged.id) == .unreadable)
    #expect(throws: MeetingStore.ContextError.existingUnreadable) {
      try store.appendFacts([attendee("Ana")], meeting: damaged.id)
    }
    #expect(try Data(contentsOf: store.contextURL(for: damaged.id)) == damagedBytes)

    let occupied = try makeMeeting(store)
    try FileManager.default.createDirectory(
      at: store.contextURL(for: occupied.id), withIntermediateDirectories: false)
    #expect(store.loadContext(meeting: occupied.id) == .unreadable)
    #expect(throws: MeetingStore.ContextError.existingUnreadable) {
      try store.appendFacts([attendee("Ana")], meeting: occupied.id)
    }
    var isDirectory: ObjCBool = false
    #expect(
      FileManager.default.fileExists(
        atPath: store.contextURL(for: occupied.id).path, isDirectory: &isDirectory))
    #expect(isDirectory.boolValue)
  }

  @Test("a missing folder, a missing or unreadable meeting.json, or a deletion refuses append")
  func refusals() throws {
    let store = makeStore()

    let gone = UUID()
    #expect(throws: MeetingStore.ContextError.meetingMissing) {
      try store.appendFacts([attendee("Ana")], meeting: gone)
    }
    #expect(FileManager.default.fileExists(atPath: store.folder(for: gone).path) == false)

    let noRecord = try makeMeeting(store)
    try FileManager.default.removeItem(at: store.recordURL(for: noRecord.id))
    #expect(throws: MeetingStore.ContextError.meetingMissing) {
      try store.appendFacts([attendee("Ana")], meeting: noRecord.id)
    }
    #expect(FileManager.default.fileExists(atPath: store.recordURL(for: noRecord.id).path) == false)
    #expect(FileManager.default.fileExists(atPath: store.contextURL(for: noRecord.id).path) == false)

    let unreadable = try makeMeeting(store)
    try Data("not json".utf8).write(to: store.recordURL(for: unreadable.id))
    #expect(throws: MeetingStore.ContextError.meetingMissing) {
      try store.appendFacts([attendee("Ana")], meeting: unreadable.id)
    }
    #expect(FileManager.default.fileExists(atPath: store.contextURL(for: unreadable.id).path) == false)

    var deleting = try makeMeeting(store)
    deleting.deletionRequested = true
    try store.save(deleting)
    #expect(throws: MeetingStore.ContextError.meetingDeleting) {
      try store.appendFacts([attendee("Ana")], meeting: deleting.id)
    }
    #expect(FileManager.default.fileExists(atPath: store.contextURL(for: deleting.id).path) == false)
  }

  @Test("a meeting a newer build wrote refuses append, whatever the context's own version")
  func newerMeetingRefuses() throws {
    let store = makeStore()
    let id = UUID()
    try FileManager.default.createDirectory(
      at: store.folder(for: id), withIntermediateDirectories: true)
    let future = """
      {"formatVersion": \(MeetingRecord.currentFormatVersion + 1), "id": "\(id.uuidString)", "createdAt": "2027-01-01T10:00:00Z"}
      """
    try Data(future.utf8).write(to: store.recordURL(for: id))
    #expect(throws: MeetingStore.ContextError.newerFormat) {
      try store.appendFacts([attendee("Ana")], meeting: id)
    }
    #expect(FileManager.default.fileExists(atPath: store.contextURL(for: id).path) == false)
  }

  @Test("a meeting whose audio was deleted still accepts facts")
  func audioDeletedStillAppends() throws {
    let store = makeStore()
    let record = try makeMeeting(store)
    try store.deleteAudio(meeting: record.id)
    var reloaded = try store.load(id: record.id)
    reloaded.audioKept = false
    try store.save(reloaded)
    try store.appendFacts([attendee("Ana")], meeting: record.id)
    guard case .loaded(let context) = store.loadContext(meeting: record.id) else {
      Issue.record("context did not load")
      return
    }
    #expect(context.attendees.map(\.name) == ["Ana"])
  }

  @Test("context.json is private (0600)")
  func permissions() throws {
    let store = makeStore()
    let record = try makeMeeting(store)
    try store.appendFacts([attendee("Ana")], meeting: record.id)
    let mode =
      try FileManager.default.attributesOfItem(
        atPath: store.contextURL(for: record.id).path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
  }

  @Test("an append that cannot be written throws and leaves the previous file byte for byte")
  func failedAppendKeepsPrevious() throws {
    let store = makeStore()
    let record = try makeMeeting(store)
    try store.appendFacts([attendee("Ana")], meeting: record.id)
    let url = store.contextURL(for: record.id)
    let before = try Data(contentsOf: url)
    let dir = store.folder(for: record.id)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }
    #expect(throws: (any Error).self) {
      try store.appendFacts([attendee("Bo")], meeting: record.id)
    }
    #expect(try Data(contentsOf: url) == before)
  }
}
