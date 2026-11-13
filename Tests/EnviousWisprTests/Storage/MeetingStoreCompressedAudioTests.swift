import EnviousWisprAppKitTestSupport
import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprStorage

/// #3147 PR4B lane A: when these fail, Settings undercounts the disk a meeting uses while its
/// original and compacted audio both exist (or counts a half-made copy as the meeting's audio),
/// a resumed recording overwrites a compacted file's index, or Delete audio leaves compacted or
/// abandoned audio behind (or removes the notes, summary or record it promises to keep).
@Suite("Meeting store with compacted audio", .tags(.productOutcome))
struct MeetingStoreCompressedAudioTests {
  struct Rig {
    let store: MeetingStore
    let record: MeetingRecord
    var folder: URL { store.folder(for: record.id) }

    func url(_ name: String) -> URL { folder.appendingPathComponent(name) }

    @discardableResult
    func write(_ name: String, bytes: Int) throws -> URL {
      let url = url(name)
      try Data(repeating: 7, count: bytes).write(to: url)
      return url
    }

    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: url(name).path) }
  }

  static func makeRig(_ edit: (inout MeetingRecord) -> Void = { _ in }) throws -> Rig {
    let root = TestTemporaryDirectory.url
      .appendingPathComponent("MeetingStoreCompressed-\(UUID().uuidString)", isDirectory: true)
    let store = MeetingStore(root: root)
    var record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    record.state = .ready
    edit(&record)
    try store.create(record)
    return Rig(store: store, record: record)
  }

  static func caf(
    _ track: MeetingTrackKind, _ index: Int, cleaned: Bool = false, partial: Bool = false
  )
    -> String
  {
    MeetingSegmentNaming.fileName(
      track: track, variant: cleaned ? .cleaned : .raw, index: index,
      startMs: (index - 1) * 60_000, partial: partial)
  }

  static func m4a(
    _ track: MeetingTrackKind, _ index: Int, inventory: UUID, cleaned: Bool = false,
    partial: Bool = false
  ) -> String {
    MeetingSegmentNaming.compactedFileName(
      source: MeetingSegmentInfo(
        index: index, fileName: caf(track, index, cleaned: cleaned),
        startMs: (index - 1) * 60_000, frameCount: 960_000),
      track: track, variant: cleaned ? .cleaned : .raw, inventoryID: inventory, partial: partial)
  }

  /// A committed inventory naming one microphone segment; enough for the record to say which
  /// compacted files are its audio.
  static func inventory(id: UUID) -> MeetingCompressedInventory {
    let source = MeetingSegmentInfo(
      index: 1, fileName: caf(.microphone, 1), startMs: 0, frameCount: 960_000)
    let compressed = MeetingSegmentInfo(
      index: 1, fileName: m4a(.microphone, 1, inventory: id), startMs: 0, frameCount: 960_000)
    let identity = MeetingAudioFileIdentity(byteCount: 1, sha256: "x")
    return MeetingCompressedInventory(
      id: id, transcriptGeneration: nil,
      segments: [
        MeetingCompressedSegment(
          track: .microphone, variant: .raw, source: source, sourceIdentity: identity,
          compressed: compressed, compressedIdentity: identity)
      ], cleanedProofs: [:])
  }

  // MARK: - Physical enumeration

  @Test("every audio file on disk is listed: recorder and compacted, finals and partials")
  func segmentFilesListsEveryRepresentation() throws {
    let rig = try Self.makeRig()
    let attempt = UUID()
    try rig.write(Self.caf(.microphone, 1), bytes: 10)
    try rig.write(Self.m4a(.microphone, 1, inventory: attempt), bytes: 3)
    try rig.write(Self.m4a(.microphone, 2, inventory: attempt, partial: true), bytes: 2)
    try rig.write(Self.caf(.microphone, 2, partial: true), bytes: 4)
    try rig.write(Self.m4a(.microphone, 1, inventory: attempt, cleaned: true), bytes: 1)
    try rig.write("notes.md", bytes: 5)
    try rig.write("micclean-complete-00001-00001.json", bytes: 5)

    let files = try rig.store.segmentFiles(meeting: rig.record.id)
    // Track, then copy (by raw value: "cleaned" sorts before "raw"), index, recorder before
    // compacted, final before partial.
    #expect(
      files.map(\.url.lastPathComponent) == [
        Self.m4a(.microphone, 1, inventory: attempt, cleaned: true),
        Self.caf(.microphone, 1), Self.m4a(.microphone, 1, inventory: attempt),
        Self.caf(.microphone, 2, partial: true),
        Self.m4a(.microphone, 2, inventory: attempt, partial: true),
      ])
    #expect(files.map(\.encoding) == [.aacM4A, .pcmCAF, .aacM4A, .pcmCAF, .aacM4A])
    #expect(files.map(\.inventoryID) == [attempt, nil, attempt, nil, attempt])
    #expect(files.map(\.partial) == [false, false, false, true, true])
  }

  @Test("a compacted file occupies its index, so a resumed writer continues past it")
  func highestIndexSeesCompactedFiles() throws {
    let rig = try Self.makeRig()
    try rig.write(Self.caf(.microphone, 2), bytes: 1)
    try rig.write(Self.m4a(.microphone, 3, inventory: UUID(), partial: true), bytes: 1)
    #expect(try rig.store.highestIndex(meeting: rig.record.id, track: .microphone) == 3)
    #expect(try rig.store.highestIndex(meeting: rig.record.id, track: .callSound) == 0)
  }

  @Test("the meeting's audio size counts its original and its compacted copy while both exist")
  func audioBytesCountsBothRepresentations() throws {
    let rig = try Self.makeRig()
    try rig.write(Self.caf(.microphone, 1), bytes: 100)
    try rig.write(Self.m4a(.microphone, 1, inventory: UUID()), bytes: 20)
    try rig.write(Self.m4a(.microphone, 2, inventory: UUID(), partial: true), bytes: 3)
    #expect(try rig.store.audioBytes(meeting: rig.record.id) == 123)
  }

  // MARK: - Usage

  @Test(
    "usage: committed copies are the meeting's audio; candidates and abandoned output are temporary"
  )
  func usageClassifiesCompactedOutput() throws {
    let committedID = UUID()
    let rig = try Self.makeRig { $0.commitCompressedAudio(Self.inventory(id: committedID)) }
    try rig.write(Self.caf(.microphone, 1), bytes: 1_000)
    try rig.write(Self.caf(.callSound, 1, partial: true), bytes: 50)
    try rig.write(Self.m4a(.microphone, 1, inventory: committedID), bytes: 100)
    // A finished candidate of another attempt, and an attempt's partial: never the audio.
    try rig.write(Self.m4a(.microphone, 1, inventory: UUID()), bytes: 30)
    try rig.write(Self.m4a(.callSound, 1, inventory: committedID, partial: true), bytes: 7)

    let usage = try #require(try rig.store.audioUsage())
    #expect(usage.committedBytes == 1_100)
    #expect(usage.temporaryBytes == 87)
    #expect(usage.unreadableFolders == 0)
  }

  @Test("usage without a committed inventory counts every compacted file as temporary")
  func usageWithoutInventory() throws {
    let rig = try Self.makeRig()
    try rig.write(Self.caf(.microphone, 1), bytes: 1_000)
    try rig.write(Self.m4a(.microphone, 1, inventory: UUID()), bytes: 100)
    let usage = try #require(try rig.store.audioUsage())
    #expect(usage.committedBytes == 1_000)
    #expect(usage.temporaryBytes == 100)
  }

  @Test("a folder whose record cannot be read still counts its compacted bytes, as temporary")
  func usageWithUnreadableRecord() throws {
    let id = UUID()
    let rig = try Self.makeRig { $0.commitCompressedAudio(Self.inventory(id: id)) }
    try rig.write(Self.m4a(.microphone, 1, inventory: id), bytes: 100)
    try Data("not json".utf8).write(to: rig.store.recordURL(for: rig.record.id))
    let usage = try #require(try rig.store.audioUsage())
    #expect(usage.committedBytes == 0)
    #expect(usage.temporaryBytes == 100)
    #expect(usage.unreadableFolders == 0)
  }

  // MARK: - Deletion

  @Test("Delete audio removes every representation and keeps the record and documents")
  func deleteAudioRemovesEveryRepresentation() throws {
    let committedID = UUID()
    let rig = try Self.makeRig { $0.commitCompressedAudio(Self.inventory(id: committedID)) }
    let audio = [
      Self.caf(.microphone, 1), Self.caf(.microphone, 1, cleaned: true),
      Self.caf(.callSound, 2, partial: true),
      Self.m4a(.microphone, 1, inventory: committedID),
      Self.m4a(.microphone, 1, inventory: committedID, cleaned: true),
      Self.m4a(.microphone, 2, inventory: UUID()),
      Self.m4a(.callSound, 2, inventory: UUID(), partial: true),
      "micclean-complete-00001-00001.json",
    ]
    for name in audio { try rig.write(name, bytes: 4) }
    let kept = ["notes.md", "notes.json", "summary.md", "documents.json", "context.json"]
    for name in kept { try rig.write(name, bytes: 4) }

    try rig.store.deleteAudio(meeting: rig.record.id)

    for name in audio { #expect(rig.exists(name) == false, "\(name) was left behind") }
    for name in kept { #expect(rig.exists(name), "\(name) must stay") }
    #expect(try rig.store.load(id: rig.record.id) == rig.record)
    #expect(try rig.store.audioBytes(meeting: rig.record.id) == 0)
  }

  @Test("Delete audio refuses a meeting a newer build wrote and leaves its compacted audio")
  func deleteAudioRefusesNewerFormat() throws {
    let rig = try Self.makeRig()
    let name = Self.m4a(.microphone, 1, inventory: UUID())
    try rig.write(name, bytes: 4)
    var json =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: rig.store.recordURL(for: rig.record.id))) as! [String: Any]
    json["formatVersion"] = MeetingRecord.currentFormatVersion + 1
    try JSONSerialization.data(withJSONObject: json).write(
      to: rig.store.recordURL(for: rig.record.id))
    #expect(throws: MeetingStore.StoreError.newerFormat) {
      try rig.store.deleteAudio(meeting: rig.record.id)
    }
    #expect(rig.exists(name))
  }
}
