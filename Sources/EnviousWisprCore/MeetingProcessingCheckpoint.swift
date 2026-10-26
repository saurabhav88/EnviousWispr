import Foundation

/// What a meeting pass has already finished, so a crash, quit or relaunch resumes it rather
/// than starting over (#3972 C3b). Written only after each piece or speaker analysis has
/// physically finished; never for work merely scheduled.
///
/// A checkpoint is reused only when its `key` matches the pass exactly: the same meeting, the
/// same audio (each segment's name, start, frame count, byte size and content hash, not paths
/// alone), the same
/// processing settings and version, and the same transcript language. Pieces are also tied to
/// the speech model that produced them; a different model discards them.
public struct MeetingProcessingCheckpoint: Codable, Equatable, Sendable {
  /// 2 adds `Key.transcriptLanguage` (#4105). A build that reads only format 1 rejects a
  /// format 2 file and redoes the pass, so a rollback never reuses words decoded in a language
  /// it cannot see in the key.
  public static let currentFormatVersion = 2

  public struct Key: Codable, Equatable, Sendable {
    public let meetingID: UUID
    public let processingVersion: Int
    public let pieceTargetSeconds: Double
    public let pieceSearchSeconds: Double
    public let seamPaddingSeconds: Double
    /// #4052: false when each contiguous run was decoded whole. A key written before this field
    /// existed decodes as `true` (it came from cut pieces), so it never matches a whole-run pass.
    public let cutsPieces: Bool
    /// #4105: the language code the pass decodes with; nil is Auto. Words decoded in another
    /// language never resume this pass. Absent in older keys, which were all Auto.
    public let transcriptLanguage: String?
    public let inputs: [TrackInventory]

    public init(
      meetingID: UUID, processingVersion: Int, pieceTargetSeconds: Double,
      pieceSearchSeconds: Double, seamPaddingSeconds: Double, cutsPieces: Bool,
      transcriptLanguage: String?, inputs: [TrackInventory]
    ) {
      self.meetingID = meetingID
      self.processingVersion = processingVersion
      self.pieceTargetSeconds = pieceTargetSeconds
      self.pieceSearchSeconds = pieceSearchSeconds
      self.seamPaddingSeconds = seamPaddingSeconds
      self.cutsPieces = cutsPieces
      // One spelling of Auto, so an Auto key always equals another Auto key.
      self.transcriptLanguage = transcriptLanguage?.isEmpty == false ? transcriptLanguage : nil
      self.inputs = inputs
    }

    private enum CodingKeys: String, CodingKey {
      case meetingID, processingVersion, pieceTargetSeconds, pieceSearchSeconds
      case seamPaddingSeconds, cutsPieces, transcriptLanguage, inputs
    }

    public init(from decoder: any Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      meetingID = try c.decode(UUID.self, forKey: .meetingID)
      processingVersion = try c.decode(Int.self, forKey: .processingVersion)
      pieceTargetSeconds = try c.decode(Double.self, forKey: .pieceTargetSeconds)
      pieceSearchSeconds = try c.decode(Double.self, forKey: .pieceSearchSeconds)
      seamPaddingSeconds = try c.decode(Double.self, forKey: .seamPaddingSeconds)
      // Absent in keys written before #4052, which always cut pieces.
      cutsPieces = try c.decodeIfPresent(Bool.self, forKey: .cutsPieces) ?? true
      // Absent in keys written before #4105, which were all Auto.
      let language = try c.decodeIfPresent(String.self, forKey: .transcriptLanguage)
      transcriptLanguage = language?.isEmpty == false ? language : nil
      inputs = try c.decode([TrackInventory].self, forKey: .inputs)
    }
  }

  public struct TrackInventory: Codable, Equatable, Sendable {
    public let track: MeetingTrackKind
    public let segments: [SegmentIdentity]

    public init(track: MeetingTrackKind, segments: [SegmentIdentity]) {
      self.track = track
      self.segments = segments
    }
  }

  public struct SegmentIdentity: Codable, Equatable, Sendable {
    public let fileName: String
    public let startSample: Int
    public let frameCount: Int
    public let byteSize: Int64
    /// SHA-256 of the file's bytes, hex: different samples of the same length differ here.
    public let sha256: String

    public init(fileName: String, startSample: Int, frameCount: Int, byteSize: Int64, sha256: String) {
      self.fileName = fileName
      self.startSample = startSample
      self.frameCount = frameCount
      self.byteSize = byteSize
      self.sha256 = sha256
    }
  }

  /// One finished piece: its own range on the track timeline and the words it owns. `words`
  /// nil means the piece failed twice (a truthful gap, not silence).
  public struct Piece: Codable, Equatable, Sendable {
    public let startSample: Int
    public let endSample: Int
    public let forcedCut: Bool
    public let text: String?
    public let words: [Word]?

    public init(
      startSample: Int, endSample: Int, forcedCut: Bool, text: String?, words: [Word]?
    ) {
      self.startSample = startSample
      self.endSample = endSample
      self.forcedCut = forcedCut
      self.text = text
      self.words = words
    }
  }

  public struct Word: Codable, Equatable, Sendable {
    public let word: String
    public let lower: Int
    public let upper: Int
    public let startMs: Int?
    public let endMs: Int?

    public init(word: String, lower: Int, upper: Int, startMs: Int?, endMs: Int?) {
      self.word = word
      self.lower = lower
      self.upper = upper
      self.startMs = startMs
      self.endMs = endMs
    }
  }

  public struct Speakers: Codable, Equatable, Sendable {
    public let outcome: MeetingSpeakerOutcome
    public let segments: [Segment]

    public init(outcome: MeetingSpeakerOutcome, segments: [Segment]) {
      self.outcome = outcome
      self.segments = segments
    }
  }

  public struct Segment: Codable, Equatable, Sendable {
    public let speakerId: String
    public let startMs: Int
    public let endMs: Int
    public let quality: Float

    public init(speakerId: String, startMs: Int, endMs: Int, quality: Float) {
      self.speakerId = speakerId
      self.startMs = startMs
      self.endMs = endMs
      self.quality = quality
    }
  }

  public struct TrackProgress: Codable, Equatable, Sendable {
    /// In timeline order; each starts where the previous one ended or at a run start.
    public var pieces: [Piece]
    public var speakers: Speakers?

    public init(pieces: [Piece] = [], speakers: Speakers? = nil) {
      self.pieces = pieces
      self.speakers = speakers
    }
  }

  public var formatVersion: Int
  public let key: Key
  /// The speech model the pieces came from (model and revision); nil before the first piece.
  public var engineIdentity: String?
  public var tracks: [MeetingTrackKind: TrackProgress]

  public init(
    key: Key, engineIdentity: String? = nil, tracks: [MeetingTrackKind: TrackProgress] = [:]
  ) {
    self.formatVersion = Self.currentFormatVersion
    self.key = key
    self.engineIdentity = engineIdentity
    self.tracks = tracks
  }
}
