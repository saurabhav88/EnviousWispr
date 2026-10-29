import EnviousWisprAppKitTestSupport
import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprStorage

/// #4013 r2 item 3: when these fail, a meeting's call names are lost or misread after a
/// relaunch, a damaged file stops a transcript, a late save brings back evidence the user
/// deleted, or an older build overwrites evidence it cannot read.
@Suite("Meeting call-speaker evidence file", .tags(.productOutcome))
struct MeetingCallSpeakersStoreTests {

  private func makeMeeting() throws -> (MeetingStore, MeetingRecord) {
    let root = TestTemporaryDirectory.url
      .appendingPathComponent(
        "MeetingCallSpeakersStoreTests-\(UUID().uuidString)", isDirectory: true)
    let store = MeetingStore(root: root)
    let record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    try store.create(record)
    return (store, record)
  }

  private static let frozen = FrozenTalkerRules(
    version: 1, payload: #"{"schema":1,"revision":2,"lagMs":{"meet":80},"selectors":[]}"#)

  private static func log(
    observations: [CallSpeakerObservation] = [
      CallSpeakerObservation(observationMs: 1_200, speaking: ["Alex Rivera"]),
      CallSpeakerObservation(observationMs: 1_700, speaking: ["Alex Rivera", "Priya Shah"]),
    ], rosterFromParticipantList: Bool? = false
  ) -> CallSpeakerLog {
    CallSpeakerLog(
      surface: .meet, source: .rules, status: .observed, lag: CallSpeakerLag(milliseconds: 80),
      rules: frozen,
      roster: CallSpeakerRoster(
        names: ["Alex Rivera", "Priya Shah", "Alex Rivera"], selfNames: ["Saurabh Vaish"]),
      rosterFromParticipantList: rosterFromParticipantList, observations: observations)
  }

  private func permissions(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require(attributes[.posixPermissions] as? Int)
  }

  private func writeRaw(_ text: String, meeting id: UUID, in store: MeetingStore) throws {
    try Data(text.utf8).write(to: store.callSpeakersURL(for: id))
  }

  @Test("every field reads back as saved, duplicates and uncertainty included, at 0600")
  func roundTrip() throws {
    let (store, record) = try makeMeeting()
    #expect(store.loadCallSpeakers(meeting: record.id) == .absent)

    try store.saveCallSpeakers(Self.log(), meeting: record.id)
    #expect(store.loadCallSpeakers(meeting: record.id) == .usable(Self.log()))
    #expect(try permissions(store.callSpeakersURL(for: record.id)) == 0o600)

    // Replacement: metadata and roster survive with no talking samples; a list-backed roster.
    let quiet = Self.log(observations: [], rosterFromParticipantList: true)
    try store.saveCallSpeakers(quiet, meeting: record.id)
    guard case .usable(let loaded) = store.loadCallSpeakers(meeting: record.id) else {
      Issue.record("the replaced log did not load")
      return
    }
    #expect(loaded == quiet)
    #expect(loaded.rules == Self.frozen, "the frozen text is kept byte for byte")
    #expect(loaded.roster.names == ["Alex Rivera", "Priya Shah", "Alex Rivera"])
    #expect(loaded.observations.isEmpty)
    #expect(try permissions(store.callSpeakersURL(for: record.id)) == 0o600)
    let leftovers = try FileManager.default.contentsOfDirectory(
      atPath: store.folder(for: record.id).path
    ).filter { $0.hasPrefix(".call-speakers") }
    #expect(leftovers.isEmpty)
  }

  @Test("a log saved before roster uncertainty was recorded reads it as unknown, not as unique")
  func legacyUncertaintyIsUnknown() throws {
    let (store, record) = try makeMeeting()
    try writeRaw(
      #"{"formatVersion":1,"surface":"zoom_app","roster":{"names":["Alex Rivera"],"selfNames":[]}}"#,
      meeting: record.id, in: store)
    guard case .usable(let log) = store.loadCallSpeakers(meeting: record.id) else {
      Issue.record("the legacy log did not load")
      return
    }
    #expect(log.rosterFromParticipantList == nil)
    #expect(log.status == nil, "no outcome is invented")
    #expect(log.lag == nil)
  }

  @Test(
    "a damaged, newer, oversized or badly timed file is unusable and never throws",
    arguments: [
      ("{\"formatVersion\":1,\"roster\"", MeetingStore.CallSpeakersLoad.Reason.invalid),
      ("not json", .invalid),
      (#"{"formatVersion":3}"#, .newerFormat),
      (#"{"formatVersion":2,"segments":[{"startMs":0},{"startMs":10}]}"#, .invalid),
      (#"{"formatVersion":2}"#, .invalid),
      (#"{"formatVersion":2,"segments":null}"#, .invalid),
      (#"{"formatVersion":1,"lag":{"milliseconds":-9223372036854775808}}"#, .invalid),
      (#"{"formatVersion":1,"observations":[{"observationMs":-1,"speaking":[]}]}"#, .invalid),
      (
        #"{"formatVersion":1,"observations":[{"observationMs":900,"speaking":[]},{"observationMs":800,"speaking":[]}]}"#,
        .invalid
      ),
      (#"{"formatVersion":1,"observations":[{"observationMs":5,"speaking":[""]}]}"#, .invalid),
      (#"{"formatVersion":1,"rules":{"version":0,"payload":"{}"}}"#, .invalid),
    ])
  func unusableFiles(text: String, reason: MeetingStore.CallSpeakersLoad.Reason) throws {
    let (store, record) = try makeMeeting()
    try writeRaw(text, meeting: record.id, in: store)
    #expect(store.loadCallSpeakers(meeting: record.id) == .unusable(reason))
  }

  @Test("a file past the size bound is refused without being decoded")
  func oversized() throws {
    let (store, record) = try makeMeeting()
    try Data(repeating: 0x20, count: MeetingStore.maximumCallSpeakersBytes + 1)
      .write(to: store.callSpeakersURL(for: record.id))
    #expect(store.loadCallSpeakers(meeting: record.id) == .unusable(.tooLarge))
  }

  @Test("a save never lands on a deleting, audio-deleted, missing or newer meeting")
  func refusedWrites() throws {
    let (store, record) = try makeMeeting()
    var deleting = record
    deleting.deletionRequested = true
    try store.save(deleting)
    #expect(throws: MeetingStore.CallSpeakersError.meetingDeleting) {
      try store.saveCallSpeakers(Self.log(), meeting: record.id)
    }

    let (store2, record2) = try makeMeeting()
    var noAudio = record2
    noAudio.audioKept = false
    try store2.save(noAudio)
    #expect(throws: MeetingStore.CallSpeakersError.audioDeleted) {
      try store2.saveCallSpeakers(Self.log(), meeting: record2.id)
    }

    let (store3, record3) = try makeMeeting()
    try store3.deleteFolder(meeting: record3.id)
    #expect(throws: MeetingStore.CallSpeakersError.meetingMissing) {
      try store3.saveCallSpeakers(Self.log(), meeting: record3.id)
    }
    #expect(!FileManager.default.fileExists(atPath: store3.folder(for: record3.id).path))

    let (store4, record4) = try makeMeeting()
    var object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(record4)) as? [String: Any])
    object["formatVersion"] = MeetingRecord.currentFormatVersion + 1
    try JSONSerialization.data(withJSONObject: object).write(to: store4.recordURL(for: record4.id))
    #expect(throws: MeetingStore.CallSpeakersError.newerFormat) {
      try store4.saveCallSpeakers(Self.log(), meeting: record4.id)
    }
    #expect(store4.loadCallSpeakers(meeting: record4.id) == .absent)
    for (subject, id) in [(store, record.id), (store2, record2.id)] {
      #expect(subject.loadCallSpeakers(meeting: id) == .absent)
    }
  }

  @Test("a file a newer build wrote is never overwritten, and a malformed log is never written")
  func protectedContent() throws {
    let (store, record) = try makeMeeting()
    let newer = #"{"formatVersion":3,"future":true}"#
    try writeRaw(newer, meeting: record.id, in: store)
    #expect(throws: MeetingStore.CallSpeakersError.newerFormat) {
      try store.saveCallSpeakers(Self.log(), meeting: record.id)
    }
    #expect(try String(contentsOf: store.callSpeakersURL(for: record.id), encoding: .utf8) == newer)

    let (store2, record2) = try makeMeeting()
    let backwards = Self.log(observations: [
      CallSpeakerObservation(observationMs: 900, speaking: []),
      CallSpeakerObservation(observationMs: 800, speaking: []),
    ])
    #expect(
      throws: MeetingStore.CallSpeakersError.invalidLog(
        "segments[0].observations[1] out of order or before the segment")
    ) {
      try store2.saveCallSpeakers(backwards, meeting: record2.id)
    }
    #expect(store2.loadCallSpeakers(meeting: record2.id) == .absent)
  }

  @Test("a log too large to read back is not saved, and the previous log stays")
  func oversizedLogRefused() throws {
    let (store, record) = try makeMeeting()
    try store.saveCallSpeakers(Self.log(), meeting: record.id)
    let before = try Data(contentsOf: store.callSpeakersURL(for: record.id))
    let names = (0..<60).map { "Participant \($0) " + String(repeating: "x", count: 230) }
    let huge = Self.log(
      observations: (0..<1_200).map { CallSpeakerObservation(observationMs: $0, speaking: names) })
    #expect(huge.shapeProblem == nil, "the log is well formed, only large")
    #expect(throws: MeetingStore.CallSpeakersError.tooLarge) {
      try store.saveCallSpeakers(huge, meeting: record.id)
    }
    #expect(try Data(contentsOf: store.callSpeakersURL(for: record.id)) == before)
  }

  @Test(
    "a file whose version cannot be shown to be this build's is kept, whatever its size",
    arguments: ["oversized newer", "not json", "version zero", "truncated"])
  func unrecognisedFileKept(kind: String) throws {
    let (store, record) = try makeMeeting()
    let url = store.callSpeakersURL(for: record.id)
    let bytes: Data
    switch kind {
    case "oversized newer":
      bytes = Data(
        (#"{"formatVersion":2,"pad":""#
          + String(repeating: "x", count: MeetingStore.maximumCallSpeakersBytes) + #""}"#).utf8)
    case "not json": bytes = Data("garbage".utf8)
    case "version zero": bytes = Data(#"{"formatVersion":0}"#.utf8)
    default: bytes = Data(#"{"formatVersion":1,"roster":"#.utf8)
    }
    try bytes.write(to: url)
    #expect(throws: MeetingStore.CallSpeakersError.existingUnverifiable) {
      try store.saveCallSpeakers(Self.log(), meeting: record.id)
    }
    #expect(try Data(contentsOf: url) == bytes)
  }

  @Test("a format-2 file with an explicit empty segment list is a recording that read no call")
  func emptySegments() throws {
    let (store, record) = try makeMeeting()
    try writeRaw(#"{"formatVersion":2,"segments":[]}"#, meeting: record.id, in: store)
    #expect(
      store.loadCallSpeakers(meeting: record.id) == .usable(CallSpeakerLog(rules: nil, segments: [])))
  }

  @Test("a format-1 file is replaced by a format-2 save")
  func formatOneReplaced() throws {
    let (store, record) = try makeMeeting()
    try writeRaw(#"{"formatVersion":1,"surface":"meet"}"#, meeting: record.id, in: store)
    try store.saveCallSpeakers(Self.log(), meeting: record.id)
    guard case .usable(let log) = store.loadCallSpeakers(meeting: record.id) else {
      Issue.record("the replaced log did not load")
      return
    }
    #expect(log.formatVersion == 2)
    #expect(log == Self.log())
  }

  @Test("a damaged log that says it is this build's version is replaced")
  func damagedCurrentVersionReplaced() throws {
    let (store, record) = try makeMeeting()
    try writeRaw(
      #"{"formatVersion":1,"observations":[{"observationMs":-5,"speaking":[]}]}"#,
      meeting: record.id, in: store)
    #expect(store.loadCallSpeakers(meeting: record.id) == .unusable(.invalid))
    try store.saveCallSpeakers(Self.log(), meeting: record.id)
    #expect(store.loadCallSpeakers(meeting: record.id) == .usable(Self.log()))
  }

  @Test("a failed replacement keeps the previous saved log")
  func failedWriteKeepsPrevious() throws {
    let (store, record) = try makeMeeting()
    try store.saveCallSpeakers(Self.log(), meeting: record.id)
    let folder = store.folder(for: record.id)
    // A read-only folder refuses the temp file, so nothing is replaced.
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    }
    #expect(throws: (any Error).self) {
      try store.saveCallSpeakers(Self.log(observations: []), meeting: record.id)
    }
    #expect(store.loadCallSpeakers(meeting: record.id) == .usable(Self.log()))
  }

  @Test("Delete audio removes the evidence and its leftovers and keeps the meeting's other files")
  func deleteAudio() throws {
    let (store, record) = try makeMeeting()
    _ = try store.saveNotes("Agenda", revision: 1, meeting: record.id)
    try store.saveCallSpeakers(Self.log(), meeting: record.id)
    let folder = store.folder(for: record.id)
    let leftovers = [
      ".call-speakers.json.\(UUID().uuidString).tmp",
      ".call-speakers.json.\(UUID().uuidString).bak",
    ]
    let unrelated = [
      ".notes.md.\(UUID().uuidString).bak", ".call-speakers.json.keep.bak",
      ".call-speakers.json.\(UUID().uuidString).tmp.old", ".call-speakers.json..bak",
      "call-speakers.json.\(UUID().uuidString).bak",
    ]
    for name in leftovers + unrelated {
      try Data("x".utf8).write(to: folder.appendingPathComponent(name))
    }

    try store.deleteAudio(meeting: record.id)
    #expect(store.loadCallSpeakers(meeting: record.id) == .absent)
    let names = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
    #expect(names.isDisjoint(with: leftovers))
    #expect(Set(unrelated).isSubset(of: names), "near-miss names are not the writer's leftovers")
    #expect(names.contains(MeetingStore.recordFileName))
    #expect(try store.loadDocuments(meeting: record.id).notes == "Agenda")
    // Repeatable: nothing left is not an error.
    try store.deleteAudio(meeting: record.id)

    try store.deleteFolder(meeting: record.id)
    #expect(!FileManager.default.fileExists(atPath: folder.path))
  }
}
