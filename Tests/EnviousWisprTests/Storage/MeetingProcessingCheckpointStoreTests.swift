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
      meetingID: UUID(), processingVersion: 1, pieceTargetSeconds: 60, pieceSearchSeconds: 15,
      seamPaddingSeconds: 1, cutsPieces: true, transcriptLanguage: nil,
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
    return MeetingProcessingCheckpoint(key: key, engineIdentity: "ultra:rev", tracks: [.microphone: progress])
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

  /// #4052: a checkpoint written before `cutsPieces` existed (version-1 job, 60 s pieces) still
  /// loads, reads as cut pieces, and so can never match a whole-run pass's key.
  @Test("a checkpoint key written before whole-run mode loads and reads as cut pieces")
  func legacyKeyLoadsAsCutPieces() throws {
    let folder = try meetingFolder()
    let store = MeetingProcessingCheckpointStore(meetingFolder: folder)
    let legacy = """
      {"formatVersion":1,"key":{"meetingID":"6F9619FF-8B86-D011-B42D-00C04FC964FF",\
      "processingVersion":1,"pieceTargetSeconds":60,"pieceSearchSeconds":15,\
      "seamPaddingSeconds":1,"inputs":[{"track":"microphone","segments":[\
      {"fileName":"mic-00001-s000000000.caf","startSample":0,"frameCount":960000,\
      "byteSize":1920100,"sha256":"ab12"}]}]},"engineIdentity":"ultra:rev",\
      "tracks":{"microphone":{"pieces":[{"startSample":0,"endSample":16000,"forcedCut":false,\
      "text":"hello","words":[{"word":"hello","lower":0,"upper":5,"startMs":0,"endMs":400}]}]}}}
      """
    try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
    try Data(legacy.utf8).write(to: store.fileURL)
    // #4105: this build writes format 2, so it redoes a format 1 pass; the format 1 reader still
    // decodes the old key's missing fields as before.
    #expect(store.load() == .unusable)
    guard case .checkpoint(let loaded) = store.load(acceptingFormatVersion: 1) else {
      Issue.record("a legacy checkpoint did not load")
      return
    }
    #expect(loaded.key.transcriptLanguage == nil, "an old key reads as Auto")
    #expect(loaded.key.cutsPieces == true)
    #expect(loaded.key.processingVersion == 1)
    #expect(loaded.tracks[.microphone]?.pieces.count == 1)
    var wholeRun = MeetingProcessingCheckpoint.Key(
      meetingID: loaded.key.meetingID, processingVersion: 2, pieceTargetSeconds: 60,
      pieceSearchSeconds: 15, seamPaddingSeconds: 1, cutsPieces: false, transcriptLanguage: nil,
      inputs: loaded.key.inputs)
    #expect(loaded.key != wholeRun)
    // Version alone also differs; with the version equal, the mode still keeps them apart.
    wholeRun = MeetingProcessingCheckpoint.Key(
      meetingID: loaded.key.meetingID, processingVersion: 1, pieceTargetSeconds: 60,
      pieceSearchSeconds: 15, seamPaddingSeconds: 1, cutsPieces: false, transcriptLanguage: nil,
      inputs: loaded.key.inputs)
    #expect(loaded.key != wholeRun)
  }

  /// #4105 (plan R2.1): the transcript language is part of the key, and a checkpoint written by
  /// this build is format 2, which a build reading only format 1 rejects and redoes.
  @Test("a locked-language checkpoint is format 2: a format 1 reader rejects it, this build resumes it")
  func lockedLanguageCheckpointIsFormatTwo() throws {
    let store = MeetingProcessingCheckpointStore(meetingFolder: try meetingFolder())
    let base = checkpoint().key
    let german = MeetingProcessingCheckpoint.Key(
      meetingID: base.meetingID, processingVersion: base.processingVersion,
      pieceTargetSeconds: base.pieceTargetSeconds, pieceSearchSeconds: base.pieceSearchSeconds,
      seamPaddingSeconds: base.seamPaddingSeconds, cutsPieces: base.cutsPieces,
      transcriptLanguage: "de", inputs: base.inputs)
    let saved = MeetingProcessingCheckpoint(
      key: german, engineIdentity: "ultra:rev", tracks: checkpoint().tracks)
    try store.save(saved)
    let json = try #require(String(data: try Data(contentsOf: store.fileURL), encoding: .utf8))
    #expect(json.contains(#""formatVersion":2"#))
    #expect(json.contains(#""transcriptLanguage":"de""#))
    // An older build (format 1 reader) never reuses the German words.
    #expect(store.load(acceptingFormatVersion: 1) == .unusable)
    // Upgraded again: the checkpoint loads, and its key matches only a German pass.
    #expect(store.load() == .checkpoint(saved))
    #expect(german != base, "Auto and German keys differ")
  }

  @Test("Auto has one spelling in the key: absent, nil and empty all compare equal")
  func autoKeysCompareEqual() throws {
    let base = checkpoint().key
    func key(_ language: String?) -> MeetingProcessingCheckpoint.Key {
      .init(
        meetingID: base.meetingID, processingVersion: base.processingVersion,
        pieceTargetSeconds: base.pieceTargetSeconds, pieceSearchSeconds: base.pieceSearchSeconds,
        seamPaddingSeconds: base.seamPaddingSeconds, cutsPieces: base.cutsPieces,
        transcriptLanguage: language, inputs: base.inputs)
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
}
