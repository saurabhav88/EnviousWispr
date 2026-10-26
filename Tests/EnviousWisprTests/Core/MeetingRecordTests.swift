import Foundation
import Testing

@testable import EnviousWisprCore

/// #3972 R3: when these fail, a meeting is lost or rewritten wrongly after a crash or an upgrade.
@Suite("MeetingRecord", .tags(.productOutcome))
struct MeetingRecordTests {

  @Test("round-trips through JSON with tracks as object keys")
  func roundTrip() throws {
    var record = MeetingRecord(
      engine: .parakeet, trackStatus: [.microphone: .captured, .callSound: .denied])
    record.segments[.microphone] = [
      MeetingSegmentInfo(index: 1, fileName: "mic-00001.caf", startMs: 0, frameCount: 960_000)
    ]
    record.gaps[.microphone] = [60_000...61_500]
    let data = try JSONEncoder().encode(record)
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(json.contains("\"microphone\""))
    let decoded = try JSONDecoder().decode(MeetingRecord.self, from: data)
    #expect(decoded == record)
    #expect(decoded.recordedDurationMs == 60_000)
  }

  /// #4105: the transcript language a meeting was started with survives a save and reload; a
  /// record written before the field reads as Auto.
  @Test("the transcript language round-trips, and an older record without it reads as Auto")
  func transcriptLanguage() throws {
    var record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    #expect(record.transcriptLanguageMode == .auto)
    record.transcriptLanguageMode = .locked("de")
    let data = try JSONEncoder().encode(record)
    let decoded = try JSONDecoder().decode(MeetingRecord.self, from: data)
    #expect(decoded.transcriptLanguage == "de")
    #expect(decoded.transcriptLanguageMode == .locked("de"))
    #expect(decoded.formatVersion == MeetingRecord.currentFormatVersion, "no format bump")

    var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "transcriptLanguage")
    let older = try JSONDecoder().decode(
      MeetingRecord.self, from: try JSONSerialization.data(withJSONObject: object))
    #expect(older.transcriptLanguage == nil)
    #expect(older.transcriptLanguageMode == .auto)

    record.transcriptLanguageMode = .auto
    #expect(record.transcriptLanguage == nil)
    record.transcriptLanguageMode = .locked("")
    #expect(record.transcriptLanguage == nil, "an empty lock is Auto")
  }

  @Test("segment names carry track, index and start, and parse back; malformed names are rejected")
  func namingRoundTrip() {
    let name = MeetingSegmentNaming.fileName(
      track: .callSound, index: 12, startMs: 720_500, partial: true)
    #expect(name == "system-00012-s000720500.caf.partial")
    #expect(
      MeetingSegmentNaming.parse(name)
        == .init(track: .callSound, index: 12, startMs: 720_500, partial: true))
    let big = MeetingSegmentNaming.fileName(
      track: .microphone, index: 123_456, startMs: 0, partial: false)
    #expect(MeetingSegmentNaming.parse(big)?.index == 123_456)
    // Past 2^31 ms (about 25 days) a 32-bit format would wrap negative; names must not.
    let long = MeetingSegmentNaming.fileName(
      track: .microphone, index: 1, startMs: 2_147_483_648, partial: false)
    #expect(long == "mic-00001-s2147483648.caf")
    #expect(MeetingSegmentNaming.parse(long)?.startMs == 2_147_483_648)
    for bad in [
      "mic-00001.caf", "mic-00000-s000000000.caf", "mic-00001-s-00000001.caf",
      "voice-00001-s000000000.caf", "mic-00001-s000000000.wav",
    ] {
      #expect(MeetingSegmentNaming.parse(bad) == nil, "\(bad)")
    }
  }

  @Test("a record from a newer format still yields its header")
  func headerOfNewerFormat() throws {
    let json = """
      {"formatVersion": 9, "id": "6F9619FF-8B86-D011-B42D-00C04FC964FF",
       "createdAt": "2027-01-01T10:00:00Z", "unknown": {"a": 1}}
      """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let header = try decoder.decode(MeetingRecord.Header.self, from: Data(json.utf8))
    #expect(header.formatVersion == 9)
    #expect((try? decoder.decode(MeetingRecord.self, from: Data(json.utf8))) == nil)
  }

  @Test(
    "launch recovery: an unfinished recording becomes interrupted, a pass in flight is queued again"
  )
  func recoveredStates() {
    #expect(MeetingRecord.recoveredState(from: .recording) == .interrupted)
    #expect(MeetingRecord.recoveredState(from: .stopping) == .interrupted)
    #expect(MeetingRecord.recoveredState(from: .processing) == .queued)
    #expect(MeetingRecord.recoveredState(from: .ready) == nil)
    #expect(MeetingRecord.recoveredState(from: .failed) == nil)
  }
}
