import EnviousWisprAppKitTestSupport
import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprStorage

/// #3147 PR4B lane A2: when these fail, a meeting's compacted audio becomes its audio while a
/// file is missing, changed or someone else's, a crash or full disk mid-commit leaves the meeting
/// with no usable audio or a record pointing at files that are not there, a rename or notes edit
/// made meanwhile is lost, or retiring the originals removes a file the compacted copy does not
/// replace (or removes anything at all when the copy is damaged).
@Suite("Meeting compacted audio commit and retirement", .tags(.productOutcome))
struct MeetingStoreCompactionCommitTests {
  struct Fixture {
    let store: MeetingStore
    let record: MeetingRecord
    let inventory: MeetingCompressedInventory
    var dir: URL { store.folder(for: record.id) }
    var id: UUID { record.id }

    func exists(_ name: String) -> Bool {
      FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
    }

    func write(_ name: String, _ text: String) throws {
      try Data(text.utf8).write(to: dir.appendingPathComponent(name))
    }

    func commit(
      _ inventory: MeetingCompressedInventory? = nil, generation: UUID?? = nil,
      segments: [MeetingTrackKind: [MeetingSegmentInfo]]? = nil,
      steps: MeetingStore.CompactionSteps = .system
    ) throws -> MeetingRecord {
      try store.commitCompressedAudio(
        meeting: id,
        expectedTranscriptGeneration: generation ?? record.committedTranscriptGeneration,
        expectedSegments: segments ?? record.segments, inventory: inventory ?? self.inventory,
        steps: steps)
    }

    func retire(inventoryID: UUID? = nil, steps: MeetingStore.CompactionSteps = .system) throws
      -> Int
    {
      try store.removeSupersededPCM(
        meeting: id, expectedTranscriptGeneration: record.committedTranscriptGeneration,
        inventoryID: inventoryID ?? inventory.id, steps: steps)
    }

    var cafNames: [String] { inventory.segments.map(\.source.fileName) }
    var outputNames: [String] { inventory.segments.map(\.compressed.fileName) }
    var candidateNames: [String] {
      inventory.segments.map {
        MeetingSegmentNaming.compactedFileName(
          source: $0.source, track: $0.track, variant: $0.variant, inventoryID: inventory.id,
          partial: true)
      }
    }
    static let proofName = MeetingSegmentNaming.cleanedProofName(first: 1, last: 2)
  }

  static func segment(_ track: MeetingTrackKind, _ index: Int, cleaned: Bool = false)
    -> MeetingSegmentInfo
  {
    MeetingSegmentInfo(
      index: index,
      fileName: MeetingSegmentNaming.fileName(
        track: track, variant: cleaned ? .cleaned : .raw, index: index,
        startMs: (index - 1) * 60_000, partial: false),
      startMs: (index - 1) * 60_000, frameCount: 960_000)
  }

  /// A ready meeting with two microphone segments, one call segment, a complete cleaned copy
  /// and its proof on disk, and a verified candidate (`.m4a.partial`) for each of the five
  /// logical segments, described by `inventory`.
  static func fixture(
    generation: UUID? = UUID(), edit: (inout MeetingRecord) -> Void = { _ in }
  ) throws -> Fixture {
    let root = TestTemporaryDirectory.url
      .appendingPathComponent("MeetingCompactionCommit-\(UUID().uuidString)", isDirectory: true)
    let store = MeetingStore(root: root)
    var record = MeetingRecord(
      engine: .parakeet, trackStatus: [.microphone: .captured, .callSound: .captured])
    record.state = generation == nil ? .queued : .ready
    record.committedTranscriptAttemptID = generation
    record.segments = [
      .microphone: [segment(.microphone, 1), segment(.microphone, 2)],
      .callSound: [segment(.callSound, 1)],
    ]
    edit(&record)
    try store.create(record)
    let dir = store.folder(for: record.id)
    let inventoryID = UUID()
    var segments: [MeetingCompressedSegment] = []
    let logical: [(MeetingTrackKind, MeetingSegmentVariant, MeetingSegmentInfo)] = [
      (.microphone, .raw, segment(.microphone, 1)), (.microphone, .raw, segment(.microphone, 2)),
      (.callSound, .raw, segment(.callSound, 1)),
      (.microphone, .cleaned, segment(.microphone, 1, cleaned: true)),
      (.microphone, .cleaned, segment(.microphone, 2, cleaned: true)),
    ]
    for (track, variant, source) in logical {
      let sourceURL = dir.appendingPathComponent(source.fileName)
      try Data("pcm \(source.fileName)".utf8).write(to: sourceURL)
      let compressed = MeetingSegmentInfo(
        index: source.index,
        fileName: MeetingSegmentNaming.compactedFileName(
          source: source, track: track, variant: variant, inventoryID: inventoryID, partial: false),
        startMs: source.startMs, frameCount: source.frameCount)
      let candidate = dir.appendingPathComponent(
        MeetingSegmentNaming.compactedFileName(
          source: source, track: track, variant: variant, inventoryID: inventoryID, partial: true))
      try Data("aac \(source.fileName)".utf8).write(to: candidate)
      segments.append(
        MeetingCompressedSegment(
          track: track, variant: variant, source: source,
          sourceIdentity: try MeetingStore.audioFileIdentity(at: sourceURL), compressed: compressed,
          compressedIdentity: try MeetingStore.audioFileIdentity(at: candidate)))
    }
    // The writer's real proof: the cleaned twins it finalized, encoded.
    let proof = dir.appendingPathComponent(Fixture.proofName)
    try JSONEncoder().encode(
      MeetingCleanedProof(segments: [
        segment(.microphone, 1, cleaned: true), segment(.microphone, 2, cleaned: true),
      ])
    ).write(to: proof)
    let inventory = MeetingCompressedInventory(
      id: inventoryID, transcriptGeneration: generation, segments: segments,
      cleanedProofs: [Fixture.proofName: try MeetingStore.audioFileIdentity(at: proof)])
    return Fixture(store: store, record: record, inventory: inventory)
  }

  /// System steps where `syncFile`, `renameExclusive`, `syncDirectory` or `unlink` fails after
  /// `successes` calls (each step counted on its own).
  enum FailingStep { case syncFile, renameExclusive, syncDirectory, unlink }

  static func failing(_ step: FailingStep, after successes: Int = 0)
    -> MeetingStore.CompactionSteps
  {
    var steps = MeetingStore.CompactionSteps.system
    let counter = Counter()
    switch step {
    case .syncFile:
      let original = steps.syncFile
      steps.syncFile = { counter.next() >= successes ? -1 : original($0) }
    case .renameExclusive:
      let original = steps.renameExclusive
      steps.renameExclusive = { counter.next() >= successes ? -1 : original($0, $1) }
    case .syncDirectory:
      let original = steps.syncDirectory
      steps.syncDirectory = { counter.next() >= successes ? -1 : original($0) }
    case .unlink:
      let original = steps.unlink
      steps.unlink = { counter.next() >= successes ? -1 : original($0) }
    }
    return steps
  }

  final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
      lock.lock()
      defer { lock.unlock() }
      value += 1
      return value - 1
    }
  }

  // MARK: - Commit

  @Test("a verified inventory is promoted and committed; every original stays")
  func commitPromotesAndSaves() throws {
    let f = try Self.fixture()
    let saved = try f.commit()
    #expect(saved.compressedAudio == f.inventory)
    #expect(saved.formatVersion == MeetingRecord.compressedAudioFormatVersion)
    #expect(try f.store.load(id: f.id) == saved)
    for name in f.outputNames { #expect(f.exists(name), "\(name) promoted") }
    for name in f.candidateNames { #expect(f.exists(name) == false, "\(name) renamed away") }
    for name in f.cafNames { #expect(f.exists(name), "\(name) kept") }
    #expect(f.exists(Fixture.proofName))
    let usage = try #require(try f.store.audioUsage())
    #expect(usage.temporaryBytes == 0)
    #expect(usage.committedBytes == (try f.store.audioBytes(meeting: f.id)))
  }

  @Test("edits saved while compacting survive the commit; the record is read fresh")
  func metadataEditsSurvive() throws {
    let f = try Self.fixture()
    var edited = try f.store.load(id: f.id)
    edited.title = "Board review"
    edited.speakerOutcomes = [.callSound: .labeled]
    edited.echoTurnIDs = ["m1-1000"]
    try f.store.save(edited)
    try f.write("notes.json", "{}")
    let saved = try f.commit()
    #expect(saved.title == "Board review")
    #expect(saved.speakerOutcomes == [.callSound: .labeled])
    #expect(saved.echoTurnIDs == ["m1-1000"])
    #expect(saved.transcriptID == f.record.transcriptID)
    #expect(saved.committedTranscriptGeneration == f.record.committedTranscriptGeneration)
    #expect(saved.segments == f.record.segments)
    #expect(f.exists("notes.json"))
  }

  @Test("a meeting with no committed transcript compacts under a nil generation, compared as is")
  func nilGenerationIsLegitimate() throws {
    let f = try Self.fixture(generation: nil)
    #expect(f.record.committedTranscriptGeneration == nil)
    let saved = try f.commit()
    #expect(saved.compressedAudio?.transcriptGeneration == nil)
    #expect(saved.committedTranscriptGeneration == nil)
  }

  @Test("committing the same inventory again is a no-op; a different one is refused")
  func commitIsIdempotent() throws {
    let f = try Self.fixture()
    let first = try f.commit()
    #expect(try f.commit() == first)
    let other = MeetingCompressedInventory(
      id: UUID(), transcriptGeneration: f.inventory.transcriptGeneration,
      segments: f.inventory.segments, cleanedProofs: f.inventory.cleanedProofs)
    #expect(throws: MeetingStore.CompactionError.alreadyCompacted) { try f.commit(other) }
    #expect(try f.store.load(id: f.id).compressedAudio == f.inventory)
  }

  @Test("a changed transcript generation or segment list refuses the commit")
  func staleExpectationsRefuse() throws {
    let f = try Self.fixture()
    #expect(throws: MeetingStore.CompactionError.staleGeneration) {
      try f.commit(generation: .some(UUID()))
    }
    let wrongInventory = MeetingCompressedInventory(
      id: f.inventory.id, transcriptGeneration: UUID(), segments: f.inventory.segments,
      cleanedProofs: f.inventory.cleanedProofs)
    #expect(throws: MeetingStore.CompactionError.staleGeneration) { try f.commit(wrongInventory) }
    #expect(throws: MeetingStore.CompactionError.staleSegments) {
      try f.commit(segments: [.microphone: [Self.segment(.microphone, 1)]])
    }
    // A retranscription (new generation) saved after the snapshot: the caller's view is stale.
    var moved = try f.store.load(id: f.id)
    moved.committedTranscriptAttemptID = UUID()
    try f.store.save(moved)
    #expect(throws: MeetingStore.CompactionError.staleGeneration) { try f.commit() }
    #expect(try f.store.load(id: f.id).compressedAudio == nil)
    for name in f.candidateNames { #expect(f.exists(name)) }
  }

  @Test("a meeting being deleted, without audio, missing, newer or unreadable is refused")
  func unavailableMeetingsRefuse() throws {
    let deleting = try Self.fixture { $0.deletionRequested = true }
    #expect(throws: MeetingStore.CompactionError.audioUnavailable) { try deleting.commit() }
    let noAudio = try Self.fixture { $0.audioKept = false }
    #expect(throws: MeetingStore.CompactionError.audioUnavailable) { try noAudio.commit() }

    let missing = try Self.fixture()
    try FileManager.default.removeItem(at: missing.store.recordURL(for: missing.id))
    #expect(throws: MeetingStore.StoreError.meetingMissing) { try missing.commit() }

    let newer = try Self.fixture()
    let url = newer.store.recordURL(for: newer.id)
    var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    json["formatVersion"] = MeetingRecord.currentFormatVersion + 1
    try JSONSerialization.data(withJSONObject: json).write(to: url)
    #expect(throws: MeetingStore.StoreError.newerFormat) { try newer.commit() }

    let corrupt = try Self.fixture()
    try Data("{".utf8).write(to: corrupt.store.recordURL(for: corrupt.id))
    #expect(throws: (any Error).self) { try corrupt.commit() }
    for name in corrupt.candidateNames { #expect(corrupt.exists(name), "nothing promoted") }
  }

  // MARK: - Invalid inventories

  static func replacing(
    _ inventory: MeetingCompressedInventory, version: Int? = nil,
    segments: [MeetingCompressedSegment]? = nil,
    proofs: [String: MeetingAudioFileIdentity]? = nil
  ) -> MeetingCompressedInventory {
    MeetingCompressedInventory(
      version: version ?? inventory.version, id: inventory.id,
      transcriptGeneration: inventory.transcriptGeneration,
      segments: segments ?? inventory.segments, cleanedProofs: proofs ?? inventory.cleanedProofs)
  }

  static func renamed(_ s: MeetingCompressedSegment, output: String? = nil, frames: Int? = nil)
    -> MeetingCompressedSegment
  {
    MeetingCompressedSegment(
      track: s.track, variant: s.variant, source: s.source, sourceIdentity: s.sourceIdentity,
      compressed: MeetingSegmentInfo(
        index: s.compressed.index, fileName: output ?? s.compressed.fileName,
        startMs: s.compressed.startMs, frameCount: frames ?? s.compressed.frameCount),
      compressedIdentity: s.compressedIdentity)
  }

  @Test("an incomplete, conflicting, foreign or unsafe inventory is refused and nothing moves")
  func invalidInventoriesRefuse() throws {
    let f = try Self.fixture()
    let segments = f.inventory.segments
    let otherAttempt = MeetingSegmentNaming.compactedFileName(
      source: segments[0].source, track: .microphone, variant: .raw, inventoryID: UUID(),
      partial: false)
    let cases: [(String, MeetingCompressedInventory)] = [
      ("unknown version", Self.replacing(f.inventory, version: 2)),
      ("a raw segment missing", Self.replacing(f.inventory, segments: Array(segments.dropFirst()))),
      (
        "a cleaned original on disk not covered",
        Self.replacing(f.inventory, segments: Array(segments.dropLast()))
      ),
      ("a segment twice", Self.replacing(f.inventory, segments: segments + [segments[0]])),
      (
        "another attempt's output",
        Self.replacing(
          f.inventory,
          segments: [Self.renamed(segments[0], output: otherAttempt)] + segments.dropFirst())
      ),
      (
        "a path outside the folder",
        Self.replacing(
          f.inventory,
          segments: [Self.renamed(segments[0], output: "../\(segments[0].compressed.fileName)")]
            + segments.dropFirst())
      ),
      (
        "a moved frame count",
        Self.replacing(
          f.inventory, segments: [Self.renamed(segments[0], frames: 959_000)] + segments.dropFirst()
        )
      ),
      (
        "a proof that is not a proof",
        Self.replacing(f.inventory, proofs: ["notes.json": segments[0].sourceIdentity])
      ),
      ("no segments", Self.replacing(f.inventory, segments: [])),
      ("the folder's proof left out", Self.replacing(f.inventory, proofs: [:])),
    ]
    for (label, inventory) in cases {
      #expect(throws: (any Error).self, "\(label)") { try f.commit(inventory) }
    }
    #expect(try f.store.load(id: f.id).compressedAudio == nil)
    for name in f.candidateNames { #expect(f.exists(name), "\(name) untouched") }
    for name in f.outputNames { #expect(f.exists(name) == false) }
    // The fixture itself is valid: the same store commits it afterwards.
    #expect(try f.commit().compressedAudio == f.inventory)
  }

  @Test("two cleaned originals sharing an index are two entries; covering one is refused")
  func cleanedSetComparesFileNames() throws {
    let f = try Self.fixture()
    // A second cleaned final with index 1 but another start, as a damaged or duplicated folder
    // could hold: the inventory covering only the first must not commit.
    let twin = MeetingSegmentNaming.fileName(
      track: .microphone, variant: .cleaned, index: 1, startMs: 30_000, partial: false)
    try f.write(twin, "pcm twin")
    #expect(throws: MeetingStore.CompactionError.invalidInventory("cleaned_set")) {
      try f.commit()
    }
    #expect(try f.store.load(id: f.id).compressedAudio == nil)
  }

  @Test("changed or missing bytes anywhere refuse the commit before anything is promoted")
  func identitiesAreChecked() throws {
    let changedSource = try Self.fixture()
    try changedSource.write(changedSource.cafNames[2], "pcm edited")
    #expect(
      throws: MeetingStore.CompactionError.identityMismatch(changedSource.cafNames[2])
    ) { try changedSource.commit() }

    let changedOutput = try Self.fixture()
    try changedOutput.write(changedOutput.candidateNames[4], "aac edited")
    #expect(
      throws: MeetingStore.CompactionError.identityMismatch(changedOutput.candidateNames[4])
    ) { try changedOutput.commit() }

    let missingOutput = try Self.fixture()
    try FileManager.default.removeItem(
      at: missingOutput.dir.appendingPathComponent(missingOutput.candidateNames[1]))
    #expect(
      throws: MeetingStore.CompactionError.missingFile(missingOutput.outputNames[1])
    ) { try missingOutput.commit() }

    let missingProof = try Self.fixture()
    try FileManager.default.removeItem(
      at: missingProof.dir.appendingPathComponent(Fixture.proofName))
    #expect(throws: MeetingStore.CompactionError.missingFile(Fixture.proofName)) {
      try missingProof.commit()
    }

    let changedProof = try Self.fixture()
    try changedProof.write(Fixture.proofName, "{}")
    #expect(throws: MeetingStore.CompactionError.identityMismatch(Fixture.proofName)) {
      try changedProof.commit()
    }
    for f in [changedSource, changedOutput, missingOutput, missingProof, changedProof] {
      #expect(try f.store.load(id: f.id).compressedAudio == nil)
      for name in f.outputNames { #expect(f.exists(name) == false, "nothing promoted") }
    }
  }

  // MARK: - Failure boundaries

  @Test("a failed promotion leaves no committed inventory; the retry finishes the same commit")
  func failedPromotionRetries() throws {
    let f = try Self.fixture()
    #expect(throws: (any Error).self) {
      try f.commit(steps: Self.failing(.renameExclusive, after: 2))
    }
    #expect(try f.store.load(id: f.id).compressedAudio == nil)
    #expect(f.outputNames.filter(f.exists).count == 2)
    // Promoted but uncommitted output is still temporary, never the meeting's audio.
    let usage = try #require(try f.store.audioUsage())
    #expect(usage.temporaryBytes > 0)
    #expect(try f.commit().compressedAudio == f.inventory)
    for name in f.outputNames { #expect(f.exists(name)) }
  }

  @Test("a failed output or folder sync stops the commit before the record changes")
  func failedSyncRefuses() throws {
    let output = try Self.fixture()
    #expect(throws: (any Error).self) { try output.commit(steps: Self.failing(.syncFile)) }
    #expect(try output.store.load(id: output.id).compressedAudio == nil)
    for name in output.outputNames { #expect(output.exists(name) == false) }

    let folder = try Self.fixture()
    #expect(throws: (any Error).self) { try folder.commit(steps: Self.failing(.syncDirectory)) }
    #expect(try folder.store.load(id: folder.id).compressedAudio == nil)
    #expect(try folder.commit().compressedAudio == folder.inventory)
  }

  @Test("a failed record save (full disk) keeps the originals as the audio; the retry commits")
  func failedSaveRetries() throws {
    struct DiskFull: Error {}
    let f = try Self.fixture()
    var steps = MeetingStore.CompactionSteps.system
    steps.saveRecord = { _, _ in throw DiskFull() }
    #expect(throws: DiskFull.self) { try f.commit(steps: steps) }
    #expect(try f.store.load(id: f.id).compressedAudio == nil)
    for name in f.cafNames { #expect(f.exists(name)) }
    #expect(try f.commit().compressedAudio == f.inventory)
  }

  // MARK: - Retirement

  @Test("retirement removes only the originals the committed inventory names")
  func retirementRemovesListedOriginalsOnly() throws {
    let f = try Self.fixture()
    _ = try f.commit()
    let unlisted = MeetingSegmentNaming.fileName(
      track: .microphone, index: 9, startMs: 480_000, partial: false)
    try f.write(unlisted, "pcm stray")
    try f.write("notes.md", "notes")
    #expect(try f.retire() == f.cafNames.count)
    for name in f.cafNames { #expect(f.exists(name) == false, "\(name) retired") }
    for name in f.outputNames { #expect(f.exists(name), "\(name) kept") }
    for name in [unlisted, "notes.md", Fixture.proofName, MeetingStore.recordFileName] {
      #expect(f.exists(name), "\(name) kept")
    }
    #expect(try f.retire() == 0, "a retry with nothing left removes nothing")
    #expect(try f.store.load(id: f.id).compressedAudio == f.inventory)
  }

  @Test("retirement refuses an uncommitted inventory, a stale generation or a damaged copy")
  func retirementRefuses() throws {
    let uncommitted = try Self.fixture()
    #expect(throws: MeetingStore.CompactionError.notCommitted) { try uncommitted.retire() }

    let other = try Self.fixture()
    _ = try other.commit()
    #expect(throws: MeetingStore.CompactionError.notCommitted) {
      try other.retire(inventoryID: UUID())
    }
    var moved = try other.store.load(id: other.id)
    moved.committedTranscriptAttemptID = UUID()
    try other.store.save(moved)
    #expect(throws: MeetingStore.CompactionError.staleGeneration) { try other.retire() }

    let damaged = try Self.fixture()
    _ = try damaged.commit()
    try damaged.write(damaged.outputNames[3], "aac truncated")
    #expect(throws: MeetingStore.CompactionError.identityMismatch(damaged.outputNames[3])) {
      try damaged.retire()
    }

    let gone = try Self.fixture()
    _ = try gone.commit()
    try FileManager.default.removeItem(at: gone.dir.appendingPathComponent(gone.outputNames[0]))
    #expect(throws: MeetingStore.CompactionError.missingFile(gone.outputNames[0])) {
      try gone.retire()
    }

    let changedOriginal = try Self.fixture()
    _ = try changedOriginal.commit()
    try changedOriginal.write(changedOriginal.cafNames[1], "pcm rewritten")
    #expect(
      throws: MeetingStore.CompactionError.identityMismatch(changedOriginal.cafNames[1])
    ) { try changedOriginal.retire() }

    for f in [other, damaged, gone, changedOriginal] {
      for name in f.cafNames { #expect(f.exists(name), "\(name) must stay") }
    }
  }

  @Test("an interrupted retirement reports what it removed, keeps the rest, and resumes")
  func interruptedRetirementResumes() throws {
    let f = try Self.fixture()
    _ = try f.commit()
    do {
      _ = try f.retire(steps: Self.failing(.unlink, after: 2))
      Issue.record("the third removal failed; retirement must say so")
    } catch MeetingStore.CompactionError.removalIncomplete(let removed, let file, _) {
      #expect(removed == 2)
      #expect(file == f.cafNames[2])
    }
    #expect(f.cafNames.filter(f.exists).count == f.cafNames.count - 2)
    for name in f.outputNames { #expect(f.exists(name)) }
    #expect(try f.retire() == f.cafNames.count - 2)
    #expect(f.cafNames.filter(f.exists).isEmpty)
  }

  @Test("a failed folder sync after retirement says how many originals went; the copy stays")
  func retirementSyncFailureKeepsTheCount() throws {
    let f = try Self.fixture()
    _ = try f.commit()
    do {
      _ = try f.retire(steps: Self.failing(.syncDirectory))
      Issue.record("the folder sync failed; retirement must say so")
    } catch MeetingStore.CompactionError.retirementSyncFailed(let removed, _) {
      #expect(removed == f.cafNames.count)
    }
    for name in f.outputNames { #expect(f.exists(name)) }
    #expect(try f.store.load(id: f.id).compressedAudio == f.inventory)
  }

  @Test("a file's identity is its length and full SHA-256")
  func identityIsFullHash() throws {
    let url = TestTemporaryDirectory.url.appendingPathComponent("identity-\(UUID().uuidString)")
    try Data("abc".utf8).write(to: url)
    #expect(
      try MeetingStore.audioFileIdentity(at: url)
        == MeetingAudioFileIdentity(
          byteCount: 3,
          sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"))
  }
}
