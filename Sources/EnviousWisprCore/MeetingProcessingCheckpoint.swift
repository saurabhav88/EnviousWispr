import Foundation

/// What a meeting pass has already finished, so a crash, quit or relaunch resumes it rather
/// than starting over (#3972 C3b). Written only after each piece or speaker analysis has
/// physically finished; never for work merely scheduled.
///
/// A checkpoint is reused only when its `key` matches the pass exactly: the same meeting, the
/// same audio (each segment's name, start, frame count, byte size and content hash, not paths
/// alone), the same
/// processing settings and version, the same transcript language, the same attempt and the same
/// engine and model (#3973 C2). Work from another attempt, engine or model is never reused.
public struct MeetingProcessingCheckpoint: Codable, Equatable, Sendable {
  /// 2 adds `Key.transcriptLanguage` (#4105). 3 adds `Key.attemptID` and `Key.engine`, which
  /// replace the separate engine identity (#3973 C2). 4 adds `Piece.segments`, so a piece with
  /// text and no words is a success timed by segment, not a failure (#3973 C3). A build that
  /// reads another format rejects the file and redoes the pass, so a rollback never reuses
  /// words it cannot see the source of.
  public static let currentFormatVersion = 4

  /// The engine and model an attempt's pieces come from (#3973 C2).
  public struct Engine: Codable, Equatable, Sendable {
    public let requested: MeetingEngineChoice
    public let resolved: MeetingEngineChoice
    /// The loaded model and revision; nil when the engine reports none.
    public let modelIdentity: String?

    public init(requested: MeetingEngineChoice, resolved: MeetingEngineChoice, modelIdentity: String?) {
      self.requested = requested
      self.resolved = resolved
      self.modelIdentity = modelIdentity
    }
  }

  public struct Key: Codable, Equatable, Sendable {
    public let meetingID: UUID
    /// #3973 C2: a new Transcribe again starts over; a continued attempt resumes.
    public let attemptID: UUID
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
    /// #3973 C2: the resolved engine and model, known before any reuse.
    public let engine: Engine
    public let inputs: [TrackInventory]

    public init(
      meetingID: UUID, attemptID: UUID, processingVersion: Int, pieceTargetSeconds: Double,
      pieceSearchSeconds: Double, seamPaddingSeconds: Double, cutsPieces: Bool,
      transcriptLanguage: String?, engine: Engine, inputs: [TrackInventory]
    ) {
      self.meetingID = meetingID
      self.attemptID = attemptID
      self.processingVersion = processingVersion
      self.pieceTargetSeconds = pieceTargetSeconds
      self.pieceSearchSeconds = pieceSearchSeconds
      self.seamPaddingSeconds = seamPaddingSeconds
      self.cutsPieces = cutsPieces
      // One spelling of Auto, so an Auto key always equals another Auto key.
      self.transcriptLanguage = transcriptLanguage?.isEmpty == false ? transcriptLanguage : nil
      self.engine = engine
      self.inputs = inputs
    }

    private enum CodingKeys: String, CodingKey {
      case meetingID, attemptID, processingVersion, pieceTargetSeconds, pieceSearchSeconds
      case seamPaddingSeconds, cutsPieces, transcriptLanguage, engine, inputs
    }

    public init(from decoder: any Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      meetingID = try c.decode(UUID.self, forKey: .meetingID)
      attemptID = try c.decode(UUID.self, forKey: .attemptID)
      processingVersion = try c.decode(Int.self, forKey: .processingVersion)
      pieceTargetSeconds = try c.decode(Double.self, forKey: .pieceTargetSeconds)
      pieceSearchSeconds = try c.decode(Double.self, forKey: .pieceSearchSeconds)
      seamPaddingSeconds = try c.decode(Double.self, forKey: .seamPaddingSeconds)
      // Absent in keys written before #4052, which always cut pieces.
      cutsPieces = try c.decodeIfPresent(Bool.self, forKey: .cutsPieces) ?? true
      // Absent in keys written before #4105, which were all Auto.
      let language = try c.decodeIfPresent(String.self, forKey: .transcriptLanguage)
      transcriptLanguage = language?.isEmpty == false ? language : nil
      engine = try c.decode(Engine.self, forKey: .engine)
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

  /// One finished piece: its own range on the track timeline and the words it owns. A piece
  /// with no `text` failed twice (a truthful gap, not silence); a decoded piece has text and a
  /// word list, which is empty for an engine timed by segment (#3973 C3).
  public struct Piece: Codable, Equatable, Sendable {
    public let startSample: Int
    public let endSample: Int
    public let forcedCut: Bool
    public let text: String?
    public let words: [Word]?
    /// #3973 C3: the engine's segment timings (Whisper), ranges into `text`, times on the
    /// meeting timeline. Nil for a word-timed engine and for a failed piece.
    public let segments: [SegmentTiming]?

    public init(
      startSample: Int, endSample: Int, forcedCut: Bool, text: String?, words: [Word]?,
      segments: [SegmentTiming]? = nil
    ) {
      self.startSample = startSample
      self.endSample = endSample
      self.forcedCut = forcedCut
      self.text = text
      self.words = words
      self.segments = segments
    }

    /// The one failure test: the piece failed twice and carries no text.
    public var isFailed: Bool { text == nil }
  }

  /// #3973 C3: one engine segment of a piece's text.
  public struct SegmentTiming: Codable, Equatable, Sendable {
    public let lower: Int
    public let upper: Int
    public let startMs: Int?
    public let endMs: Int?

    public init(lower: Int, upper: Int, startMs: Int?, endMs: Int?) {
      self.lower = lower
      self.upper = upper
      self.startMs = startMs
      self.endMs = endMs
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
  public var tracks: [MeetingTrackKind: TrackProgress]

  public init(key: Key, tracks: [MeetingTrackKind: TrackProgress] = [:]) {
    self.formatVersion = Self.currentFormatVersion
    self.key = key
    self.tracks = tracks
  }
}
