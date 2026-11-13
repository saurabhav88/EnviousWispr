import Foundation

/// One of the two tracks an EnviousMeet recording writes (#3972 §3.1).
///
/// The microphone is what the user's input device hears; the call sound is what the Mac
/// plays, captured digitally through a Core Audio process tap, so headphones of any kind do
/// not change it (founder F2).
public enum MeetingTrackKind: String, Sendable, Equatable, Codable, CaseIterable,
  CodingKeyRepresentable
{
  case microphone
  case callSound

  /// The file-name stem of this track's segment files: `mic-00001-s000000000.caf`.
  public var fileStem: String {
    switch self {
    case .microphone: "mic"
    case .callSound: "system"
    }
  }

  /// The prefix of this track's speaker ids, so two tracks' diarizer ids can never collide
  /// (#3972 §3.6): `mic:S1`, `sys:S2`.
  public var speakerPrefix: String {
    switch self {
    case .microphone: "mic"
    case .callSound: "sys"
    }
  }
}

/// The physical copy a microphone segment file holds (#4355 PR B). One logical microphone
/// track can have two copies on disk: the audio as captured (`raw`, what playback and every
/// existing reader use) and the echo-cleaned copy (`cleaned`, `micclean-…`), written in the same
/// segments at the same timeline positions. The call sound only ever has `raw`.
public enum MeetingSegmentVariant: String, Sendable, Equatable, Hashable, Codable {
  case raw
  case cleaned
}

/// The echo cleaner a recording's cleaned microphone copy was made with, recorded at Start
/// (#4355 PR B). A cleaned copy is used only with the provenance it was recorded under; a later
/// build never invents it from the library it happens to ship.
public struct MeetingEchoProvenance: Sendable, Equatable, Hashable, Codable {
  /// `ew_aec_version()` of the library that ran, for example
  /// "webrtc-audio-processing 2.1 846fe90 ew-4355.3".
  public let library: String
  /// The fixed configuration it ran with (sample rate, frame size, which stages were on).
  public let configuration: String

  public init(library: String, configuration: String) {
    self.library = library
    self.configuration = configuration
  }
}

/// What one writer's cleaned copy finished (#4355 PR B): every twin it finalized, as written.
public struct MeetingCleanedProof: Sendable, Equatable, Codable {
  public let segments: [MeetingSegmentInfo]

  public init(segments: [MeetingSegmentInfo]) {
    self.segments = segments
  }
}

/// Which microphone copy a final transcript attempt read (#4355 PR B), frozen once per attempt,
/// with the recording-time echo provenance either way: a raw attempt of a recording that had a
/// cleaned copy is still identified by the cleaner that recorded it (nil when it had none).
public enum MeetingMicrophoneCopy: Sendable, Equatable, Hashable, Codable {
  case raw(MeetingEchoProvenance?)
  case cleaned(MeetingEchoProvenance)
}

/// One finished segment file of one track (#3972 R3).
///
/// `startMs` is measured from the meeting's anchor. On the call-sound track it comes from the
/// tap's acquisition clock; on the microphone track it is APPROXIMATE (arrival time plus sample
/// count, #3972 R27), so it places gaps on the timeline but makes no accuracy promise.
public struct MeetingSegmentInfo: Sendable, Equatable, Codable {
  public let index: Int
  public let fileName: String
  public let startMs: Int
  /// Frames at `MeetingAudioFormat.sampleRate`.
  public let frameCount: Int

  public init(index: Int, fileName: String, startMs: Int, frameCount: Int) {
    self.index = index
    self.fileName = fileName
    self.startMs = startMs
    self.frameCount = frameCount
  }

  public var durationMs: Int {
    Int((Double(frameCount) * 1000 / MeetingAudioFormat.sampleRate).rounded())
  }
  public var endMs: Int { startMs + durationMs }
}

/// The format every meeting segment file is written in: 16 kHz mono 16-bit PCM in CAF, the
/// rate every shipped engine consumes, 115 MB per track-hour.
public enum MeetingAudioFormat {
  public static let sampleRate: Double = 16_000
  public static let segmentSeconds: Double = 60
  public static let fileExtension = "caf"
  /// A segment still being written. Renamed to `fileExtension` once finalized (#3972 R3).
  public static let partialExtension = "caf.partial"
}

/// Why one track has no audio, when it has none (#3972 §8: absent is distinct from silent).
public enum MeetingTrackStatus: String, Sendable, Equatable, Codable {
  /// Captured; segment files exist (they may still contain silence).
  case captured
  /// The user turned call sound off for this meeting.
  case off
  /// macOS refused the call-sound permission.
  case denied
  /// This Mac cannot capture the call sound (macOS earlier than 14.2).
  case unsupported
  /// Capture started but could not continue.
  case failed
}

/// The lifecycle of one meeting (#3972 §5, R3).
public enum MeetingState: String, Sendable, Equatable, Codable {
  case recording
  case stopping
  /// Recording ended unexpectedly (crash, force quit, quit while recording). The audio written
  /// so far is kept and transcribed.
  case interrupted
  case queued
  case processing
  case ready
  case failed
  /// Nothing was captured on any track, but the user typed notes (#3972 R53, R56): the notes are
  /// kept, and the meeting is never queued for transcription. Written with `formatVersion` 2.
  case notesOnly
}

/// What the speaker analysis of one track really found, kept for the meeting and telemetry
/// because the History row always stores `.labeled` (#3972 R5).
public enum MeetingSpeakerOutcome: String, Sendable, Equatable, Codable {
  case labeled
  case single
  case noSpeech
  case failed
  case timedOut
}

/// The speech engine a meeting's final transcript is written with, independent of the
/// dictation engine (#3973 decision 19). A new case needs a `formatVersion` bump, because an
/// older build cannot decode a value it does not know: Whisper arrived with format 4.
public enum MeetingEngineChoice: String, Sendable, Equatable, Codable, CaseIterable {
  case parakeet
  case whisper
}

/// The persisted description of one EnviousMeet recording: `meeting.json` in its folder.
///
/// Additive Codable: every field added after `formatVersion` 1 must be optional so an older
/// file still decodes; a file from a NEWER format is listed read-only and never rewritten or
/// deleted by this build (#3972 §4).
public struct MeetingRecord: Sendable, Equatable, Codable, Identifiable {
  /// 2 adds `MeetingState.notesOnly` (#3972 R56). 3 adds transcription attempts and the
  /// committed transcript generation (#3973 C2). 4 adds `MeetingEngineChoice.whisper` (#3973
  /// C3). 5 adds the committed compressed audio inventory (#3147 PR4B). A record keeps the
  /// version it was created with until it needs a newer value: `markNotesOnly()`,
  /// `beginAttempt(_:)` and `commitCompressedAudio(_:)` raise it.
  public static let currentFormatVersion = 5
  /// The format that introduced `MeetingState.notesOnly`.
  public static let notesOnlyFormatVersion = 2
  /// The format that introduced attempts (#3973 C2). An older build lists such a meeting
  /// read-only rather than resuming an attempt it cannot see.
  public static let attemptFormatVersion = 3
  /// The format that introduced `MeetingEngineChoice.whisper` (#3973 C3).
  public static let whisperFormatVersion = 4
  /// The format that introduced `compressedAudio` (#3147 PR4B). An older build lists a compacted
  /// meeting read-only rather than reading CAF files that may have been retired.
  public static let compressedAudioFormatVersion = 5
  /// The generation of a transcript committed before attempts existed (#3973 C2): its History
  /// row carries no attempt ID, and its record no committed ID while it is ready.
  public static let legacyTranscriptAttemptID = UUID(
    uuidString: "00000000-0000-0000-0000-000000000001")!

  public private(set) var formatVersion: Int
  public let id: UUID
  /// The History row this meeting's transcript is saved as. Minted at creation so every save
  /// replaces the same row, never a second one (#3972 R3).
  public let transcriptID: UUID
  public var title: String?
  public let createdAt: Date
  public var endedAt: Date?
  public var state: MeetingState
  public var engine: MeetingEngineChoice
  public var trackStatus: [MeetingTrackKind: MeetingTrackStatus]
  public var segments: [MeetingTrackKind: [MeetingSegmentInfo]]
  /// Gaps the recorder knew about, per track, in meeting milliseconds.
  public var gaps: [MeetingTrackKind: [ClosedRange<Int>]]
  public var speakerOutcomes: [MeetingTrackKind: MeetingSpeakerOutcome]
  /// Turn ids on the microphone track that repeat the call sound (#3972 §3.7, R5): hidden by
  /// default, never deleted.
  public var echoTurnIDs: [String]
  /// False once the user deleted the audio. Transcribe again is then unavailable.
  public var audioKept: Bool
  /// Set before a delete starts, so a crash mid-delete is finished at the next launch.
  public var deletionRequested: Bool
  /// Why the last pass failed, as a closed code (never text from the meeting).
  public var failureCode: String?
  /// True once launch recovery found this meeting still recording or stopping (a crash, force
  /// quit or quit while recording). Optional: absent means false.
  public var wasInterrupted: Bool?
  /// The call app this meeting was started for (#4012), by `CallAppFamily` raw value. Optional
  /// and stored as text: absent on hand-started and older meetings, and a value from a newer
  /// build never stops this one from reading the record.
  public var callAppRaw: String?
  /// #4105: the final transcript's language, frozen from `meetingLanguageMode` at Start and
  /// written before the record's first save, so processing, launch recovery and retry all use
  /// the Start value. A language code for a locked language; absent means Auto (also for
  /// meetings recorded before this field). Stored as text, like `callAppRaw`.
  public var transcriptLanguage: String?
  /// #3973 C2: the attempt still to finish (queued, processing, or failed and resumable); nil
  /// once its transcript committed. Never the attempt the shown transcript came from.
  public var pendingAttempt: MeetingAttemptConfiguration?
  /// #3973 C2: what `pendingAttempt` resolved to, once it did.
  public var resolvedAttempt: MeetingResolvedAttempt?
  /// #3973 C2: the committed transcript's attempt, its requested and used engine and why they
  /// differ. Changed only at the ready barrier; a failed or running attempt leaves them.
  public var committedTranscriptAttemptID: UUID?
  public var requestedTranscriptEngine: MeetingEngineChoice?
  public var transcriptEngineUsed: MeetingEngineChoice?
  public var transcriptEngineFallbackReason: MeetingTranscriptFallbackReason?
  /// #4355 PR B: the echo cleaner that wrote this meeting's cleaned microphone copy, set at
  /// Start when cleaning runs. Absent (older meetings, or no cleaning) means the raw copy is the
  /// only one the final pass may use. The cleaned segment files themselves are not listed here:
  /// the folder is their authority, as recovery already is for raw segments.
  public var echoProvenance: MeetingEchoProvenance?
  /// #3147 PR4B: the verified compacted audio readers use, when committed. Absent (older
  /// meetings, or not yet compacted) means every segment is its recorder CAF file. Logical
  /// `segments` and `gaps` never change; `MeetingAudioSelection` picks the physical files.
  public private(set) var compressedAudio: MeetingCompressedInventory?

  /// #3147 PR4B: makes `inventory` the meeting's reader authority, raising the format so an older
  /// build never reads around it. Storage calls this on a freshly read record inside its write.
  public mutating func commitCompressedAudio(_ inventory: MeetingCompressedInventory) {
    compressedAudio = inventory
    formatVersion = max(formatVersion, Self.compressedAudioFormatVersion)
  }

  /// The generation of the committed transcript, or nil when none committed. A ready record
  /// written before attempts existed committed the legacy generation.
  public var committedTranscriptGeneration: UUID? {
    committedTranscriptAttemptID ?? (state == .ready ? Self.legacyTranscriptAttemptID : nil)
  }

  /// Saves a new attempt as the one to run (#3973 C2), raising the format so an older build
  /// never resumes it. A legacy committed generation is pinned first, because the record is
  /// about to leave `.ready`, which is what identified it.
  public mutating func beginAttempt(_ attempt: MeetingAttemptConfiguration) {
    if committedTranscriptAttemptID == nil, state == .ready {
      committedTranscriptAttemptID = Self.legacyTranscriptAttemptID
    }
    pendingAttempt = attempt
    resolvedAttempt = nil
    formatVersion = max(
      formatVersion,
      attempt.requestedEngine == .whisper ? Self.whisperFormatVersion : Self.attemptFormatVersion)
  }

  /// A new attempt from the record's saved Start values (#3973 C2): its Start language on its
  /// Start engine, never current Settings. Start saves it; a record queued before attempts
  /// existed runs it.
  public func attemptFromStartValues(
    supports: (MeetingEngineChoice, String) -> Bool = { _, _ in true }
  ) -> MeetingAttemptConfiguration {
    MeetingAttemptConfiguration(
      requestedEngine: engine, language: transcriptLanguageMode, supports: supports)
  }

  /// Commits `resolved`'s attempt as the shown transcript's generation (#3973 C2), at the
  /// ready barrier only.
  public mutating func commitAttempt(_ resolved: MeetingResolvedAttempt) {
    committedTranscriptAttemptID = resolved.attemptID
    requestedTranscriptEngine = resolved.requestedEngine
    transcriptEngineUsed = resolved.resolvedEngine
    transcriptEngineFallbackReason = resolved.fallbackReason
    pendingAttempt = nil
    resolvedAttempt = nil
  }

  /// `transcriptLanguage` as a mode: Auto when absent or empty.
  public var transcriptLanguageMode: LanguageMode {
    get { transcriptLanguage.flatMap { $0.isEmpty ? nil : LanguageMode.locked($0) } ?? .auto }
    set {
      if case .locked(let code) = newValue, !code.isEmpty {
        transcriptLanguage = code
      } else {
        transcriptLanguage = nil
      }
    }
  }

  /// The call app this meeting was started for, when this build knows it.
  public var callApp: CallAppFamily? {
    get { callAppRaw.flatMap(CallAppFamily.init(rawValue:)) }
    set { callAppRaw = newValue?.rawValue }
  }

  public init(
    id: UUID = UUID(), transcriptID: UUID = UUID(), title: String? = nil,
    createdAt: Date = Date(), engine: MeetingEngineChoice,
    trackStatus: [MeetingTrackKind: MeetingTrackStatus]
  ) {
    self.formatVersion = Self.currentFormatVersion
    self.id = id
    self.transcriptID = transcriptID
    self.title = title
    self.createdAt = createdAt
    self.endedAt = nil
    self.state = .recording
    self.engine = engine
    self.trackStatus = trackStatus
    self.segments = [:]
    self.gaps = [:]
    self.speakerOutcomes = [:]
    self.echoTurnIDs = []
    self.audioKept = true
    self.deletionRequested = false
    self.failureCode = nil
    self.wasInterrupted = nil
    self.callAppRaw = nil
    self.transcriptLanguage = nil
    self.pendingAttempt = nil
    self.resolvedAttempt = nil
    self.committedTranscriptAttemptID = nil
    self.requestedTranscriptEngine = nil
    self.transcriptEngineUsed = nil
    self.transcriptEngineFallbackReason = nil
    self.echoProvenance = nil
    self.compressedAudio = nil
  }

  /// Nothing was captured, the user's notes are kept (#3972 R53, R56). Raises the format so an
  /// older build that cannot decode `notesOnly` lists the meeting as newer, read-only.
  public mutating func markNotesOnly() {
    state = .notesOnly
    formatVersion = max(formatVersion, Self.notesOnlyFormatVersion)
  }

  /// Whether this build may rewrite the file.
  public var isWritableByThisBuild: Bool { formatVersion <= Self.currentFormatVersion }

  /// The few fields every format version keeps, read first so a meeting written by a NEWER
  /// build is still listed (read-only) even when its other fields do not decode here.
  public struct Header: Sendable, Equatable, Codable {
    public let formatVersion: Int
    public let id: UUID
    public let createdAt: Date
  }

  /// Recorded duration: from the anchor to the end of the latest segment on any track.
  public var recordedDurationMs: Int {
    segments.values.compactMap { $0.last?.endMs }.max() ?? 0
  }

  /// The state a meeting found at launch moves to (#3972 R3). Nil means leave it as it is.
  public static func recoveredState(from state: MeetingState) -> MeetingState? {
    switch state {
    case .recording, .stopping: .interrupted
    case .processing: .queued
    case .interrupted, .queued, .ready, .failed, .notesOnly: nil
    }
  }
}

/// File names of meeting segment files (#3972 R3, R15), shared by the writer (Audio) and the
/// store (Storage), which cannot import each other.
///
/// The segment's start on the meeting timeline is IN the name (`mic-00003-s000120000.caf`), and
/// the `.caf.partial` carries it from the moment the file is created, so crash recovery never
/// needs `meeting.json` to place a segment.
public enum MeetingSegmentNaming {
  public struct Parsed: Sendable, Equatable {
    public let track: MeetingTrackKind
    /// `.cleaned` only for `micclean-…` (the microphone's echo-cleaned copy).
    public let variant: MeetingSegmentVariant
    public let index: Int
    public let startMs: Int
    public let partial: Bool
    /// #3147 PR4B: `.aacM4A` for a compacted file, else `.pcmCAF`.
    public let encoding: MeetingAudioEncoding
    /// #3147 PR4B: the inventory attempt a compacted file belongs to; nil for recorder CAF.
    public let inventoryID: UUID?

    public init(
      track: MeetingTrackKind, variant: MeetingSegmentVariant, index: Int, startMs: Int,
      partial: Bool, encoding: MeetingAudioEncoding = .pcmCAF, inventoryID: UUID? = nil
    ) {
      self.track = track
      self.variant = variant
      self.index = index
      self.startMs = startMs
      self.partial = partial
      self.encoding = encoding
      self.inventoryID = inventoryID
    }
  }

  /// #3147 PR4B: compacted files: `mic-00003-s000120000-c<32 hex inventory id>.m4a`, and
  /// `.m4a.partial` while being written. The inventory id is in the name so an abandoned or
  /// retried attempt never overwrites another attempt's output.
  public static let compactedExtension = "m4a"
  public static let compactedPartialExtension = "m4a.partial"

  public static func compactedFileName(
    source: MeetingSegmentInfo, track: MeetingTrackKind, variant: MeetingSegmentVariant,
    inventoryID: UUID, partial: Bool
  ) -> String {
    precondition(
      source.index > 0 && source.startMs >= 0,
      "segment index must be positive and start non-negative")
    precondition(variant == .raw || track == .microphone, "only the microphone has a cleaned copy")
    let ext = partial ? compactedPartialExtension : compactedExtension
    let stem = variant == .cleaned ? cleanedMicrophoneStem : track.fileStem
    let id = inventoryID.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    return "\(stem)-\(padded(source.index, 5))-s\(padded(source.startMs, 9))-c\(id).\(ext)"
  }

  /// The stem of the microphone's echo-cleaned copy (#4355 PR B): `micclean-00003-s000120000.caf`
  /// is the twin of `mic-00003-s000120000.caf`.
  public static let cleanedMicrophoneStem = "micclean"

  /// #4355 PR B: the proof a recording's cleaned copy finished whole, written durably by the
  /// writer only after its last twin did and only if no step of the cleaned copy failed:
  /// `micclean-complete-00001-00003.json` covers twins 1 to 3. The final pass uses a cleaned twin
  /// only when a proof lists it; any failure, crash or missing write leaves no proof, so the
  /// pass reads raw without depending on any cleanup having worked. Not a segment name.
  public static let cleanedProofPrefix = "micclean-complete-"

  public static func cleanedProofName(first: Int, last: Int) -> String {
    "\(cleanedProofPrefix)\(padded(first, 5))-\(padded(last, 5)).json"
  }

  public static func isCleanedProof(_ name: String) -> Bool {
    name.hasPrefix(cleanedProofPrefix) && name.hasSuffix(".json")
  }

  /// One timing policy for names and metadata: callers pass a start that is already
  /// non-negative (the writer clamps a start before the anchor to 0 once, and records the same
  /// value in `MeetingSegmentInfo`). A negative start is a caller defect. Only the microphone
  /// has a `.cleaned` variant.
  public static func fileName(
    track: MeetingTrackKind, variant: MeetingSegmentVariant = .raw, index: Int, startMs: Int,
    partial: Bool
  ) -> String {
    precondition(index > 0 && startMs >= 0, "segment index must be positive and start non-negative")
    precondition(variant == .raw || track == .microphone, "only the microphone has a cleaned copy")
    let ext = partial ? MeetingAudioFormat.partialExtension : MeetingAudioFormat.fileExtension
    let stem = variant == .cleaned ? cleanedMicrophoneStem : track.fileStem
    return "\(stem)-\(padded(index, 5))-s\(padded(startMs, 9)).\(ext)"
  }

  /// Zero-padded decimal of a full `Int` (no 32-bit `%d` narrowing: a start past 2^31 ms, about
  /// 25 days, still names and parses correctly).
  static func padded(_ value: Int, _ width: Int) -> String {
    let digits = String(value)
    return String(repeating: "0", count: max(0, width - digits.count)) + digits
  }

  /// Recorder segment files only (`.caf`, `.caf.partial`), as every existing reader expects.
  /// Compacted names are NOT recognized here, so a reader cannot mistake an uncommitted or
  /// committed `.m4a` for a duplicate segment; callers that must see them use `parseAny`.
  public static func parse(_ name: String) -> Parsed? {
    guard let parsed = parseAny(name), parsed.encoding == .pcmCAF else { return nil }
    return parsed
  }

  /// #3147 PR4B: recorder AND compacted segment files. For physical accounting and deletion
  /// (every owned file), never for choosing what a reader opens (`MeetingAudioSelection`).
  public static func parseAny(_ name: String) -> Parsed? {
    let forms: [(ext: String, partial: Bool, encoding: MeetingAudioEncoding)] = [
      (MeetingAudioFormat.partialExtension, true, .pcmCAF),
      (MeetingAudioFormat.fileExtension, false, .pcmCAF),
      (compactedPartialExtension, true, .aacM4A),
      (compactedExtension, false, .aacM4A),
    ]
    guard let form = forms.first(where: { name.hasSuffix("." + $0.ext) }) else { return nil }
    let partial = form.partial
    let stem = name.dropLast(form.ext.count + 1)
    let parts = stem.split(separator: "-", omittingEmptySubsequences: false)
    let inventoryID: UUID?
    switch form.encoding {
    case .pcmCAF:
      guard parts.count == 3 else { return nil }
      inventoryID = nil
    case .aacM4A:
      guard parts.count == 4, let id = compactedInventoryID(parts[3]) else { return nil }
      inventoryID = id
    }
    guard parts[2].hasPrefix("s") else { return nil }
    let identity: (MeetingTrackKind, MeetingSegmentVariant)
    if parts[0] == cleanedMicrophoneStem {
      identity = (.microphone, .cleaned)
    } else if let track = MeetingTrackKind.allCases.first(where: { $0.fileStem == parts[0] }) {
      identity = (track, .raw)
    } else {
      return nil
    }
    guard let index = Int(parts[1]), index > 0,
      let start = Int(parts[2].dropFirst()), start >= 0
    else { return nil }
    return Parsed(
      track: identity.0, variant: identity.1, index: index, startMs: start, partial: partial,
      encoding: form.encoding, inventoryID: inventoryID)
  }

  /// `c` + 32 lowercase hex digits, back to the inventory id.
  private static func compactedInventoryID(_ part: Substring) -> UUID? {
    guard part.count == 33, part.first == "c" else { return nil }
    let hex = Array(part.dropFirst())
    guard hex.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else {
      return nil
    }
    let s = String(hex)
    func cut(_ from: Int, _ to: Int) -> Substring {
      s[s.index(s.startIndex, offsetBy: from)..<s.index(s.startIndex, offsetBy: to)]
    }
    return UUID(
      uuidString: "\(cut(0, 8))-\(cut(8, 12))-\(cut(12, 16))-\(cut(16, 20))-\(cut(20, 32))")
  }
}
