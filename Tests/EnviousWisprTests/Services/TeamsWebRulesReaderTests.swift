import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprServices

/// #4013 r5 step 3: when these fail, a Teams call in the browser names the wrong person, keeps
/// the " Unverified" tag in a name, or the shipped rules stop reading Teams web.
///
/// CAPTURED: the Teams web rule in the bundled rules file and the tile shape below come from the
/// C1 Teams web run of 2026-10-28 (`docs/audits/2026-10-27-4013/c1tw-receipt.txt`): each
/// participant is an AXMenuItem labelled with the name (guests end " Unverified"; the Mac's own
/// tile and the host carry no tag), and the talker's tile holds a group with class
/// `vdi-frame-occlusion` a few levels down. SYNTHETIC: the duplicate and nested cases.
@Suite("Teams web through the talker rules", .tags(.productOutcome))
struct TeamsWebRulesReaderTests {

  private static let good = CallCaptureContext(completeness: .complete, scope: .resolved)

  private func rule() throws -> SpeakerSelectorRule {
    try TalkerRules.decode(
      Data(
        contentsOf: RepoRoot.url.appending(
          path: "Sources/EnviousWisprServices/Resources/talker-rules.json"))
    ).rule(for: .teamsWeb)
  }

  private func tile(_ label: String, talking: Bool, inner: [CallAXNode] = []) -> CallAXNode {
    let frame = CallAXNode(
      role: "AXGroup",
      children: [
        CallAXNode(
          role: "AXGroup",
          children: [
            CallAXNode(
              role: "AXGroup",
              domClassList: talking ? ["fui-Flex", "vdi-frame-occlusion"] : ["fui-Flex"])
          ])
      ])
    return CallAXNode(role: "AXMenuItem", description: label, children: [frame] + inner)
  }

  private func read(_ tiles: [CallAXNode]) throws -> CallSpeakerReading {
    try #require(
      RulesSpeakerReader.read(
        documents: [
          CallAXDocument(
            // The meeting-link address the classifier accepts today. The live in-call page was
            // teams.live.com/light-meetings/launch?p=..., which it does not yet (#4162).
            url: "https://teams.live.com/meet/9379651200261",
            root: CallAXNode(role: "AXWebArea", children: tiles))
        ], rule: rule()))
  }

  @Test("CAPTURED: the shipped rules read Teams web; the guest tag is removed from names")
  func captured() throws {
    let rule = try rule()
    #expect(rule.mayReportTalker && rule.tilesAreParticipants)
    let reading = try read([
      tile("Sam Web", talking: false), tile("Saurabh Vaish", talking: false),
      tile("Alex Rivera Unverified", talking: false), tile("Priya Shah Unverified", talking: true),
    ])
    #expect(reading.roster.names == ["Sam Web", "Saurabh Vaish", "Alex Rivera", "Priya Shah"])
    #expect(CallSpeakerAdmission.observationSpeaking(reading, context: Self.good) == ["Priya Shah"])
  }

  @Test("SYNTHETIC: two guests named Alex make a talking Alex ambiguous")
  func duplicates() throws {
    let reading = try read([
      tile("Alex Rivera Unverified", talking: true), tile("Alex Rivera Unverified", talking: false),
    ])
    #expect(
      CallSpeakerAdmission.admission(of: reading, context: Self.good) == .withheld(.ambiguousTalker)
    )
  }

  @Test("SYNTHETIC: a tile nested inside another keeps its own frame")
  func nested() throws {
    let reading = try read([
      tile(
        "Alex Rivera Unverified", talking: false,
        inner: [tile("Priya Shah Unverified", talking: true)])
    ])
    #expect(CallSpeakerAdmission.observationSpeaking(reading, context: Self.good) == ["Priya Shah"])
  }
}
