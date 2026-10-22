import Foundation
import Testing
import os

@testable import EnviousWisprCore
@testable import EnviousWisprStorage

/// #3972 R3, R15: when these fail, a meeting folder is overwritten, a newer build's meeting is
/// damaged, audio a crash left behind is lost, or an unreadable folder looks empty.
@Suite("MeetingStore", .tags(.productOutcome))
struct MeetingStoreTests {

  private func makeStore() throws -> (MeetingStore, URL) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("MeetingStoreTests-\(UUID().uuidString)", isDirectory: true)
    return (MeetingStore(root: root), root)
  }

  private func touch(_ url: URL) throws {
    try Data([0, 1, 2, 3]).write(to: url)
  }

  @Test("create then load returns the same record; a second create of the same id is refused")
  func createIsAtomicAndNeverOverwrites() throws {
    let (store, _) = try makeStore()
    // Millisecond-exact, the precision the file keeps.
    var record = MeetingRecord(
      createdAt: Date(timeIntervalSince1970: 1_800_000_000.123), engine: .parakeet,
      trackStatus: [.microphone: .captured])
    record.title = "Kickoff"
    try store.create(record)
    #expect(try store.load(id: record.id) == record)

    var other = record
    other.title = "Should not win"
    #expect(throws: MeetingStore.StoreError.alreadyExists) { try store.create(other) }
    #expect(try store.load(id: record.id).title == "Kickoff")
  }

  @Test("a meeting written by a newer build is listed read-only and never rewritten or deleted")
  func newerFormatIsReadOnly() throws {
    let (store, _) = try makeStore()
    let id = UUID()
    try FileManager.default.createDirectory(
      at: store.folder(for: id), withIntermediateDirectories: true)
    let future = """
      {"formatVersion": 3, "id": "\(id.uuidString)", "createdAt": "2027-01-01T10:00:00Z",
       "engine": "something-new", "newField": [1, 2, 3]}
      """
    let original = Data(future.utf8)
    try original.write(to: store.recordURL(for: id))

    let listings = try store.loadAll()
    #expect(listings.count == 1)
    guard case .newerFormat(let header) = listings.first else {
      Issue.record("expected a newer-format listing, got \(String(describing: listings.first))")
      return
    }
    #expect(header.id == id && header.formatVersion == 3)

    var attempt = MeetingRecord(id: id, engine: .parakeet, trackStatus: [:])
    attempt.title = "overwrite"
    #expect(throws: MeetingStore.StoreError.newerFormat) { try store.save(attempt) }
    #expect(throws: MeetingStore.StoreError.newerFormat) { try store.deleteFolder(meeting: id) }
    #expect(throws: MeetingStore.StoreError.newerFormat) { try store.deleteAudio(meeting: id) }
    #expect(try Data(contentsOf: store.recordURL(for: id)) == original)
  }

  @Test("an unreadable meeting.json is listed as unreadable, not dropped and not deleted")
  func unreadableIsListed() throws {
    let (store, _) = try makeStore()
    let id = UUID()
    try FileManager.default.createDirectory(
      at: store.folder(for: id), withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: store.recordURL(for: id))
    #expect(try store.loadAll() == [.unreadable(id)])
    #expect(FileManager.default.fileExists(atPath: store.recordURL(for: id).path))
  }

  @Test("segment files: finals, partials and duplicates are all listed in numeric order")
  func segmentInventory() throws {
    let (store, _) = try makeStore()
    let record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    try store.create(record)
    let dir = store.folder(for: record.id)
    let names = [
      MeetingSegmentNaming.fileName(track: .microphone, index: 2, startMs: 60_000, partial: false),
      MeetingSegmentNaming.fileName(track: .microphone, index: 10, startMs: 540_000, partial: true),
      MeetingSegmentNaming.fileName(track: .microphone, index: 2, startMs: 60_000, partial: true),
      MeetingSegmentNaming.fileName(track: .callSound, index: 1, startMs: 0, partial: false),
      "not-a-segment.caf", ".DS_Store",
    ]
    for name in names { try touch(dir.appendingPathComponent(name)) }

    let files = try store.segmentFiles(meeting: record.id)
    #expect(files.map(\.track) == [.callSound, .microphone, .microphone, .microphone])
    let mic = files.filter { $0.track == .microphone }
    #expect(mic.map(\.index) == [2, 2, 10])
    #expect(mic.map(\.partial) == [false, true, true])
    #expect(mic.first?.startMs == 60_000)
    #expect(try store.highestIndex(meeting: record.id, track: .microphone) == 10)
    #expect(try store.highestIndex(meeting: record.id, track: .callSound) == 1)
  }

  @Test(
    "delete audio removes every segment file and keeps meeting.json; delete folder removes it all")
  func deletion() throws {
    let (store, root) = try makeStore()
    let record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    let neighbour = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    try store.create(record)
    try store.create(neighbour)
    let dir = store.folder(for: record.id)
    try touch(
      dir.appendingPathComponent(
        MeetingSegmentNaming.fileName(track: .microphone, index: 1, startMs: 0, partial: false)))
    try touch(
      dir.appendingPathComponent(
        MeetingSegmentNaming.fileName(track: .callSound, index: 1, startMs: 0, partial: true)))

    try store.deleteAudio(meeting: record.id)
    #expect(try store.segmentFiles(meeting: record.id).isEmpty)
    #expect(FileManager.default.fileExists(atPath: store.recordURL(for: record.id).path))

    try store.deleteFolder(meeting: record.id)
    #expect(!FileManager.default.fileExists(atPath: dir.path))
    #expect(FileManager.default.fileExists(atPath: store.folder(for: neighbour.id).path))
    #expect(FileManager.default.fileExists(atPath: root.path))
  }

  @Test("deletion intent survives a reload")
  func deletionIntentPersists() throws {
    let (store, _) = try makeStore()
    var record = MeetingRecord(engine: .parakeet, trackStatus: [:])
    try store.create(record)
    record.deletionRequested = true
    try store.save(record)
    #expect(try store.load(id: record.id).deletionRequested)
  }

  @Test("an unreadable meeting folder throws instead of listing no segments")
  func unreadableFolderThrows() throws {
    let (store, _) = try makeStore()
    #expect(throws: (any Error).self) { try store.segmentFiles(meeting: UUID()) }
  }

  @Test("the root and each meeting folder are private, the root is excluded from Spotlight, records are 0600")
  func privacyPosture() throws {
    let (store, root) = try makeStore()
    let record = MeetingRecord(engine: .parakeet, trackStatus: [:])
    try store.create(record)
    func mode(_ url: URL) throws -> Int {
      (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1
    }
    #expect(try mode(root) == 0o700)
    #expect(try mode(store.folder(for: record.id)) == 0o700)
    #expect(try mode(store.recordURL(for: record.id)) == 0o600)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".metadata_never_index").path))
  }

  @Test("eight simultaneous creates of one meeting: exactly one wins")
  func concurrentCreateHasOneWinner() throws {
    let (store, _) = try makeStore()
    try store.prepareRoot()
    let record = MeetingRecord(engine: .parakeet, trackStatus: [:])
    let wins = OSAllocatedUnfairLock(initialState: 0)
    DispatchQueue.concurrentPerform(iterations: 8) { _ in
      if (try? store.create(record)) != nil { wins.withLock { $0 += 1 } }
    }
    #expect(wins.withLock { $0 } == 1)
  }

  @Test("a save that cannot be written leaves the previous meeting.json byte for byte")
  func failedSaveKeepsPreviousRecord() throws {
    let (store, _) = try makeStore()
    var record = MeetingRecord(engine: .parakeet, trackStatus: [:])
    record.title = "Before"
    try store.create(record)
    let before = try Data(contentsOf: store.recordURL(for: record.id))
    let dir = store.folder(for: record.id)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
    record.title = "After"
    #expect(throws: (any Error).self) { try store.save(record) }
    #expect(try Data(contentsOf: store.recordURL(for: record.id)) == before)
  }

  @Test("saving an existing meeting repairs loosened root permissions and a removed Spotlight marker")
  func saveRepairsPrivacy() throws {
    let (store, root) = try makeStore()
    var record = MeetingRecord(engine: .parakeet, trackStatus: [:])
    try store.create(record)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
    try FileManager.default.removeItem(at: root.appendingPathComponent(".metadata_never_index"))
    // A fresh store over the same root, as after a relaunch or a backup restore.
    let reopened = MeetingStore(root: root)
    record.title = "Saved again"
    try reopened.save(record)
    let mode = try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int
    #expect(mode == 0o700)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".metadata_never_index").path))
  }

  @Test("a replace that fails after the new file is written leaves the previous meeting.json")
  func failedReplaceKeepsPreviousRecord() throws {
    let (store, _) = try makeStore()
    var record = MeetingRecord(engine: .parakeet, trackStatus: [:])
    record.title = "Before"
    try store.create(record)
    let url = store.recordURL(for: record.id)
    let before = try Data(contentsOf: url)
    // An immutable destination: the temp file writes fine, the replace itself fails.
    try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: url.path)
    defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: url.path) }
    record.title = "After"
    #expect(throws: (any Error).self) { try store.save(record) }
    #expect(try Data(contentsOf: url) == before)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: store.folder(for: record.id).path)
      .filter { $0.hasSuffix(".tmp") }
    #expect(leftovers.isEmpty)
  }
}
