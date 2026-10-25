import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprStorage
import EnviousWisprAppKitTestSupport

/// #3996: when these fail, a meeting save that throws can leave the NEW file on disk while
/// the app rolls back to the old one, so what the user sees and what is saved disagree, or a
/// failed write leaves no trace of what the disk now holds.
/// Real files on the real file system (real `replaceItemAt`); only the directory sync, the
/// restore calls and the replacement call are stood in for, one at a time, each failing with
/// its own error number so the report shows the right one.
@Suite("MeetingStore atomic write", .tags(.productOutcome))
struct MeetingStoreAtomicWriteTests {

  private func folder() throws -> URL {
    let url = TestTemporaryDirectory.url
      .appendingPathComponent(
        "MeetingStoreAtomicWriteTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func names(_ dir: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
  }

  private func text(_ url: URL) throws -> String {
    String(decoding: try Data(contentsOf: url), as: UTF8.self)
  }

  /// Collects report lines and counts directory syncs.
  final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [String] = []
    private var syncCount = 0
    var lines: [String] { lock.withLock { collected } }
    var syncs: Int { lock.withLock { syncCount } }
    func add(_ line: String) { lock.withLock { collected.append(line) } }
    func nextSync() -> Int {
      lock.withLock {
        defer { syncCount += 1 }
        return syncCount
      }
    }
  }

  /// Fails with `code` the way a system call does: errno set, -1 returned.
  private static func fail(_ code: Int32) -> Int32 {
    errno = code
    return -1
  }

  /// The system steps, reporting into `probe`, with the directory sync failing with the
  /// given error numbers in order (nil = the real sync).
  private func steps(
    _ probe: Probe, syncs: [Int32?] = [], onSync: @escaping @Sendable (Int) -> Void = { _ in }
  ) -> MeetingStore.WriteSteps {
    var steps = MeetingStore.WriteSteps.system
    steps.report = { probe.add($0) }
    steps.syncDirectory = { fd in
      let n = probe.nextSync()
      onSync(n)
      if n < syncs.count, let code = syncs[n] { return Self.fail(code) }
      return fsync(fd)
    }
    return steps
  }

  private static func line(_ file: String, _ rest: String) -> String {
    "meeting file write failed file=\(file) \(rest)"
  }

  @Test("a write replaces the file and leaves no temp or backup beside it")
  func writeReplacesCleanly() throws {
    let dir = try folder()
    let url = dir.appendingPathComponent("meeting.json")
    let probe = Probe()
    try MeetingStore.atomicWrite(Data("old".utf8), to: url)
    try MeetingStore.atomicWrite(Data("new".utf8), to: url, steps: steps(probe))
    #expect(try text(url) == "new")
    #expect(try names(dir) == ["meeting.json"])
    #expect(probe.lines.isEmpty)
    #expect(probe.syncs == 1)
  }

  final class Box: @unchecked Sendable { var value: Data? }

  @Test("a failed directory sync after replacing puts the previous file back, syncs, then throws")
  func failedSyncRestoresPrevious() throws {
    let dir = try folder()
    let url = dir.appendingPathComponent("meeting.json")
    try MeetingStore.atomicWrite(Data("old".utf8), to: url)
    let probe = Probe()
    let seenBackup = Box()
    let failing = steps(probe, syncs: [EIO]) { call in
      guard call == 0 else { return }
      // The backup Foundation kept is the previous content, read before anything is undone.
      let backup = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
        .first { $0.hasSuffix(".bak") }
      seenBackup.value = backup.flatMap { try? Data(contentsOf: dir.appendingPathComponent($0)) }
    }
    #expect(throws: MeetingStore.StoreError.syncFailed(EIO)) {
      try MeetingStore.atomicWrite(Data("new".utf8), to: url, steps: failing)
    }
    #expect(seenBackup.value == Data("old".utf8))
    #expect(try text(url) == "old", "the throw means the previous file stands")
    #expect(try names(dir) == ["meeting.json"])
    #expect(probe.syncs == 2, "the restore is synced too")
    #expect(
      probe.lines == [
        Self.line("meeting.json", "stage=sync holds=previous durable=yes sync=\(EIO)")
      ])
  }

  @Test("a failed directory sync for a new file removes it, syncs, then throws")
  func failedSyncRemovesNewFile() throws {
    let dir = try folder()
    let url = dir.appendingPathComponent("notes.md")
    let probe = Probe()
    #expect(throws: MeetingStore.StoreError.syncFailed(EIO)) {
      try MeetingStore.atomicWrite(Data("new".utf8), to: url, steps: steps(probe, syncs: [EIO]))
    }
    #expect(try names(dir).isEmpty)
    #expect(probe.syncs == 2)
    #expect(
      probe.lines == [Self.line("notes.md", "stage=sync holds=absent durable=yes sync=\(EIO)")])
  }

  @Test("a directory that cannot be opened fails before anything is replaced")
  func directoryOpenFailsFirst() throws {
    let dir = try folder()
    let url = dir.appendingPathComponent("meeting.json")
    try MeetingStore.atomicWrite(Data("old".utf8), to: url)
    let probe = Probe()
    var steps = steps(probe)
    steps.openDirectory = { _ in Self.fail(EMFILE) }
    steps.replace = { _, _, _ in Issue.record("replaced after the directory failed to open") }
    #expect(throws: MeetingStore.StoreError.syncFailed(EMFILE)) {
      try MeetingStore.atomicWrite(Data("new".utf8), to: url, steps: steps)
    }
    #expect(try text(url) == "old")
    #expect(try names(dir) == ["meeting.json"])
    #expect(
      probe.lines == [
        Self.line("meeting.json", "stage=open_directory holds=unchanged durable=unchanged open=\(EMFILE)")
      ])
  }

  @Test("when putting the previous file back fails, the report says the new file may stand")
  func failedRestoreIsReported() throws {
    let dir = try folder()
    let url = dir.appendingPathComponent("meeting.json")
    try MeetingStore.atomicWrite(Data("old".utf8), to: url)
    let probe = Probe()
    var steps = steps(probe, syncs: [EIO])
    steps.rename = { _, _ in Self.fail(EACCES) }
    #expect(throws: MeetingStore.StoreError.syncFailed(EIO)) {
      try MeetingStore.atomicWrite(Data("new".utf8), to: url, steps: steps)
    }
    // The residual case: the new content is in place and the previous one is kept beside it.
    #expect(try text(url) == "new")
    let backup = try names(dir).first { $0.hasSuffix(".bak") }
    #expect(backup.map { try? text(dir.appendingPathComponent($0)) } == "old")
    #expect(
      probe.lines == [
        Self.line("meeting.json", "stage=undo holds=new durable=unknown sync=\(EIO) undo=\(EACCES)")
      ])
  }

  @Test("a restore whose own directory sync fails says the previous file is back but unconfirmed")
  func unconfirmedRestoreIsReported() throws {
    let dir = try folder()
    let url = dir.appendingPathComponent("meeting.json")
    try MeetingStore.atomicWrite(Data("old".utf8), to: url)
    let probe = Probe()
    #expect(throws: MeetingStore.StoreError.syncFailed(EIO)) {
      try MeetingStore.atomicWrite(
        Data("new".utf8), to: url, steps: steps(probe, syncs: [EIO, ENOSPC]))
    }
    #expect(try text(url) == "old")
    #expect(try names(dir) == ["meeting.json"])
    #expect(
      probe.lines == [
        Self.line(
          "meeting.json",
          "stage=undo_sync holds=previous durable=unknown sync=\(EIO) undo_sync=\(ENOSPC)")
      ])
  }

  /// The error a displacing replacement throws: the caller must get exactly this one back.
  private static func isOriginal(_ error: any Error, location: URL?) -> Bool {
    let ns = error as NSError
    return ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteUnknownError
      && (ns.userInfo[MeetingStore.originalItemLocationKey] as? URL) == location
  }

  private static let replaceError = "error=\(NSCocoaErrorDomain):\(NSFileWriteUnknownError)"

  /// A replacement call that moves the original aside and fails, as Foundation documents.
  private func displacingReplace(aside: URL) -> @Sendable (URL, URL, String) throws -> Void {
    { url, _, _ in
      try FileManager.default.moveItem(at: url, to: aside)
      throw NSError(
        domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
        userInfo: [MeetingStore.originalItemLocationKey: aside])
    }
  }

  @Test("a replacement call that moved the original away and failed puts it back and syncs")
  func failedReplacementRestoresOriginal() throws {
    let dir = try folder()
    let url = dir.appendingPathComponent("meeting.json")
    try MeetingStore.atomicWrite(Data("old".utf8), to: url)
    let probe = Probe()
    var steps = steps(probe)
    steps.replace = displacingReplace(aside: dir.appendingPathComponent(".aside"))
    let thrown = #expect(throws: (any Error).self) {
      try MeetingStore.atomicWrite(Data("new".utf8), to: url, steps: steps)
    }
    #expect(thrown.map { Self.isOriginal($0, location: dir.appendingPathComponent(".aside")) } == true, "Foundation's own error")
    #expect(try text(url) == "old")
    #expect(try names(dir) == ["meeting.json"], "the temp file goes once the original is back")
    #expect(probe.syncs == 1, "the restored original is synced")
    #expect(
      probe.lines == [
        Self.line(
          "meeting.json",
          "stage=replace_restore holds=previous durable=yes \(Self.replaceError)")
      ])
  }

  @Test("when the displaced original cannot be put back, the temp file and the original are kept")
  func failedReplacementRestoreKeepsEvidence() throws {
    let dir = try folder()
    let url = dir.appendingPathComponent("meeting.json")
    try MeetingStore.atomicWrite(Data("old".utf8), to: url)
    let aside = dir.appendingPathComponent(".aside")
    let probe = Probe()
    var steps = steps(probe)
    steps.replace = displacingReplace(aside: aside)
    steps.rename = { _, _ in Self.fail(EROFS) }
    let thrown = #expect(throws: (any Error).self) {
      try MeetingStore.atomicWrite(Data("new".utf8), to: url, steps: steps)
    }
    #expect(thrown.map { Self.isOriginal($0, location: aside) } == true, "Foundation's own error")
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(try text(aside) == "old", "the original stays where Foundation left it")
    #expect(try names(dir).contains { $0.hasSuffix(".tmp") }, "the new content is kept as evidence")
    #expect(
      probe.lines == [
        Self.line(
          "meeting.json",
          "stage=replace_restore holds=absent durable=unknown \(Self.replaceError) restore=\(EROFS)"
        )
      ])
  }

  @Test("a put-back original whose directory sync fails is reported as unconfirmed")
  func failedReplacementRestoreSyncIsReported() throws {
    let dir = try folder()
    let url = dir.appendingPathComponent("meeting.json")
    try MeetingStore.atomicWrite(Data("old".utf8), to: url)
    let probe = Probe()
    var steps = steps(probe, syncs: [ENOSPC])
    steps.replace = displacingReplace(aside: dir.appendingPathComponent(".aside"))
    let thrown = #expect(throws: (any Error).self) {
      try MeetingStore.atomicWrite(Data("new".utf8), to: url, steps: steps)
    }
    #expect(thrown.map { Self.isOriginal($0, location: dir.appendingPathComponent(".aside")) } == true, "Foundation's own error")
    #expect(try text(url) == "old")
    #expect(
      probe.lines == [
        Self.line(
          "meeting.json",
          "stage=replace_restore_sync holds=previous durable=unknown \(Self.replaceError) restore_sync=\(ENOSPC)"
        )
      ])
  }

  @Test("a displaced original goes back even when something was left at the destination")
  func displacedOriginalReplacesLeftover() throws {
    let dir = try folder()
    let url = dir.appendingPathComponent("meeting.json")
    try MeetingStore.atomicWrite(Data("old".utf8), to: url)
    let aside = dir.appendingPathComponent(".aside")
    let probe = Probe()
    var steps = steps(probe)
    steps.replace = { url, _, _ in
      try FileManager.default.moveItem(at: url, to: aside)
      try Data("partial".utf8).write(to: url)
      throw NSError(
        domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
        userInfo: [MeetingStore.originalItemLocationKey: aside])
    }
    let thrown = #expect(throws: (any Error).self) {
      try MeetingStore.atomicWrite(Data("new".utf8), to: url, steps: steps)
    }
    #expect(thrown.map { Self.isOriginal($0, location: aside) } == true)
    #expect(try text(url) == "old", "the original wins over what the failed call left")
    #expect(try names(dir) == ["meeting.json"])
    #expect(
      probe.lines == [
        Self.line("meeting.json", "stage=replace_restore holds=previous durable=yes \(Self.replaceError)")
      ])
  }

  @Test("a failed replacement that reports no original says what is left, and drops the temp copy")
  func unreportedOriginalIsUnverified() throws {
    let dir = try folder()
    let url = dir.appendingPathComponent("meeting.json")
    try MeetingStore.atomicWrite(Data("old".utf8), to: url)
    let probe = Probe()
    var steps = steps(probe)
    steps.replace = { _, _, _ in
      throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError)
    }
    let thrown = #expect(throws: (any Error).self) {
      try MeetingStore.atomicWrite(Data("new".utf8), to: url, steps: steps)
    }
    #expect(thrown.map { Self.isOriginal($0, location: nil) } == true)
    #expect(try text(url) == "old")
    #expect(try names(dir) == ["meeting.json"], "the temp copy of the new content goes")
    #expect(
      probe.lines == [
        Self.line(
          "meeting.json",
          "stage=replace holds=unverified durable=unknown \(Self.replaceError) original=unreported")
      ])
  }

  @Test("a confirmed write whose backup cannot be removed still succeeds with the new content")
  func backupCleanupFailureIsHarmless() throws {
    let dir = try folder()
    let url = dir.appendingPathComponent("meeting.json")
    try MeetingStore.atomicWrite(Data("old".utf8), to: url)
    let probe = Probe()
    var steps = steps(probe)
    steps.removeBackup = { _ in throw CocoaError(.fileWriteNoPermission) }
    try MeetingStore.atomicWrite(Data("new".utf8), to: url, steps: steps)
    #expect(try text(url) == "new")
    #expect(
      try names(dir).filter { $0.hasSuffix(".bak") }.count == 1, "left as an ignored dot-file")
    #expect(probe.lines.isEmpty)
  }

  @Test("a backup left by a crash is ignored by every meeting reader and goes with the folder")
  @MainActor
  func leftoverBackupsAreIgnored() throws {
    let root = try folder()
    let store = MeetingStore(root: root)
    let record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    try store.create(record)
    let meeting = store.folder(for: record.id)
    try MeetingAudioFixture.writeSegment(
      in: meeting, track: .microphone, index: 1, startMs: 0, frames: 16_000)
    _ = try store.saveNotes("notes", revision: 1, meeting: record.id)
    let checkpoints = MeetingProcessingCheckpointStore(meetingFolder: meeting)
    let checkpoint = MeetingCoordinatorTests.checkpoint(record.id)
    try checkpoints.save(checkpoint)
    let before = (
      try store.segmentFiles(meeting: record.id), try store.audioBytes(meeting: record.id),
      try store.loadDocuments(meeting: record.id)
    )
    for name in [
      MeetingStore.recordFileName, MeetingStore.notesFileName, MeetingStore.summaryFileName,
      MeetingStore.documentsFileName,
    ] {
      try Data("stale".utf8).write(
        to: meeting.appendingPathComponent(".\(name).\(UUID().uuidString).bak"))
    }
    try Data("stale".utf8).write(
      to: checkpoints.fileURL.deletingLastPathComponent()
        .appendingPathComponent(".checkpoint.json.\(UUID().uuidString).bak"))
    #expect(try store.load(id: record.id) == record)
    #expect(try store.loadAll().count == 1)
    #expect(try store.segmentFiles(meeting: record.id) == before.0)
    #expect(try store.audioBytes(meeting: record.id) == before.1)
    #expect(try store.loadDocuments(meeting: record.id) == before.2)
    #expect(checkpoints.load() == .checkpoint(checkpoint))
    try store.deleteAudio(meeting: record.id)
    #expect(try store.load(id: record.id).id == record.id)
    try store.deleteFolder(meeting: record.id)
    #expect(!FileManager.default.fileExists(atPath: meeting.path))
  }
}
