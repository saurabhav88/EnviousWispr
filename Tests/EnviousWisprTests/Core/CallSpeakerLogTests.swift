import Foundation
import Testing

@testable import EnviousWisprCore

/// #4013: when these fail, a meeting's saved call-speaker evidence is lost, misread after an
/// upgrade, or read as a confident guess, and real names land on the wrong lines.
@Suite("CallSpeakerLog", .tags(.productOutcome))
struct CallSpeakerLogTests {

  /// A log as this build writes it, read back from literal JSON so the stored shape is pinned.
  @Test("a saved log reads back from its stored JSON with every field")
  func readsStoredShape() throws {
    let json = """
      {"formatVersion":1,"surface":"teams_app","source":"app","status":"observed",
       "lag":{"milliseconds":-350},
       "rules":{"version":3,"payload":"{\\"meet\\":[\\"kssMZb\\"]}"},
       "roster":{"names":["Alex Rivera","Priya Shah","Alex Rivera"],"selfNames":["Saurabh Vaish"]},
       "observations":[{"observationMs":1500,"speaking":["Alex Rivera"]},
                       {"observationMs":2000,"speaking":[]}]}
      """
    let log = try JSONDecoder().decode(CallSpeakerLog.self, from: Data(json.utf8))
    #expect(log.surface == .teamsApp)
    #expect(log.source == .app)
    #expect(log.status == .observed)
    #expect(log.lag == CallSpeakerLag(milliseconds: -350))
    #expect(log.rules == FrozenTalkerRules(version: 3, payload: #"{"meet":["kssMZb"]}"#))
    #expect(log.roster.names == ["Alex Rivera", "Priya Shah", "Alex Rivera"], "duplicates kept")
    #expect(log.roster.selfNames == ["Saurabh Vaish"])
    #expect(
      log.observations == [
        CallSpeakerObservation(observationMs: 1500, speaking: ["Alex Rivera"]),
        CallSpeakerObservation(observationMs: 2000, speaking: []),
      ])

    let reencoded = try JSONDecoder().decode(
      CallSpeakerLog.self, from: try JSONEncoder().encode(log))
    #expect(reencoded == log)
  }

  /// A newer build may add a surface, source or status; this build must read it as unknown,
  /// not fail and not map it to something it knows.
  @Test("an unknown surface, source or status reads as unknown and survives a re-save")
  func unknownValuesStayUnknown() throws {
    let json = """
      {"formatVersion":1,"surface":"discord","source":"vision","status":"paused",
       "roster":{"names":[],"selfNames":[]},"observations":[]}
      """
    let log = try JSONDecoder().decode(CallSpeakerLog.self, from: Data(json.utf8))
    #expect(log.surface == nil)
    #expect(log.source == nil)
    #expect(log.status == nil)
    let object = try #require(
      try JSONSerialization.jsonObject(with: try JSONEncoder().encode(log)) as? [String: Any])
    #expect(object["surface"] as? String == "discord", "re-save keeps the newer build's value")
  }

  /// Missing metadata is unknown, never filled in: no lag means no lag was measured.
  @Test("a log with only the format version reads with no lag, rules, roster or samples")
  func minimalLog() throws {
    let log = try JSONDecoder().decode(
      CallSpeakerLog.self, from: Data(#"{"formatVersion":1}"#.utf8))
    #expect(log.surface == nil)
    #expect(log.lag == nil)
    #expect(log.rules == nil)
    #expect(log.roster == .empty)
    #expect(log.observations.isEmpty)
  }

  @Test("a log from a newer format fails to decode instead of being misread")
  func newerFormatRefused() {
    #expect(throws: CallSpeakerLog.DecodeError.unsupportedFormatVersion(2)) {
      try JSONDecoder().decode(CallSpeakerLog.self, from: Data(#"{"formatVersion":2}"#.utf8))
    }
  }

  /// r2 item 2: lag is indicator time minus voice onset, so a positive lag moves the voice
  /// earlier and a negative lag moves it later.
  @Test("lag of either sign moves an observation onto the voice it points to")
  func signedLag() {
    #expect(CallSpeakerLag(milliseconds: 500).audioAlignedMs(10_000) == 9_500)
    #expect(CallSpeakerLag(milliseconds: -250).audioAlignedMs(10_000) == 10_250)
    #expect(CallSpeakerLag(milliseconds: 0).audioAlignedMs(42) == 42)
  }
}
