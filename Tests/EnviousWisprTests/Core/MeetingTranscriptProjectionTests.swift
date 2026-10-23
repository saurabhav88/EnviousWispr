import Foundation
import Testing

@testable import EnviousWisprCore

/// #3972 R19: when these fail, Copy or Export shows lines the screen hides (or the reverse), or a
/// fully hidden transcript falls back to showing the hidden lines.
@Suite("MeetingTranscriptProjection", .tags(.productOutcome))
struct MeetingTranscriptProjectionTests {

  private let text = "Hello there\n\nHello there\n\nThanks"
  private var turns: [Turn] {
    [
      Turn(id: "m0-0", speakerId: "sys:S1", startMs: 0, endMs: 900, originalTextRange: 0..<11),
      Turn(
        id: "m1-100", speakerId: "mic:S1", startMs: 100, endMs: 1000, originalTextRange: 13..<24),
      Turn(
        id: "m2-2000", speakerId: "mic:S1", startMs: 2000, endMs: 2500, originalTextRange: 26..<32),
    ]
  }
  private let names = ["sys:S1": "Speaker 1", "mic:S1": "You"]

  @Test("echo turns are hidden by default and shown with the toggle; Copy follows the same rule")
  func hiddenAndShown() {
    let echo: Set<String> = ["m1-100"]
    let hidden = MeetingTranscriptProjection.visible(
      turns: turns, echoTurnIDs: echo, showEcho: false)
    #expect(hidden.turns.map(\.id) == ["m0-0", "m2-2000"])
    #expect(!hidden.everythingHidden)
    #expect(
      MeetingTranscriptProjection.plainText(
        text: text, turns: turns, speakerNames: names, echoTurnIDs: echo, showEcho: false)
        == "Speaker 1: Hello there\n\nYou: Thanks")
    let shown = MeetingTranscriptProjection.visible(turns: turns, echoTurnIDs: echo, showEcho: true)
    #expect(shown.turns.count == 3)
  }

  @Test("when every turn is echo the projection is empty and says so, never the raw text")
  func everythingHiddenStaysEmpty() {
    let all = Set(turns.map(\.id))
    let visible = MeetingTranscriptProjection.visible(
      turns: turns, echoTurnIDs: all, showEcho: false)
    #expect(visible.turns.isEmpty)
    #expect(visible.everythingHidden)
    #expect(
      MeetingTranscriptProjection.plainText(
        text: text, turns: turns, speakerNames: names, echoTurnIDs: all, showEcho: false
      ).isEmpty)
  }

  @Test("reserved speaker classifications get no name prefix")
  func reservedHaveNoPrefix() {
    let both = [Turn(id: "b", speakerId: "both", startMs: 0, endMs: 1, originalTextRange: 0..<11)]
    #expect(
      MeetingTranscriptProjection.plainText(
        text: text, turns: both, speakerNames: names, echoTurnIDs: [], showEcho: false)
        == "Hello there")
  }
}
