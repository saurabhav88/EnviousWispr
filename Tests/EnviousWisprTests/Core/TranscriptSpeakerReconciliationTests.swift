import Foundation
import Testing

@testable import EnviousWisprCore

/// #4013 r2 item 4, r3 F2, F3: when these fail, Transcribe again throws away the names the user
/// typed, moves a name onto the wrong person or the wrong track, lets a stale automatic name pose
/// as the user's, or loses a name with nowhere to offer it again.
///
/// The "incoming" rows here are synthetic replacements written by hand, standing in for what a
/// meeting's processing pass will produce; they exercise the reconciliation, not the pass.
@Suite("Transcript speaker-name provenance and reconciliation", .tags(.productOutcome))
struct TranscriptSpeakerReconciliationTests {

  private static let id = UUID()

  private static func turn(_ speaker: String, _ start: Int?, _ end: Int?, _ tag: String = "")
    -> Turn
  {
    Turn(
      id: "\(speaker)-\(start ?? -1)\(tag)", speakerId: speaker, startMs: start, endMs: end,
      originalTextRange: 0..<1, wasPolished: true, granularity: .word)
  }

  private static func row(
    _ turns: [Turn], names: [String: String], sources: [String: SpeakerNameSource]? = [:],
    unassigned: [String]? = nil
  ) -> Transcript {
    Transcript(
      id: id, text: "x", backendType: .parakeet,
      speakerAnalysis: .labeled(count: max(1, Set(turns.map(\.speakerId)).count)),
      speakerNames: names, turns: turns, speakerNameSources: sources,
      unassignedSpeakerNames: unassigned, meetingID: UUID())
  }

  // MARK: - Provenance

  @Test("provenance and kept names survive a save and a reload")
  func codableRoundTrip() throws {
    let row = Self.row(
      [Self.turn("sys:S1", 0, 10)], names: ["sys:S1": "Alex Rivera"],
      sources: ["sys:S1": .auto], unassigned: ["Priya Shah"])
    let back = try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(row))
    #expect(back.speakerNameSources == ["sys:S1": .auto])
    #expect(back.unassignedSpeakerNames == ["Priya Shah"])
    #expect(back.speakerNameSource(for: "sys:S1") == .auto)
  }

  @Test(
    "an older row's typed names count as the user's, with their exact spelling; its labels do not")
  func legacyRows() throws {
    let json = """
      {"id":"\(UUID().uuidString)","text":"x","duration":0,"processingTime":0,
       "backendType":"parakeet","createdAt":0,
       "speakerNames":{"sys:S1":"  Dr. Ana  ","sys:S2":"Speaker 2","mic:you":"You","sys:call":"Call",
                       "sys:S3":"Speaker"}}
      """
    let row = try JSONDecoder().decode(Transcript.self, from: Data(json.utf8))
    #expect(row.speakerNameSources == nil)
    #expect(row.speakerNameSource(for: "sys:S1") == .manual)
    #expect(row.speakerNames?["sys:S1"] == "  Dr. Ana  ")
    #expect(row.speakerNameSource(for: "sys:S2") == nil)
    #expect(row.speakerNameSource(for: "mic:you") == nil)
    #expect(row.speakerNameSource(for: "sys:call") == nil)
    #expect(
      row.speakerNameSource(for: "sys:S3") == .manual, "only the generated pattern is a label")
  }

  @Test("an explicit rename is manual, even when it reads like a generated label")
  func renameIsManual() {
    let base = Self.row(
      [Self.turn("sys:S1", 0, 10)], names: ["sys:S1": "Alex Rivera"], sources: ["sys:S1": .auto])
    let renamed = base.mergingSpeakerFields(
      analysis: .labeled(count: 1), turns: base.turns, explicitRename: ("sys:S1", "Speaker 7"))
    #expect(renamed.speakerNames?["sys:S1"] == "Speaker 7")
    #expect(renamed.speakerNameSource(for: "sys:S1") == .manual)
  }

  @Test("a rename to a kept name takes it out of the kept list")
  func renameConsumesKeptName() {
    let base = Self.row(
      [Self.turn("sys:S1", 0, 10)], names: ["sys:S1": "Speaker 1"], unassigned: ["Ana", "Ben"])
    let renamed = base.mergingSpeakerFields(
      analysis: .labeled(count: 1), turns: base.turns, explicitRename: ("sys:S1", "Ana"))
    #expect(renamed.unassignedSpeakerNames == ["Ben"])
  }

  @Test("a speaker merge that retires a typed name, or clears the speakers, keeps the name")
  func mergeKeepsTypedNames() {
    let base = Self.row(
      [Self.turn("sys:S1", 0, 10), Self.turn("sys:S2", 10, 20)],
      names: ["sys:S1": "Ana", "sys:S2": "Speaker 2"], sources: ["sys:S1": .manual])
    let retired = base.mergingSpeakerFields(
      analysis: .labeled(count: 1), turns: [Self.turn("sys:S2", 0, 20)])
    #expect(retired.speakerNames == ["sys:S2": "Speaker 2"])
    #expect(retired.unassignedSpeakerNames == ["Ana"])
    let cleared = base.mergingSpeakerFields(analysis: .single, turns: nil)
    #expect(cleared.speakerNames == nil)
    #expect(cleared.speakerNameSources == nil)
    #expect(cleared.unassignedSpeakerNames == ["Ana"])
  }

  @Test("carrying speaker fields carries names, provenance and kept names together")
  func carryAll() {
    let source = Self.row(
      [Self.turn("sys:S1", 0, 10)], names: ["sys:S1": "Ana"], sources: ["sys:S1": .manual],
      unassigned: ["Ben"])
    let carried = Transcript(id: Self.id, text: "y", backendType: .parakeet)
      .carryingSpeakerFields(from: source)
    #expect(carried.speakerNames == ["sys:S1": "Ana"])
    #expect(carried.speakerNameSources == ["sys:S1": .manual])
    #expect(carried.unassignedSpeakerNames == ["Ben"])
    #expect(carried.text == "y")
  }

  // MARK: - Reconciliation

  @Test("a typed name moves to the new speaker that overlaps it most on the same track")
  func moveByOverlap() {
    let current = Self.row(
      [Self.turn("sys:S1", 0, 5_000), Self.turn("sys:S2", 5_000, 10_000)],
      names: ["sys:S1": "Ana", "sys:S2": "Speaker 2"], sources: ["sys:S1": .manual])
    let incoming = Self.row(
      [Self.turn("sys:S7", 500, 4_500), Self.turn("sys:S8", 4_500, 10_000)],
      names: ["sys:S7": "Speaker 1", "sys:S8": "Speaker 2"])
    let result = incoming.reconcilingSpeakerNames(withCurrent: current)
    #expect(result.speakerNames == ["sys:S7": "Ana", "sys:S8": "Speaker 2"])
    #expect(result.speakerNameSources == ["sys:S7": .manual])
    #expect(result.unassignedSpeakerNames == nil)
    #expect(result.turns == incoming.turns)
    #expect(result.text == incoming.text)
  }

  @Test("the call's You keeps its name and is never matched to anyone else")
  func stableYou() {
    let current = Self.row(
      [Self.turn("mic:you", 0, 10_000), Self.turn("sys:S1", 0, 10_000)],
      names: ["mic:you": "Saurabh", "sys:S1": "Speaker 1"], sources: ["mic:you": .manual])
    let kept = Self.row(
      [Self.turn("mic:you", 9_000, 9_500), Self.turn("sys:S2", 0, 10_000)],
      names: ["mic:you": "You", "sys:S2": "Speaker 1"]
    )
    .reconcilingSpeakerNames(withCurrent: current)
    #expect(kept.speakerNames?["mic:you"] == "Saurabh")
    let gone = Self.row(
      [Self.turn("mic:S1", 0, 10_000), Self.turn("sys:S2", 0, 10_000)],
      names: ["mic:S1": "Speaker 1", "sys:S2": "Speaker 2"]
    )
    .reconcilingSpeakerNames(withCurrent: current)
    #expect(gone.speakerNames == ["mic:S1": "Speaker 1", "sys:S2": "Speaker 2"])
    #expect(gone.unassignedSpeakerNames == ["Saurabh"])
  }

  @Test("simultaneous speech never moves a call speaker's name onto the microphone")
  func neverAcrossTracks() {
    // The old call speaker overlaps a new microphone speaker for 9 s and the new call speaker
    // for only 1 s: an unrestricted match would pick the microphone.
    let current = Self.row(
      [Self.turn("sys:S1", 0, 10_000)], names: ["sys:S1": "Ana"], sources: ["sys:S1": .manual])
    let incoming = Self.row(
      [Self.turn("mic:S1", 0, 9_000), Self.turn("sys:S4", 9_000, 10_000)],
      names: ["mic:S1": "Speaker 1", "sys:S4": "Speaker 2"])
    let result = incoming.reconcilingSpeakerNames(withCurrent: current)
    #expect(result.speakerNames == ["mic:S1": "Speaker 1", "sys:S4": "Ana"])
  }

  @Test(
    "a tie, no overlap, missing times, or two names wanting one speaker keep the names unassigned")
  func ambiguousCases() {
    let incoming = Self.row(
      [Self.turn("sys:S5", 0, 2_000), Self.turn("sys:S6", 2_000, 4_000)],
      names: ["sys:S5": "Speaker 1", "sys:S6": "Speaker 2"])
    let tie = Self.row(
      [Self.turn("sys:S1", 1_000, 3_000)], names: ["sys:S1": "Ana"], sources: ["sys:S1": .manual])
    #expect(incoming.reconcilingSpeakerNames(withCurrent: tie).unassignedSpeakerNames == ["Ana"])
    let apart = Self.row(
      [Self.turn("sys:S1", 8_000, 9_000)], names: ["sys:S1": "Ana"], sources: ["sys:S1": .manual])
    #expect(incoming.reconcilingSpeakerNames(withCurrent: apart).unassignedSpeakerNames == ["Ana"])
    let untimed = Self.row(
      [Self.turn("sys:S1", nil, nil)], names: ["sys:S1": "Ana"], sources: ["sys:S1": .manual])
    #expect(
      incoming.reconcilingSpeakerNames(withCurrent: untimed).unassignedSpeakerNames == ["Ana"])
    // A split speaker merged into one: both names want sys:S5.
    let merged = Self.row(
      [Self.turn("sys:S1", 0, 1_000), Self.turn("sys:S2", 1_000, 2_000)],
      names: ["sys:S1": "Ana", "sys:S2": "Ben"], sources: ["sys:S1": .manual, "sys:S2": .manual])
    let result = incoming.reconcilingSpeakerNames(withCurrent: merged)
    #expect(result.speakerNames == ["sys:S5": "Speaker 1", "sys:S6": "Speaker 2"])
    #expect(result.unassignedSpeakerNames == ["Ana", "Ben"])
    #expect(result.speakerNameSources == [:])
  }

  @Test("a speaker split in two gives the name to the larger part only")
  func split() {
    let current = Self.row(
      [Self.turn("sys:S1", 0, 10_000)], names: ["sys:S1": "Ana"], sources: ["sys:S1": .manual])
    let incoming = Self.row(
      [Self.turn("sys:S2", 0, 7_000), Self.turn("sys:S3", 7_000, 10_000)],
      names: ["sys:S2": "Speaker 1", "sys:S3": "Speaker 2"])
    #expect(
      incoming.reconcilingSpeakerNames(withCurrent: current).speakerNames
        == ["sys:S2": "Ana", "sys:S3": "Speaker 2"])
  }

  @Test("overlapping turns are not counted twice when choosing the match")
  func noDoubleCount() {
    // Old Ana: 0-4000. New S2 has three copies of 0-2000 (2 s real overlap); S3 has 2000-4000
    // plus 2000-3000 (2 s). Counted per turn, S2 would win 6 s to 3 s; counted once, it is a tie.
    let current = Self.row(
      [Self.turn("sys:S1", 0, 4_000)], names: ["sys:S1": "Ana"], sources: ["sys:S1": .manual])
    let incoming = Self.row(
      [
        Self.turn("sys:S2", 0, 2_000, "a"), Self.turn("sys:S2", 0, 2_000, "b"),
        Self.turn("sys:S2", 0, 2_000, "c"), Self.turn("sys:S3", 2_000, 4_000, "a"),
        Self.turn("sys:S3", 2_000, 3_000, "b"),
      ], names: ["sys:S2": "Speaker 1", "sys:S3": "Speaker 2"])
    #expect(
      incoming.reconcilingSpeakerNames(withCurrent: current).unassignedSpeakerNames == ["Ana"])
  }

  @Test("a moved typed name beats an automatic proposal; old automatic names are not carried")
  func manualBeatsAuto() {
    let current = Self.row(
      [Self.turn("sys:S1", 0, 5_000), Self.turn("sys:S2", 5_000, 10_000)],
      names: ["sys:S1": "Ana", "sys:S2": "Old Auto"],
      sources: ["sys:S1": .manual, "sys:S2": .auto])
    // The pass proposes "Priya" for the speaker that inherits Ana, and "Ana" elsewhere.
    let incoming = Self.row(
      [
        Self.turn("sys:S7", 0, 5_000), Self.turn("sys:S8", 5_000, 10_000),
        Self.turn("sys:S9", 10_000, 12_000),
      ],
      names: ["sys:S7": "Priya", "sys:S8": "Speaker 2", "sys:S9": "Ana"],
      sources: ["sys:S7": .auto, "sys:S9": .auto, "sys:S8": .manual])
    let result = incoming.reconcilingSpeakerNames(withCurrent: current)
    #expect(result.speakerNames?["sys:S7"] == "Ana")
    #expect(result.speakerNameSource(for: "sys:S7") == .manual)
    #expect(result.speakerNames?["sys:S8"] == "Speaker 2", "the stale automatic name is gone")
    #expect(result.speakerNameSource(for: "sys:S8") == nil, "an incoming manual claim is ignored")
    #expect(result.speakerNames?["sys:S9"] == "Speaker 3", "the duplicate proposal falls back")
    #expect(result.speakerNameSource(for: "sys:S9") == nil)
  }

  @Test("kept names survive a second Transcribe again and a reload, without duplicates")
  func keptAcrossRuns() throws {
    let current = Self.row(
      [Self.turn("sys:S1", 0, 1_000)], names: ["sys:S1": "Ana"], sources: ["sys:S1": .manual],
      unassigned: ["Ben"])
    let first = Self.row([Self.turn("sys:S5", 5_000, 6_000)], names: ["sys:S5": "Speaker 1"])
      .reconcilingSpeakerNames(withCurrent: current)
    #expect(first.unassignedSpeakerNames == ["Ben", "Ana"])
    let reloaded = try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(first))
    let second = Self.row([Self.turn("sys:S9", 7_000, 8_000)], names: ["sys:S9": "Speaker 1"])
      .reconcilingSpeakerNames(withCurrent: reloaded)
    #expect(second.unassignedSpeakerNames == ["Ben", "Ana"])
  }

  @Test("a row with no speaker turns keeps its typed names unassigned and changes nothing else")
  func noTurnsIncoming() {
    let current = Self.row(
      [Self.turn("sys:S1", 0, 1_000)], names: ["sys:S1": "Ana"], sources: ["sys:S1": .manual])
    let incoming = Transcript(
      id: Self.id, text: "nothing said", backendType: .parakeet, meetingID: UUID())
    let result = incoming.reconcilingSpeakerNames(withCurrent: current)
    #expect(result.speakerNames == nil)
    #expect(result.speakerNameSources == nil)
    #expect(result.turns == nil)
    #expect(result.unassignedSpeakerNames == ["Ana"])
    #expect(result.text == "nothing said")
  }

  @Test("a legacy row's custom name is reconciled as the user's")
  func legacyCurrent() {
    let current = Self.row(
      [Self.turn("sys:S1", 0, 1_000)], names: ["sys:S1": "Ana"], sources: nil)
    let result = Self.row([Self.turn("sys:S4", 0, 1_000)], names: ["sys:S4": "Speaker 1"])
      .reconcilingSpeakerNames(withCurrent: current)
    #expect(result.speakerNames == ["sys:S4": "Ana"])
    #expect(result.speakerNameSources == ["sys:S4": .manual])
  }
}
