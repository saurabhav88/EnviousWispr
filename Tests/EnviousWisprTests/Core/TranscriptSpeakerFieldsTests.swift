import Foundation
import Testing

@testable import EnviousWisprCore

/// `Transcript` gains optional `speakerAnalysis` / `speakerNames` / `turns` (#2810, phase 3 of
/// #2807). Decode-safety matches the established pattern (#1063, #1408, #2087, #2772): a
/// pre-#2810 row must still decode, with the new fields nil. `mergingSpeakerFields` is the
/// single write-time enforcement point for the cross-field invariant a decode cannot check,
/// and it computes its own default names (never takes one from the caller) so a surviving
/// speakerId can never be silently dropped from `speakerNames` (found by chunk review).
@Suite("Transcript speaker fields (#2810)", .tags(.productOutcome))
struct TranscriptSpeakerFieldsTests {

  @Test("a pre-#2810 JSON row decodes with the new fields nil")
  func legacyJSONDecodes() throws {
    let id = UUID().uuidString
    let legacy = """
      {"id":"\(id)","text":"hello world","duration":1.5,"processingTime":0.2,\
      "backendType":"parakeet","createdAt":12345.0}
      """
    let transcript = try JSONDecoder().decode(Transcript.self, from: Data(legacy.utf8))
    #expect(transcript.speakerAnalysis == nil)
    #expect(transcript.speakerNames == nil)
    #expect(transcript.turns == nil)
  }

  @Test("a non-labeled outcome clears turns and names")
  func nonLabeledClearsTurnsAndNames() {
    let labeled = Transcript(text: "x").mergingSpeakerFields(
      analysis: .labeled(count: 2),
      turns: [Turn(id: "0-1", speakerId: "A", startMs: 0, endMs: 100, originalTextRange: 0..<1)])
    let single = labeled.mergingSpeakerFields(analysis: .single, turns: nil)
    #expect(single.speakerAnalysis == .single)
    #expect(single.turns == nil)
    #expect(single.speakerNames == nil)
  }

  @Test("a fresh labeled merge fills every surviving speakerId's name, excluding unknown")
  func freshMergeFillsEveryName() {
    // Two real speakers plus "unknown" — no existing names, no caller-supplied defaults
    // possible (the parameter is gone): every real speakerId must still get a name.
    let turns = [
      Turn(id: "0-1", speakerId: "A", startMs: 0, endMs: 100, originalTextRange: 0..<1),
      Turn(id: "2-3", speakerId: "unknown", startMs: nil, endMs: nil, originalTextRange: 2..<3),
      Turn(id: "4-5", speakerId: "B", startMs: 200, endMs: 300, originalTextRange: 4..<5),
    ]
    let merged = Transcript(text: "x").mergingSpeakerFields(
      analysis: .labeled(count: 2), turns: turns)
    #expect(merged.speakerNames == ["A": "Speaker 1", "B": "Speaker 2"])
    #expect(merged.speakerNames?["unknown"] == nil)
  }

  @Test("a retry preserves an existing name for a surviving speakerId")
  func retryPreservesExistingName() {
    let firstTurns = [
      Turn(id: "0-1", speakerId: "A", startMs: 0, endMs: 100, originalTextRange: 0..<1)
    ]
    let first = Transcript(text: "x").mergingSpeakerFields(
      analysis: .labeled(count: 1), turns: firstTurns)
    // Simulate a rename having already happened to this row (phase 4, out of this phase's
    // scope to trigger, but the merge function must not clobber it on a later cleanup pass).
    let renamed = first.mergingSpeakerFields(
      analysis: .labeled(count: 1), turns: firstTurns, explicitRename: ("A", "Zach"))
    #expect(renamed.speakerNames == ["A": "Zach"])

    // A later retry with the SAME surviving speakerId must not overwrite "Zach" back to a
    // freshly-computed default.
    let retried = renamed.mergingSpeakerFields(analysis: .labeled(count: 1), turns: firstTurns)
    #expect(retried.speakerNames == ["A": "Zach"])
  }

  @Test("a retry removes a name whose speakerId no longer appears, and fills a new one")
  func retryRetiresAndFills() {
    let firstTurns = [
      Turn(id: "0-1", speakerId: "A", startMs: 0, endMs: 100, originalTextRange: 0..<1)
    ]
    let first = Transcript(text: "x").mergingSpeakerFields(
      analysis: .labeled(count: 1), turns: firstTurns)

    // A fresh TurnAssembler pass reshuffles which ids appear: "A" is gone, "B" is new.
    let secondTurns = [
      Turn(id: "0-1", speakerId: "B", startMs: 0, endMs: 100, originalTextRange: 0..<1)
    ]
    let second = first.mergingSpeakerFields(analysis: .labeled(count: 1), turns: secondTurns)
    #expect(second.speakerNames == ["B": "Speaker 1"])
  }

  @Test("an explicit rename overwrites exactly the named speakerId, preserving the rest")
  func explicitRenameOverwritesOneID() {
    let turns = [
      Turn(id: "0-1", speakerId: "A", startMs: 0, endMs: 100, originalTextRange: 0..<1),
      Turn(id: "2-3", speakerId: "B", startMs: 200, endMs: 300, originalTextRange: 2..<3),
    ]
    let merged = Transcript(text: "x").mergingSpeakerFields(
      analysis: .labeled(count: 2), turns: turns, explicitRename: ("A", "Zach"))
    #expect(merged.speakerNames == ["A": "Zach", "B": "Speaker 2"])
  }

  @Test("a legacy-JSON transcript's new fields round-trip through Codable")
  func newFieldsRoundTrip() throws {
    let original = Transcript(text: "x").mergingSpeakerFields(
      analysis: .labeled(count: 1),
      turns: [Turn(id: "0-1", speakerId: "A", startMs: 0, endMs: 100, originalTextRange: 0..<1)])
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(Transcript.self, from: data)
    #expect(decoded.speakerAnalysis == .labeled(count: 1))
    #expect(decoded.speakerNames == ["A": "Speaker 1"])
    #expect(decoded.turns?.first?.id == "0-1")
  }

  @Test("SpeakerAnalysis maps exhaustively to the persisted TranscriptSpeakerAnalysis")
  func speakerAnalysisMapsExhaustively() {
    #expect(SpeakerAnalysis.single(segments: []).asStorageAnalysis == .single)
    #expect(SpeakerAnalysis.labeled(count: 3, segments: []).asStorageAnalysis == .labeled(count: 3))
    #expect(
      SpeakerAnalysis.failed(.modelsUnavailable).asStorageAnalysis == .failed(.modelsUnavailable))
    #expect(
      SpeakerAnalysis.failed(.analyzerThrew("boom")).asStorageAnalysis == .failed(.analyzerThrew))
    #expect(
      SpeakerAnalysis.failed(.noSpeakerSegments).asStorageAnalysis == .failed(.noSpeakerSegments))
    #expect(SpeakerAnalysis.failed(.cancelled).asStorageAnalysis == .failed(.cancelled))
    #expect(SpeakerAnalysis.timedOut(afterMs: 20_000).asStorageAnalysis == .failed(.timedOut))
  }

  @Test("analyzerThrew's diagnostic string is stripped before persisting")
  func analyzerThrewStripsDiagnosticText() {
    let mapped = SpeakerFailure.analyzerThrew("a very specific crash string").asStorageReason
    #expect(mapped == .analyzerThrew)
  }
}
