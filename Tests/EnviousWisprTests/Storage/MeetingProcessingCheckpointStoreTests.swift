import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprStorage
import EnviousWisprAppKitTestSupport

/// #3972 C3b: when these fail, a meeting transcription that was interrupted starts over, or
/// resumes from a damaged or foreign record and produces wrong or doubled words.
@Suite("MeetingProcessingCheckpointStore", .tags(.productOutcome))
struct MeetingProcessingCheckpointStoreTests {
  private func meetingFolder() throws -> URL {
    let url = TestTemporaryDirectory.url
      .appendingPathComponent("CheckpointStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func checkpoint(pieces: Int = 2) -> MeetingProcessingCheckpoint {
    let key = MeetingProcessingCheckpoint.Key(
      meetingID: UUID(), attemptID: UUID(), processingVersion: 3, pieceTargetSeconds: 60,
      pieceSearchSeconds: 15, seamPaddingSeconds: 1, cutsPieces: true, transcriptLanguage: nil,
      engine: .init(requested: .parakeet, resolved: .parakeet, modelIdentity: "ultra:rev"),
      inputs: [
        .init(
          track: .microphone,
          segments: [.init(fileName: "mic-00001-s000000000.caf", startSample: 0, frameCount: 960_000, byteSize: 1_920_100, sha256: "ab12")])
      ])
    var progress = MeetingProcessingCheckpoint.TrackProgress()
    for i in 0..<pieces {
      progress.pieces.append(
        .init(
          startSample: i * 16_000, endSample: (i + 1) * 16_000, forcedCut: false, text: "héllo 👋",
          words: [.init(word: "héllo", lower: 0, upper: 5, startMs: i * 1_000, endMs: i * 1_000 + 400)]))
    }
    progress.speakers = .init(
      outcome: .labeled, segments: [.init(speakerId: "1", startMs: 0, endMs: 900, quality: 0.8)])
    return MeetingProcessingCheckpoint(key: key, tracks: [.microphone: progress])
  }

  private func mode(_ url: URL) throws -> Int {
    (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?
      .intValue ?? -1
  }

  @Test("a saved checkpoint loads back exactly, private, under the meeting's work folder")
  func roundTripIsPrivate() throws {
    let folder = try meetingFolder()
    let store = MeetingProcessingCheckpointStore(meetingFolder: folder)
    #expect(store.load() == .none)
    let saved = checkpoint()
    try store.save(saved)
    #expect(store.load() == .checkpoint(saved))
    #expect(store.fileURL.path.hasPrefix(folder.appendingPathComponent("work").path))
    #expect(try mode(store.directory) == 0o700)
    #expect(try mode(store.fileURL) == 0o600)
    try store.clear()
    #expect(store.load() == .none)
    try store.clear()
  }

  @Test("a damaged or newer-format checkpoint is reported unusable, never trusted")
  func damagedIsUnusable() throws {
    let store = MeetingProcessingCheckpointStore(meetingFolder: try meetingFolder())
    try store.save(checkpoint())
    let full = try Data(contentsOf: store.fileURL)
    try full.prefix(full.count / 2).write(to: store.fileURL)
    #expect(store.load() == .unusable)
    var newer = checkpoint()
    newer.formatVersion = 99
    try JSONEncoder().encode(newer).write(to: store.fileURL)
    #expect(store.load() == .unusable)
  }

  @Test("a save that cannot be written keeps the previous checkpoint intact")
  func failedSaveKeepsPrevious() throws {
    let store = MeetingProcessingCheckpointStore(meetingFolder: try meetingFolder())
    let first = checkpoint(pieces: 1)
    try store.save(first)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: store.directory.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.directory.path) }
    #expect(throws: (any Error).self) { try store.save(checkpoint(pieces: 3)) }
    #expect(store.load() == .checkpoint(first))
  }

  /// #3973 C2: a checkpoint from before attempts (format 1 or 2) never resumes a pass here: its
  /// pieces carry no attempt or engine, so this build redoes them from the kept audio.
  @Test("a checkpoint written before attempts is not reused", arguments: [1, 2])
  func checkpointFromBeforeAttemptsIsUnusable(format: Int) throws {
    let store = MeetingProcessingCheckpointStore(meetingFolder: try meetingFolder())
    let legacy = """
      {"formatVersion":\(format),"key":{"meetingID":"6F9619FF-8B86-D011-B42D-00C04FC964FF",\
      "processingVersion":\(format),"pieceTargetSeconds":60,"pieceSearchSeconds":15,\
      "seamPaddingSeconds":1,"cutsPieces":false,"inputs":[{"track":"microphone","segments":[\
      {"fileName":"mic-00001-s000000000.caf","startSample":0,"frameCount":960000,\
      "byteSize":1920100,"sha256":"ab12"}]}]},"engineIdentity":"ultra:rev",\
      "tracks":{"microphone":{"pieces":[{"startSample":0,"endSample":16000,"forcedCut":false,\
      "text":"hello","words":[{"word":"hello","lower":0,"upper":5,"startMs":0,"endMs":400}]}]}}}
      """
    try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
    try Data(legacy.utf8).write(to: store.fileURL)
    #expect(store.load() == .unusable)
  }

  /// #3973 C2 (plan G3): the attempt and the engine are part of the key. #3973 C3: a checkpoint
  /// written by this build is format 4 (segment-timed pieces), which a build reading only format
  /// 3 rejects and redoes: there a text-only piece would not mean what it means here.
  @Test("#3973 C3: a Whisper piece (text, no words, segments) round-trips as a success; a failed one has no text")
  func segmentPieceRoundTrips() throws {
    let store = MeetingProcessingCheckpointStore(meetingFolder: try meetingFolder())
    var saved = checkpoint(pieces: 0)
    saved.tracks[.microphone]?.pieces = [
      .init(
        startSample: 0, endSample: 16_000, forcedCut: false, text: "Hello there. Bye.", words: [],
        segments: [
          .init(lower: 0, upper: 12, startMs: 0, endMs: 600),
          .init(lower: 13, upper: 17, startMs: 700, endMs: nil),
        ]),
      .init(startSample: 16_000, endSample: 32_000, forcedCut: false, text: nil, words: nil),
    ]
    try store.save(saved)
    guard case .checkpoint(let loaded) = store.load() else {
      Issue.record("the checkpoint did not load")
      return
    }
    #expect(loaded == saved)
    let pieces = try #require(loaded.tracks[.microphone]?.pieces)
    #expect(pieces.map(\.isFailed) == [false, true])
  }

  @Test("a checkpoint is format 4: a format 3 reader rejects it, this build resumes it")
  func checkpointIsFormatFour() throws {
    let store = MeetingProcessingCheckpointStore(meetingFolder: try meetingFolder())
    let saved = checkpoint()
    try store.save(saved)
    let json = try #require(String(data: try Data(contentsOf: store.fileURL), encoding: .utf8))
    #expect(json.contains(#""formatVersion":4"#))
    #expect(json.contains(#""attemptID":""#))
    #expect(json.contains(#""modelIdentity":"ultra:rev""#))
    #expect(!json.contains("engineIdentity"), "one identity, in the key")
    #expect(store.load(acceptingFormatVersion: 3) == .unusable)
    #expect(store.load() == .checkpoint(saved))
  }

  /// #4105, #3973 C2: a key matches only the same language, attempt, engine and model.
  @Test("another language, attempt, engine or model never matches the key")
  func keyCoversLanguageAttemptAndModel() {
    let base = checkpoint().key
    func key(
      language: String? = nil, attemptID: UUID? = nil, model: String? = "ultra:rev"
    ) -> MeetingProcessingCheckpoint.Key {
      .init(
        meetingID: base.meetingID, attemptID: attemptID ?? base.attemptID,
        processingVersion: base.processingVersion, pieceTargetSeconds: base.pieceTargetSeconds,
        pieceSearchSeconds: base.pieceSearchSeconds, seamPaddingSeconds: base.seamPaddingSeconds,
        cutsPieces: base.cutsPieces, transcriptLanguage: language,
        engine: .init(requested: .parakeet, resolved: .parakeet, modelIdentity: model),
        inputs: base.inputs)
    }
    #expect(key() == base)
    #expect(key(language: "de") != base)
    #expect(key(attemptID: UUID()) != base)
    #expect(key(model: "ultra:r2") != base)
    #expect(key(model: nil) != base)
  }

  @Test("Auto has one spelling in the key: absent, nil and empty all compare equal")
  func autoKeysCompareEqual() throws {
    let base = checkpoint().key
    func key(_ language: String?) -> MeetingProcessingCheckpoint.Key {
      .init(
        meetingID: base.meetingID, attemptID: base.attemptID,
        processingVersion: base.processingVersion, pieceTargetSeconds: base.pieceTargetSeconds,
        pieceSearchSeconds: base.pieceSearchSeconds, seamPaddingSeconds: base.seamPaddingSeconds,
        cutsPieces: base.cutsPieces, transcriptLanguage: language, engine: base.engine,
        inputs: base.inputs)
    }
    #expect(key(nil) == key(""))
    #expect(key(nil) == base)
    let withEmpty = try JSONSerialization.jsonObject(
      with: try JSONEncoder().encode(key("de"))) as? [String: Any]
    var edited = try #require(withEmpty)
    edited["transcriptLanguage"] = ""
    let decoded = try JSONDecoder().decode(
      MeetingProcessingCheckpoint.Key.self, from: try JSONSerialization.data(withJSONObject: edited))
    #expect(decoded == key(nil), "an empty stored language reads as Auto")
  }

  @Test("#4254: a piece saved before provenance existed decodes as unknown and is not reusable")
  func legacyPieceProvenanceIsUnknown() throws {
    let json = Data(
      #"{"startSample":0,"endSample":16000,"forcedCut":false,"text":"Hi","words":[],"segments":[]}"#
        .utf8)
    let piece = try JSONDecoder().decode(MeetingProcessingCheckpoint.Piece.self, from: json)
    #expect(piece.speechPreparation == nil)
    #expect(piece.isReusable == false, "missing provenance is never evidence detection ran")
    let failed = try JSONDecoder().decode(
      MeetingProcessingCheckpoint.Piece.self,
      from: Data(#"{"startSample":0,"endSample":16000,"forcedCut":false}"#.utf8))
    #expect(failed.isReusable, "a failed piece keeps its truthful gap")
    let silent = MeetingProcessingCheckpoint.Piece(
      startSample: 0, endSample: 16_000, forcedCut: false, text: "", words: [], segments: [],
      speechPreparation: .confirmedSilence)
    let back = try JSONDecoder().decode(
      MeetingProcessingCheckpoint.Piece.self, from: JSONEncoder().encode(silent))
    #expect(back == silent)
    #expect(back.isReusable)
    #expect(back.isFailed == false)
  }
}
