import Foundation
import Testing

@testable import EnviousWisprCore

/// #4013 r2 item 5, r3 F4: when these fail, `meeting.ended` counts names the user typed, the
/// microphone or stale names as automatic ones, reports naming as working when every proposal
/// was replaced, or reports a summary for a History write that never landed.
///
/// Every row here is synthetic and written by hand, some passed through the real
/// `reconcilingSpeakerNames(withCurrent:)`. They prove the calculation; they do not prove the
/// processing pass or the durable write produce these inputs (that wiring lands after #3973
/// PR C).
@Suite("Speaker naming summary for meeting.ended", .tags(.observabilityContract))
struct SpeakerNamingSummaryTests {

  private static func turn(_ speaker: String, _ start: Int, _ end: Int) -> Turn {
    Turn(
      id: "\(speaker)-\(start)", speakerId: speaker, startMs: start, endMs: end,
      originalTextRange: 0..<1, wasPolished: true, granularity: .word)
  }

  private static func row(
    _ turns: [Turn], names: [String: String], sources: [String: SpeakerNameSource]? = [:]
  ) -> Transcript {
    Transcript(
      id: UUID(), text: "x", backendType: .parakeet,
      speakerAnalysis: .labeled(count: max(1, Set(turns.map(\.speakerId)).count)),
      speakerNames: names, turns: turns, speakerNameSources: sources, meetingID: UUID())
  }

  private static let turns = [
    turn("mic:you", 0, 1_000), turn("sys:S1", 1_000, 2_000), turn("sys:S2", 2_000, 3_000),
    turn("sys:S3", 3_000, 4_000),
  ]

  /// The pass's own row, with automatic proposals for S1 and S2.
  private static let proposals = row(
    turns, names: ["sys:S1": "Priya Shah", "sys:S2": "Dana Lee"],
    sources: ["sys:S1": .auto, "sys:S2": .auto])

  private func summary(
    _ row: Transcript, _ pass: SpeakerNamingPass, proposed: Transcript? = nil
  ) -> SpeakerNamingSummary? {
    PendingSpeakerNamingSummary(proposed: proposed ?? row, reconciled: row, pass: pass)
      .committed(.written)
  }

  @Test("every surface and outcome spelling is closed")
  func vocabularies() {
    #expect(
      SpeakerNamingSummary.Surface.allCases.map(\.rawValue) == [
        "zoom_app", "teams_app", "zoom_web", "teams_web", "meet", "slack_app", "slack_web",
        "unsupported", "none",
      ])
    #expect(
      SpeakerNamingSummary.Outcome.allCases.map(\.rawValue) == [
        "named", "no_permission", "no_signal", "ambiguous", "unsupported", "not_a_call",
        "unavailable", "manual_only",
      ])
  }

  @Test(
    "talker surfaces keep their spelling; roster-only call apps are unsupported; none is never inferred"
  )
  func surfaces() {
    for surface in CallSpeakerSurface.allCases {
      let mapped = SpeakerNamingSummary.Surface(surface)
      if let same = SpeakerNamingSummary.Surface(rawValue: surface.rawValue) {
        #expect(mapped == same)
      } else {
        #expect(mapped == .unsupported)
      }
    }
    #expect(SpeakerNamingSummary.Surface(nil) == nil)
  }

  @Test("only present call-sound speakers with automatic names count")
  func countsOnlyCommittedAutomaticCallNames() throws {
    let row = Self.row(
      Self.turns + [Self.turn("sys:call", 4_000, 5_000)],
      names: [
        "mic:you": "Alex Rivera", "sys:S1": "Priya Shah", "sys:S2": "Speaker 2",
        "sys:S3": "Dana Lee", "sys:call": "Call", "sys:S9": "Ben Ode",
      ],
      sources: [
        "mic:you": .auto, "sys:S1": .auto, "sys:S2": .auto, "sys:S3": .manual, "sys:call": .auto,
        "sys:S9": .auto,
      ])
    let result = try #require(summary(row, .proposed(surface: .teamsApp, count: 3)))
    #expect(result == .init(surface: .teamsApp, outcome: .named, autoNamedCount: 1))
  }

  @Test("an older row's typed names never count as automatic")
  func legacyRowCountsNothing() throws {
    let row = Self.row(
      Self.turns, names: ["sys:S1": "Priya Shah", "sys:S2": "Dana Lee"], sources: nil)
    let result = try #require(
      summary(row, .proposed(surface: .zoomApp, count: 2), proposed: Self.proposals))
    #expect(result.autoNamedCount == 0)
    #expect(result.outcome == .manualOnly)
  }

  @Test("mixed: a moved user name and a kept automatic name give named with a count of one")
  func mixedManualAndAutomatic() throws {
    let current = Self.row(
      Self.turns, names: ["sys:S1": "Sam Ortiz"], sources: ["sys:S1": .manual])
    let incoming = Self.row(
      Self.turns, names: ["sys:S1": "Priya Shah", "sys:S2": "Dana Lee"],
      sources: ["sys:S1": .auto, "sys:S2": .auto])
    let reconciled = incoming.reconcilingSpeakerNames(withCurrent: current)
    #expect(reconciled.speakerNameSources == ["sys:S1": .manual, "sys:S2": .auto])
    let result = try #require(
      summary(reconciled, .proposed(surface: .meet, count: 2), proposed: incoming))
    #expect(result == .init(surface: .meet, outcome: .named, autoNamedCount: 1))
  }

  @Test("every proposal displaced by the user's names gives manual_only")
  func allProposalsDisplaced() throws {
    let current = Self.row(
      Self.turns, names: ["sys:S1": "Sam Ortiz", "mic:you": "Priya Shah"],
      sources: ["sys:S1": .manual, "mic:you": .manual])
    // S1's proposal is replaced by the moved name; S2's proposal is the user's name for "You".
    let incoming = Self.row(
      Self.turns, names: ["sys:S1": "Dana Lee", "sys:S2": "Priya Shah"],
      sources: ["sys:S1": .auto, "sys:S2": .auto])
    let reconciled = incoming.reconcilingSpeakerNames(withCurrent: current)
    #expect(reconciled.speakerNameSources?.values.contains(.auto) == false)
    let result = try #require(
      summary(reconciled, .proposed(surface: .zoomWeb, count: 2), proposed: incoming))
    #expect(result == .init(surface: .zoomWeb, outcome: .manualOnly, autoNamedCount: 0))
  }

  @Test("the user's names with no proposals keep the namer's reason, never manual_only")
  func manualWithoutProposals() throws {
    let row = Self.row(Self.turns, names: ["sys:S1": "Sam Ortiz"], sources: ["sys:S1": .manual])
    let result = try #require(
      summary(row, .abstained(surface: .slackApp, outcome: .ambiguous)))
    #expect(result == .init(surface: .slackApp, outcome: .ambiguous, autoNamedCount: 0))
    let unknown = try #require(summary(row, .abstained(surface: nil, outcome: nil)))
    #expect(unknown == .init(surface: nil, outcome: nil, autoNamedCount: 0))
  }

  @Test("proposals that vanished with no user name to explain it give no outcome")
  func unexplainedLoss() throws {
    let row = Self.row(Self.turns, names: [:])
    let result = try #require(
      summary(row, .proposed(surface: .teamsWeb, count: 2), proposed: Self.proposals))
    #expect(result.outcome == nil)
    #expect(result.autoNamedCount == 0)
  }

  @Test("an unrelated user name does not explain vanished proposals")
  func unrelatedManualName() throws {
    let row = Self.row(
      Self.turns, names: ["mic:you": "Sam Ortiz", "sys:S1": "Speaker 1", "sys:S2": "Speaker 2"],
      sources: ["mic:you": .manual])
    let result = try #require(
      summary(row, .proposed(surface: .zoomApp, count: 2), proposed: Self.proposals))
    #expect(result == .init(surface: .zoomApp, outcome: nil, autoNamedCount: 0))
  }

  @Test("one proposal displaced and one vanished is not manual_only")
  func partlyDisplaced() throws {
    let row = Self.row(
      Self.turns, names: ["sys:S1": "Sam Ortiz", "sys:S2": "Speaker 2"],
      sources: ["sys:S1": .manual])
    let result = try #require(
      summary(row, .proposed(surface: .zoomApp, count: 2), proposed: Self.proposals))
    #expect(result.outcome == nil)
  }

  @Test(
    "a contradictory pass gives no outcome: an abstention that left automatic names, or a claimed named"
  )
  func contradictions() throws {
    let row = Self.row(Self.turns, names: ["sys:S1": "Priya Shah"], sources: ["sys:S1": .auto])
    for reason: SpeakerNamingSummary.Outcome in [.noSignal, .named, .manualOnly, .notACall] {
      let result = try #require(summary(row, .abstained(surface: .meet, outcome: reason)))
      #expect(result.outcome == nil, "\(reason)")
      #expect(result.autoNamedCount == 1)
    }
    #expect(try #require(summary(row, .notACall)).outcome == nil)
  }

  @Test("not a call needs the positive pass, and reports surface none with a known zero")
  func notACall() throws {
    let row = Self.row(Self.turns, names: [:])
    #expect(
      summary(row, .notACall)
        == .init(surface: SpeakerNamingSummary.Surface.none, outcome: .notACall, autoNamedCount: 0))
  }

  @Test("a failed or unknown write releases no summary")
  func uncommitted() {
    let pending = PendingSpeakerNamingSummary(
      proposed: Self.proposals,
      reconciled: Self.row(Self.turns, names: ["sys:S1": "Priya Shah"], sources: ["sys:S1": .auto]),
      pass: .proposed(surface: .teamsApp, count: 1))
    #expect(pending.committed(.failed) == nil)
    #expect(pending.committed(.unknown) == nil)
    #expect(pending.committed(.written)?.outcome == .named)
  }
}
