import Foundation
import Testing

@testable import EnviousWisprCore

/// The S1-mini control line is a contract with a third party's weights (#2649).
/// The pickers can put any trained combination on the wire, so these rows pin
/// the VALUE SETS to the published card and the composed line to its shape.
/// When one fails, the app is about to send S1-mini a token it was never
/// trained on, which the card says makes it hallucinate or garble its output.
@Suite("S1-mini control settings (#2649)", .tags(.driftGuard))
struct S1ControlSettingsTests {

  /// The card's three value sets, transcribed literally. A raw value is the
  /// wire token, so the enum IS the allow-list; this row is what stops someone
  /// adding a plausible-looking fifth register.
  @Test("the value sets are exactly the card's trained sets")
  func valueSetsMatchTheCard() {
    #expect(
      S1Styling.allCases.map(\.rawValue) == ["casual", "semi-casual", "semi-formal", "formal"])
    #expect(S1Structure.allCases.map(\.rawValue) == ["prose", "lists"])
    #expect(S1Context.allCases.map(\.rawValue) == ["general", "email"])
  }

  /// The shipped values. Anyone who never opens the pickers runs under these,
  /// so a changed default here silently changes every install.
  @Test("the default is the shipped control line")
  func defaultIsTheShippedLine() {
    #expect(
      S1ControlSettings.default.controlLine
        == "[Styling: semi-formal] [Structure: lists] [Context: general]")
  }

  /// Every combination renders in the card's shape, with the raw tokens in the
  /// card's order. Generated from the enums rather than hand-picked, so a case
  /// added later is covered without anyone extending a list here.
  @Test("every trained combination composes in the card's shape")
  func everyCombinationComposes() {
    var seen: Set<String> = []
    for styling in S1Styling.allCases {
      for structure in S1Structure.allCases {
        for context in S1Context.allCases {
          let settings = S1ControlSettings(
            styling: styling, structure: structure, context: context)
          let line = settings.controlLine
          #expect(
            line
              == "[Styling: \(styling.rawValue)] [Structure: \(structure.rawValue)] [Context: \(context.rawValue)]"
          )
          // One line, no newline: the transcript follows on the NEXT line and
          // the connector recovers it by splitting on the first newline.
          #expect(!line.contains("\n"))
          #expect(line.hasPrefix("[Styling:"))
          seen.insert(line)
        }
      }
    }
    // 4 x 2 x 2, every one distinct.
    #expect(seen.count == 16)
  }

  /// The value rides inside the recovery spool's settings snapshot, so it must
  /// survive JSON with its raw tokens intact, and an unknown token must be a
  /// decode ERROR rather than a silent default: a spool that named a value this
  /// build does not know is a spool this build cannot honestly replay.
  @Test("Codable round-trips on the raw tokens and refuses an untrained one")
  func codableRoundTrip() throws {
    let picks = S1ControlSettings(styling: .semiCasual, structure: .prose, context: .email)
    let data = try JSONEncoder().encode(picks)
    let json = String(decoding: data, as: UTF8.self)
    #expect(json.contains("\"semi-casual\""))
    #expect(try JSONDecoder().decode(S1ControlSettings.self, from: data) == picks)

    let untrained = Data(
      #"{"styling":"shouty","structure":"prose","context":"email"}"#.utf8)
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(S1ControlSettings.self, from: untrained)
    }
  }
}
