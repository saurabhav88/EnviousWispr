import CryptoKit
import EnviousWisprCore
import Foundation

/// #3147 PR4B: committing a verified compacted copy of a meeting's audio, and (later, behind the
/// C6 gate) retiring the recorder originals it supersedes.
///
/// **Authority**: the committed inventory on `meeting.json` (`MeetingRecord.compressedAudio`) is
/// the only thing that makes compacted files readable (`MeetingAudioSelection`). Until it is
/// saved, compacted output is temporary, whatever its state on disk.
///
/// **Order of a commit**, each step durable before the next: read the current record; check the
/// caller's expectations (transcript generation and logical segments) against it; check the
/// inventory maps every logical segment exactly once to an owned, correctly named output; check
/// the bytes of every source, proof and output against the inventory's identities (all of them
/// before any file moves); promote each verified candidate (`.m4a.partial`, synced) to its final name with an exclusive rename; sync
/// the folder; then save the patched record atomically. Nothing is deleted: every original stays.
///
/// **Retirement** (`removeSupersededPCM`) removes only the recorder files the committed
/// inventory names as sources, after re-reading and re-hashing every committed output and every
/// source it would remove. Nothing in the app calls it yet (main wires it after C6).
///
/// Both run on the caller's queue; production calls them through `MeetingFileWriter`, so they
/// are ordered with every other write of the meeting. They read the record from disk, never a
/// caller's copy, so a rename, notes or summary edit saved meanwhile survives.
extension MeetingStore {
  public enum CompactionError: Error, Equatable, Sendable {
    /// The meeting is being deleted, or its audio was deleted.
    case audioUnavailable
    /// The committed transcript generation is not the one the caller compacted under.
    case staleGeneration
    /// The record's logical segments are not the ones the caller compacted.
    case staleSegments
    /// A different inventory is already committed; a retry never republishes another.
    case alreadyCompacted
    /// The inventory is not a complete, owned, correctly named mapping (reason for the log).
    case invalidInventory(String)
    /// A file the operation needs is not in the meeting folder.
    case missingFile(String)
    /// A file's bytes are not the ones the inventory recorded.
    case identityMismatch(String)
    /// `removeSupersededPCM` was asked for an inventory that is not the committed one.
    case notCommitted
    /// A file step failed (`stage` names it); nothing after it ran.
    case fileStepFailed(stage: String, file: String, errno: Int32)
    /// Retirement removed `removed` originals, then could not remove `file`; the rest stay.
    case removalIncomplete(removed: Int, file: String, errno: Int32)
  }

  /// The file system calls compaction makes, so a test can fail any one of them; production
  /// uses `.system`.
  package struct CompactionSteps: Sendable {
    package var syncFile: @Sendable (String) -> Int32
    package var renameExclusive: @Sendable (_ from: String, _ to: String) -> Int32
    package var openDirectory: @Sendable (String) -> Int32
    package var syncDirectory: @Sendable (Int32) -> Int32
    package var unlink: @Sendable (String) -> Int32
    package var saveRecord: @Sendable (MeetingStore, MeetingRecord) throws -> Void

    package static let system = CompactionSteps(
      syncFile: { path in
        let fd = Foundation.open(path, O_RDONLY)
        guard fd >= 0 else { return -1 }
        defer { Foundation.close(fd) }
        return fcntl(fd, F_FULLFSYNC) == 0 ? 0 : -1
      },
      renameExclusive: { renamex_np($0, $1, UInt32(RENAME_EXCL)) },
      openDirectory: { Foundation.open($0, O_RDONLY) },
      syncDirectory: { fsync($0) },
      unlink: { Foundation.unlink($0) },
      saveRecord: { store, record in try store.save(record) })
  }

  // MARK: - Commit

  /// Commits `inventory` as the meeting's audio authority and returns the saved record.
  /// Idempotent: the same inventory already committed returns the record unchanged; a different
  /// one is refused. Throws (with nothing saved) on any failed check or file step.
  public func commitCompressedAudio(
    meeting id: UUID,
    expectedTranscriptGeneration: UUID?,
    expectedSegments: [MeetingTrackKind: [MeetingSegmentInfo]],
    inventory: MeetingCompressedInventory
  ) throws -> MeetingRecord {
    try commitCompressedAudio(
      meeting: id, expectedTranscriptGeneration: expectedTranscriptGeneration,
      expectedSegments: expectedSegments, inventory: inventory, steps: .system)
  }

  package func commitCompressedAudio(
    meeting id: UUID,
    expectedTranscriptGeneration: UUID?,
    expectedSegments: [MeetingTrackKind: [MeetingSegmentInfo]],
    inventory: MeetingCompressedInventory,
    steps: CompactionSteps
  ) throws -> MeetingRecord {
    var record = try currentRecordForCompaction(id)
    guard record.committedTranscriptGeneration == expectedTranscriptGeneration,
      inventory.transcriptGeneration == expectedTranscriptGeneration
    else { throw CompactionError.staleGeneration }
    guard Self.nonEmpty(record.segments) == Self.nonEmpty(expectedSegments) else {
      throw CompactionError.staleSegments
    }
    if let committed = record.compressedAudio {
      guard committed == inventory else { throw CompactionError.alreadyCompacted }
      return record
    }

    let dir = folder(for: id)
    let names = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
    try Self.validate(inventory, record: record, folderNames: names)

    // The originals and proofs are still exactly what was compacted.
    for segment in inventory.segments {
      try Self.expect(
        segment.sourceIdentity, at: dir.appendingPathComponent(segment.source.fileName))
    }
    for (name, identity) in inventory.cleanedProofs {
      guard names.contains(name) else { throw CompactionError.missingFile(name) }
      try Self.expect(identity, at: dir.appendingPathComponent(name))
    }

    // Every output is checked before any is promoted: a final already there (an earlier attempt
    // of this same inventory that stopped before its record was saved) only with the same bytes,
    // else its synced-to-be candidate.
    var promotions: [(candidate: URL, candidateName: String, final: URL, finalName: String)] = []
    for segment in inventory.segments {
      let finalName = segment.compressed.fileName
      let final = dir.appendingPathComponent(finalName)
      if names.contains(finalName) {
        try Self.expect(segment.compressedIdentity, at: final)
        continue
      }
      let candidateName = MeetingSegmentNaming.compactedFileName(
        source: segment.source, track: segment.track, variant: segment.variant,
        inventoryID: inventory.id, partial: true)
      guard names.contains(candidateName) else { throw CompactionError.missingFile(finalName) }
      let candidate = dir.appendingPathComponent(candidateName)
      try Self.expect(segment.compressedIdentity, at: candidate)
      promotions.append((candidate, candidateName, final, finalName))
    }
    for promotion in promotions {
      guard steps.syncFile(promotion.candidate.path) == 0 else {
        throw CompactionError.fileStepFailed(
          stage: "sync_output", file: promotion.candidateName, errno: errno)
      }
      guard steps.renameExclusive(promotion.candidate.path, promotion.final.path) == 0 else {
        throw CompactionError.fileStepFailed(
          stage: "promote", file: promotion.finalName, errno: errno)
      }
    }
    try Self.syncDirectory(dir, steps: steps)

    record.commitCompressedAudio(inventory)
    try steps.saveRecord(self, record)
    return record
  }

  // MARK: - Retirement

  /// Removes the recorder originals the committed inventory `inventoryID` supersedes and returns
  /// how many it removed (0 on a retry with nothing left). Before removing anything it re-reads
  /// the record, re-hashes every committed output and every original it would remove, and
  /// refuses on any difference. Removes only files named as sources in that inventory: never a
  /// compacted file, a proof, an unlisted file or a document. Not called in production yet.
  public func removeSupersededPCM(
    meeting id: UUID,
    expectedTranscriptGeneration: UUID?,
    inventoryID: UUID
  ) throws -> Int {
    try removeSupersededPCM(
      meeting: id, expectedTranscriptGeneration: expectedTranscriptGeneration,
      inventoryID: inventoryID, steps: .system)
  }

  package func removeSupersededPCM(
    meeting id: UUID,
    expectedTranscriptGeneration: UUID?,
    inventoryID: UUID,
    steps: CompactionSteps
  ) throws -> Int {
    let record = try currentRecordForCompaction(id)
    guard let inventory = record.compressedAudio, inventory.id == inventoryID else {
      throw CompactionError.notCommitted
    }
    guard record.committedTranscriptGeneration == expectedTranscriptGeneration,
      inventory.transcriptGeneration == expectedTranscriptGeneration
    else { throw CompactionError.staleGeneration }

    let dir = folder(for: id)
    let names = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
    // The committed copy must be whole and unchanged before any original goes.
    for segment in inventory.segments {
      guard names.contains(segment.compressed.fileName) else {
        throw CompactionError.missingFile(segment.compressed.fileName)
      }
      try Self.expect(
        segment.compressedIdentity, at: dir.appendingPathComponent(segment.compressed.fileName))
    }
    var originals: [String] = []
    for segment in inventory.segments where names.contains(segment.source.fileName) {
      try Self.expect(
        segment.sourceIdentity, at: dir.appendingPathComponent(segment.source.fileName))
      originals.append(segment.source.fileName)
    }

    var removed = 0
    for name in originals {
      guard steps.unlink(dir.appendingPathComponent(name).path) == 0 else {
        let failure = errno
        // What did go is made durable before the partial failure is reported.
        try? Self.syncDirectory(dir, steps: steps)
        throw CompactionError.removalIncomplete(removed: removed, file: name, errno: failure)
      }
      removed += 1
    }
    if removed > 0 { try Self.syncDirectory(dir, steps: steps) }
    return removed
  }

  // MARK: - Identity

  /// The exact bytes of `url`: its length and a full streaming SHA-256 (lowercase hex). The one
  /// definition compaction compares against, so the preparing side should use it too.
  public static func audioFileIdentity(at url: URL) throws -> MeetingAudioFileIdentity {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    var count: Int64 = 0
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
      hasher.update(data: chunk)
      count += Int64(chunk.count)
    }
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    return MeetingAudioFileIdentity(byteCount: count, sha256: digest)
  }

  // MARK: - Checks

  /// The current record, refused when this build may not change it or its audio is gone.
  private func currentRecordForCompaction(_ id: UUID) throws -> MeetingRecord {
    try refuseNewerFormat(id)
    guard FileManager.default.fileExists(atPath: recordURL(for: id).path) else {
      throw StoreError.meetingMissing
    }
    let record = try load(id: id)
    guard record.isWritableByThisBuild else { throw StoreError.newerFormat }
    guard !record.deletionRequested, record.audioKept else {
      throw CompactionError.audioUnavailable
    }
    return record
  }

  /// The segment lists with empty tracks dropped, so "no segments" and "empty list" agree.
  static func nonEmpty(_ segments: [MeetingTrackKind: [MeetingSegmentInfo]])
    -> [MeetingTrackKind: [MeetingSegmentInfo]]
  {
    segments.filter { !$0.value.isEmpty }
  }

  /// Every logical segment once, every output owned and correctly named, every cleaned original
  /// on disk covered: the complete set a reader will ask the selector for.
  static func validate(
    _ inventory: MeetingCompressedInventory, record: MeetingRecord, folderNames: Set<String>
  ) throws {
    guard inventory.version == MeetingCompressedInventory.currentVersion else {
      throw CompactionError.invalidInventory("version")
    }
    guard !inventory.segments.isEmpty else { throw CompactionError.invalidInventory("empty") }
    for segment in inventory.segments {
      let source = segment.source
      guard segment.variant == .raw || segment.track == .microphone,
        source.index > 0, source.startMs >= 0
      else { throw CompactionError.invalidInventory("segment") }
      // Recorder originals and owned outputs, named exactly as their writers name them: no path
      // component, no other attempt's file, no other segment's file.
      let expectedSource = MeetingSegmentNaming.fileName(
        track: segment.track, variant: segment.variant, index: source.index,
        startMs: source.startMs, partial: false)
      guard source.fileName == expectedSource else {
        throw CompactionError.invalidInventory("source_name")
      }
      let output = segment.compressed
      guard output.index == source.index, output.startMs == source.startMs,
        output.frameCount == source.frameCount,
        output.fileName
          == MeetingSegmentNaming.compactedFileName(
            source: source, track: segment.track, variant: segment.variant,
            inventoryID: inventory.id, partial: false)
      else { throw CompactionError.invalidInventory("output_name") }
      guard folderNames.contains(source.fileName) else {
        throw CompactionError.missingFile(source.fileName)
      }
    }
    for name in inventory.cleanedProofs.keys where !MeetingSegmentNaming.isCleanedProof(name) {
      throw CompactionError.invalidInventory("proof_name")
    }

    // The complete logical set: the record's segments (every track) plus every cleaned original
    // on disk, whose descriptor the inventory carries (the folder is the cleaned copy's
    // authority; its frame count is what preparation decoded and hashed).
    let cleanedOnDisk = Set(
      folderNames.compactMap { name -> Int? in
        guard let parsed = MeetingSegmentNaming.parse(name), !parsed.partial,
          parsed.variant == .cleaned
        else { return nil }
        return parsed.index
      })
    let cleanedInInventory = inventory.segments.filter { $0.variant == .cleaned }
    guard Set(cleanedInInventory.map(\.source.index)) == cleanedOnDisk else {
      throw CompactionError.invalidInventory("cleaned_set")
    }
    var logical: [MeetingLogicalSegment] = []
    for track in MeetingTrackKind.allCases {
      for segment in record.segments[track] ?? [] {
        logical.append(MeetingLogicalSegment(track: track, variant: .raw, segment: segment))
      }
    }
    for segment in cleanedInInventory {
      logical.append(
        MeetingLogicalSegment(track: .microphone, variant: .cleaned, segment: segment.source))
    }
    do {
      _ = try MeetingAudioSelection.select(logical: logical, inventory: inventory)
    } catch {
      throw CompactionError.invalidInventory("selection_\(error)")
    }
  }

  static func expect(_ identity: MeetingAudioFileIdentity, at url: URL) throws {
    let actual: MeetingAudioFileIdentity
    do {
      actual = try audioFileIdentity(at: url)
    } catch {
      throw CompactionError.missingFile(url.lastPathComponent)
    }
    guard actual == identity else {
      throw CompactionError.identityMismatch(url.lastPathComponent)
    }
  }

  static func syncDirectory(_ dir: URL, steps: CompactionSteps) throws {
    let fd = steps.openDirectory(dir.path)
    guard fd >= 0 else {
      throw CompactionError.fileStepFailed(stage: "open_directory", file: "", errno: errno)
    }
    defer { Foundation.close(fd) }
    guard steps.syncDirectory(fd) == 0 else {
      throw CompactionError.fileStepFailed(stage: "sync_directory", file: "", errno: errno)
    }
  }
}
