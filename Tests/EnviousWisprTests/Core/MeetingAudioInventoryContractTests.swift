import EnviousWisprCore
import Foundation
import Testing

/// #3147 PR4B contract: compacted meeting audio is named, recorded and selected so a reader
/// opens exactly one file per logical segment and never mixes a CAF with its compacted copy.
/// Class: `.productOutcome`: when these fail, a meeting plays or transcribes duplicated, missing
/// or wrong audio, or an older build reads around compacted files.
@Suite("Meeting compacted audio contract (#3147 PR4B)", .tags(.productOutcome))
struct MeetingAudioInventoryContractTests {
  private static let id = UUID(uuidString: "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9")!
  private static let mic1 = MeetingSegmentInfo(
    index: 1, fileName: "mic-00001-s000000000.caf", startMs: 0, frameCount: 960_000)
  private static let mic2 = MeetingSegmentInfo(
    index: 2, fileName: "mic-00002-s000065000.caf", startMs: 65_000, frameCount: 480_000)
  private static let identity = MeetingAudioFileIdentity(byteCount: 10, sha256: "ab")

  private static func compacted(_ source: MeetingSegmentInfo) -> MeetingCompressedSegment {
    let name = MeetingSegmentNaming.compactedFileName(
      source: source, track: .microphone, variant: .raw, inventoryID: id, partial: false)
    return MeetingCompressedSegment(
      track: .microphone, variant: .raw, source: source, sourceIdentity: identity,
      compressed: MeetingSegmentInfo(
        index: source.index, fileName: name, startMs: source.startMs,
        frameCount: source.frameCount),
      compressedIdentity: identity)
  }

  private static func inventory(_ segments: [MeetingCompressedSegment])
    -> MeetingCompressedInventory
  {
    MeetingCompressedInventory(
      id: id, transcriptGeneration: nil, segments: segments, cleanedProofs: [:])
  }

  private static let logical = [
    MeetingLogicalSegment(track: .microphone, variant: .raw, segment: mic1),
    MeetingLogicalSegment(track: .microphone, variant: .raw, segment: mic2),
  ]

  @Test(
    "compacted names carry index, start and inventory id, and parse back; the old parser ignores them"
  )
  func naming() throws {
    let name = MeetingSegmentNaming.compactedFileName(
      source: Self.mic2, track: .microphone, variant: .cleaned, inventoryID: Self.id,
      partial: true)
    #expect(name == "micclean-00002-s000065000-c0a1b2c3d4e5f60718293a4b5c6d7e8f9.m4a.partial")
    let parsed = try #require(MeetingSegmentNaming.parseAny(name))
    #expect(parsed.track == .microphone && parsed.variant == .cleaned)
    #expect(parsed.index == 2 && parsed.startMs == 65_000 && parsed.partial)
    #expect(parsed.encoding == .aacM4A && parsed.inventoryID == Self.id)
    #expect(MeetingSegmentNaming.parse(name) == nil, "existing readers never see compacted files")
    let caf = try #require(MeetingSegmentNaming.parse(Self.mic1.fileName))
    #expect(caf.encoding == .pcmCAF && caf.inventoryID == nil)
    #expect(MeetingSegmentNaming.parseAny(Self.mic1.fileName) == caf)
    #expect(MeetingSegmentNaming.parseAny("mic-00001-s000000000-cXYZ.m4a") == nil)
  }

  @Test("committing an inventory keeps the record's logical audio and raises its format to 5")
  func recordAdoption() throws {
    var record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    record.segments[.microphone] = [Self.mic1, Self.mic2]
    let legacy = try JSONDecoder().decode(
      MeetingRecord.self, from: JSONEncoder().encode(record))
    #expect(legacy.compressedAudio == nil, "a record without the field decodes as not compacted")
    let inventory = Self.inventory([Self.compacted(Self.mic1), Self.compacted(Self.mic2)])
    record.commitCompressedAudio(inventory)
    #expect(record.formatVersion == MeetingRecord.compressedAudioFormatVersion)
    #expect(record.segments[.microphone] == [Self.mic1, Self.mic2], "logical segments unchanged")
    let reread = try JSONDecoder().decode(MeetingRecord.self, from: JSONEncoder().encode(record))
    #expect(reread == record)
  }

  @Test("the selector reads CAF without an inventory and only the compacted file with one")
  func selection() throws {
    let plain = try MeetingAudioSelection.select(logical: Self.logical, inventory: nil)
    #expect(plain.map(\.fileName) == [Self.mic1.fileName, Self.mic2.fileName])
    #expect(plain.allSatisfy { $0.encoding == .pcmCAF })
    let inventory = Self.inventory([Self.compacted(Self.mic2), Self.compacted(Self.mic1)])
    let chosen = try MeetingAudioSelection.select(logical: Self.logical, inventory: inventory)
    #expect(chosen.map(\.logical) == [Self.mic1, Self.mic2], "timeline kept, in reader order")
    #expect(chosen.allSatisfy { $0.encoding == .aacM4A && $0.fileName.hasSuffix(".m4a") })
  }

  @Test("the selector refuses incomplete, duplicated, conflicting or newer inventories")
  func refusals() {
    let one = Self.inventory([Self.compacted(Self.mic1)])
    #expect(throws: MeetingAudioSelection.Refusal.incompleteInventory) {
      try MeetingAudioSelection.select(logical: Self.logical, inventory: one)
    }
    let twice = Self.inventory([
      Self.compacted(Self.mic1), Self.compacted(Self.mic1), Self.compacted(Self.mic2),
    ])
    #expect(throws: MeetingAudioSelection.Refusal.duplicateInInventory(Self.logical[0].key)) {
      try MeetingAudioSelection.select(logical: Self.logical, inventory: twice)
    }
    let moved = MeetingSegmentInfo(
      index: 2, fileName: Self.mic2.fileName, startMs: 66_000, frameCount: 480_000)
    let conflicting = Self.inventory([Self.compacted(Self.mic1), Self.compacted(moved)])
    #expect(throws: MeetingAudioSelection.Refusal.conflictingSource(Self.logical[1].key)) {
      try MeetingAudioSelection.select(logical: Self.logical, inventory: conflicting)
    }
    #expect(throws: MeetingAudioSelection.Refusal.duplicateLogical(Self.logical[0].key)) {
      try MeetingAudioSelection.select(logical: [Self.logical[0], Self.logical[0]], inventory: nil)
    }
    let newer = MeetingCompressedInventory(
      version: MeetingCompressedInventory.currentVersion + 1, id: Self.id,
      transcriptGeneration: nil, segments: [], cleanedProofs: [:])
    #expect(throws: MeetingAudioSelection.Refusal.unsupportedInventoryVersion(2)) {
      try MeetingAudioSelection.select(logical: Self.logical, inventory: newer)
    }
  }
}
