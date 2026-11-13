import Foundation

/// #3147 PR4B: how one meeting segment file stores its audio. `pcmCAF` is what the recorder
/// writes (16 kHz mono 16-bit PCM in CAF, `MeetingAudioFormat`); `aacM4A` is the compacted copy
/// (AAC-LC 16 kHz mono in M4A, made by the production `.meeting` encoder).
public enum MeetingAudioEncoding: String, Codable, Sendable {
  case pcmCAF
  case aacM4A
}

/// #3147 PR4B: the exact bytes of one owned audio or proof file, as a full streaming SHA-256
/// (never PR3's sampled imported-file fingerprint).
public struct MeetingAudioFileIdentity: Codable, Equatable, Hashable, Sendable {
  public let byteCount: Int64
  public let sha256: String

  public init(byteCount: Int64, sha256: String) {
    self.byteCount = byteCount
    self.sha256 = sha256
  }
}

/// #3147 PR4B: one logical segment (track, copy, index) and the compacted file that now holds
/// it. `source` keeps the recorder's descriptor (index, start, frames, CAF name) so timeline,
/// gaps and boundaries never move; `compressed` names the M4A file with the same index, start and
/// logical frame count.
public struct MeetingCompressedSegment: Codable, Equatable, Sendable {
  public let track: MeetingTrackKind
  public let variant: MeetingSegmentVariant
  public let source: MeetingSegmentInfo
  public let sourceIdentity: MeetingAudioFileIdentity
  public let compressed: MeetingSegmentInfo
  public let compressedIdentity: MeetingAudioFileIdentity

  public init(
    track: MeetingTrackKind, variant: MeetingSegmentVariant, source: MeetingSegmentInfo,
    sourceIdentity: MeetingAudioFileIdentity, compressed: MeetingSegmentInfo,
    compressedIdentity: MeetingAudioFileIdentity
  ) {
    self.track = track
    self.variant = variant
    self.source = source
    self.sourceIdentity = sourceIdentity
    self.compressed = compressed
    self.compressedIdentity = compressedIdentity
  }

  public var key: MeetingAudioSegmentKey {
    MeetingAudioSegmentKey(track: track, variant: variant, index: source.index)
  }
}

/// #3147 PR4B: a verified, committed set of compacted segments for one meeting. Committed on the
/// record (`MeetingRecord.compressedAudio`) only after every output was decoded and checked; until
/// then compacted files are temporary and never readable authority.
public struct MeetingCompressedInventory: Codable, Equatable, Sendable {
  public static let currentVersion = 1

  public let version: Int
  public let id: UUID
  /// The committed transcript generation the inventory was made under; nil when the meeting had
  /// none (a legitimate state, compared faithfully, never minted by compaction).
  public let transcriptGeneration: UUID?
  public let segments: [MeetingCompressedSegment]
  /// The cleaned-copy proof files the cleaned segments were eligible under, by file name, with
  /// their exact bytes, so recovery can carry proof across representations.
  public let cleanedProofs: [String: MeetingAudioFileIdentity]

  public init(
    version: Int = MeetingCompressedInventory.currentVersion, id: UUID,
    transcriptGeneration: UUID?, segments: [MeetingCompressedSegment],
    cleanedProofs: [String: MeetingAudioFileIdentity]
  ) {
    self.version = version
    self.id = id
    self.transcriptGeneration = transcriptGeneration
    self.segments = segments
    self.cleanedProofs = cleanedProofs
  }
}

/// #3147 PR4B: one logical segment's identity: its track, copy and recorder index.
public struct MeetingAudioSegmentKey: Hashable, Sendable, Codable {
  public let track: MeetingTrackKind
  public let variant: MeetingSegmentVariant
  public let index: Int

  public init(track: MeetingTrackKind, variant: MeetingSegmentVariant, index: Int) {
    self.track = track
    self.variant = variant
    self.index = index
  }
}

/// #3147 PR4B: one logical segment a reader asks for, as the recorder described it.
public struct MeetingLogicalSegment: Equatable, Sendable {
  public let track: MeetingTrackKind
  public let variant: MeetingSegmentVariant
  public let segment: MeetingSegmentInfo

  public init(track: MeetingTrackKind, variant: MeetingSegmentVariant, segment: MeetingSegmentInfo)
  {
    self.track = track
    self.variant = variant
    self.segment = segment
  }

  public var key: MeetingAudioSegmentKey {
    MeetingAudioSegmentKey(track: track, variant: variant, index: segment.index)
  }
}

/// #3147 PR4B: the one physical file a reader opens for a logical segment. `logical` keeps the
/// recorder's start and frame count; `fileName` and `encoding` say which file holds it now.
public struct MeetingSelectedSegment: Equatable, Sendable {
  public let key: MeetingAudioSegmentKey
  public let logical: MeetingSegmentInfo
  public let fileName: String
  public let encoding: MeetingAudioEncoding
}

/// #3147 PR4B: the single reader-authority selector. Playback, recovery, retranscription and
/// every other READER choose files through it; physical accounting (bytes, deletion) enumerates
/// the folder instead and never uses it.
///
/// With no committed inventory, every logical segment is its own CAF file (legacy behavior).
/// With one, the inventory must cover every asked segment exactly once and name its exact source
/// descriptor; anything else is refused, never mixed.
public enum MeetingAudioSelection {
  public enum Refusal: Error, Equatable, Sendable {
    /// The same logical segment was asked for twice.
    case duplicateLogical(MeetingAudioSegmentKey)
    /// The inventory is from a version this build cannot read.
    case unsupportedInventoryVersion(Int)
    /// The inventory names the same logical segment twice.
    case duplicateInInventory(MeetingAudioSegmentKey)
    /// The inventory's source for a segment differs from the recorder's descriptor.
    case conflictingSource(MeetingAudioSegmentKey)
    /// The inventory names a segment the reader did not ask for, or misses one it did.
    case incompleteInventory
  }

  public static func select(
    logical: [MeetingLogicalSegment], inventory: MeetingCompressedInventory?
  ) throws(Refusal) -> [MeetingSelectedSegment] {
    var asked: [MeetingAudioSegmentKey: MeetingSegmentInfo] = [:]
    for item in logical {
      guard asked.updateValue(item.segment, forKey: item.key) == nil else {
        throw .duplicateLogical(item.key)
      }
    }
    guard let inventory else {
      return logical.map {
        MeetingSelectedSegment(
          key: $0.key, logical: $0.segment, fileName: $0.segment.fileName, encoding: .pcmCAF)
      }
    }
    guard inventory.version == MeetingCompressedInventory.currentVersion else {
      throw .unsupportedInventoryVersion(inventory.version)
    }
    var byKey: [MeetingAudioSegmentKey: MeetingCompressedSegment] = [:]
    for segment in inventory.segments {
      guard byKey.updateValue(segment, forKey: segment.key) == nil else {
        throw .duplicateInInventory(segment.key)
      }
    }
    guard Set(byKey.keys) == Set(asked.keys) else { throw .incompleteInventory }
    return try logical.map { item throws(Refusal) in
      guard let mapped = byKey[item.key], mapped.source == item.segment else {
        throw .conflictingSource(item.key)
      }
      return MeetingSelectedSegment(
        key: item.key, logical: item.segment, fileName: mapped.compressed.fileName,
        encoding: .aacM4A)
    }
  }
}
