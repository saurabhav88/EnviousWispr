import EnviousWisprCore
import Testing

@testable import EnviousWisprServices

/// #4013: when these fail, a Meet, Teams web or Slack call names the wrong tile as talking, a
/// rule nobody checked names people, or a roster-only app claims to know who talked.
///
/// Fixture provenance: the Meet talking token `kssMZb` and the container token `dkjMxf` were seen
/// on the 2026-10-27 Meet call (`docs/audits/2026-10-27-4013/meet-chrome-names-findings.md`);
/// the Teams web tile label `<Name> Unverified` on the Teams web call
/// (`teams-web-names-findings.md`); the Slack tokens are Wispr Flow's defaults
/// in its shipped app, never seen
/// here. Every tree shape is SYNTHETIC: the captures did not record full tile hierarchies.
@Suite("Rules speaker reader", .tags(.productOutcome))
struct RulesSpeakerReaderTests {

  private let meetURL = "https://meet.google.com/eod-yjir-ufc"
  private let meetRule = SpeakerSelectorRule(
    surface: .meet, tileRole: nil, tileClass: "dkjMxf", nameSource: .firstStaticText,
    talkingClasses: ["kssMZb"], participantListClass: nil, verification: .verified)

  private func meetTile(_ name: String?, talking: Bool = false, extra: [CallAXNode] = [])
    -> CallAXNode
  {
    CallAXNode(
      role: "AXGroup", domClassList: talking ? ["dkjMxf", "kssMZb"] : ["dkjMxf"],
      children: (name.map { [CallAXNode(role: "AXStaticText", value: $0)] } ?? []) + extra)
  }

  private func page(_ url: String?, _ children: [CallAXNode]) -> CallAXDocument {
    CallAXDocument(url: url, root: CallAXNode(role: "AXWebArea", children: children))
  }

  @Test("a verified rule names the tile carrying the talking token; every tile is on the roster")
  func meetTalker() throws {
    let reading = try #require(
      RulesSpeakerReader.read(
        documents: [
          page(
            meetURL,
            [
              meetTile("Saurabh Vaish"), meetTile("Alex Rivera", talking: true),
              meetTile("Priya Shah"),
            ])
        ], rule: meetRule))
    #expect(reading.speaking == ["Alex Rivera"])
    #expect(reading.roster.names == ["Saurabh Vaish", "Alex Rivera", "Priya Shah"])
    #expect(reading.roster.selfNames.isEmpty)
    #expect(!reading.rosterFromParticipantList)
  }

  @Test("an unverified rule reads names but never a talker")
  func unverifiedRule() throws {
    let rule = SpeakerSelectorRule(
      surface: .meet, tileRole: nil, tileClass: "dkjMxf", nameSource: .firstStaticText,
      talkingClasses: ["kssMZb"], participantListClass: nil, verification: .unverified)
    let reading = try #require(
      RulesSpeakerReader.read(
        documents: [
          page(meetURL, [meetTile("Alex Rivera", talking: true), meetTile("Priya Shah")])
        ], rule: rule))
    #expect(reading.speaking.isEmpty)
    #expect(reading.roster.names == ["Alex Rivera", "Priya Shah"])
  }

  @Test("tokens match exactly; simultaneous talkers are all kept")
  func exactTokensAndSimultaneous() throws {
    let lookalike = CallAXNode(
      role: "AXGroup", domClassList: ["dkjMxf", "kssMZbX"],
      children: [CallAXNode(role: "AXStaticText", value: "Dana Lee")])
    let reading = try #require(
      RulesSpeakerReader.read(
        documents: [
          page(
            meetURL,
            [
              meetTile("Alex Rivera", talking: true), lookalike,
              meetTile("Priya Shah", talking: true),
            ])
        ], rule: meetRule))
    #expect(reading.speaking == ["Alex Rivera", "Priya Shah"])
  }

  @Test("a talking signal never borrows another tile's name; an unnamed talker cancels the scan's talkers")
  func tileNameAssociation() throws {
    // A nameless talking tile, and a talking token on a tile nested inside a named tile.
    let nested = meetTile("Outer Name", extra: [meetTile(nil, talking: true)])
    let reading = try #require(
      RulesSpeakerReader.read(
        documents: [
          page(meetURL, [meetTile(nil, talking: true), nested, meetTile("Priya Shah", talking: true)])
        ], rule: meetRule))
    #expect(reading.speaking.isEmpty)
    #expect(reading.roster.names == ["Outer Name", "Priya Shah"])
  }

  @Test("a single participant list keeps its duplicates; two lists fall back to tiles")
  func participantList() throws {
    let rule = SpeakerSelectorRule(
      surface: .meet, tileRole: nil, tileClass: "dkjMxf", nameSource: .firstStaticText,
      talkingClasses: ["kssMZb"], participantListClass: "people-list", verification: .verified)
    func list() -> CallAXNode {
      CallAXNode(
        role: "AXList", domClassList: ["people-list"],
        children: ["Alex Rivera", "Alex Rivera", "Priya Shah"].map { name in
          CallAXNode(role: "AXGroup", children: [CallAXNode(role: "AXStaticText", value: name)])
        })
    }
    let one = try #require(
      RulesSpeakerReader.read(
        documents: [page(meetURL, [list(), meetTile("Alex Rivera"), meetTile("Alex Rivera")])], rule: rule))
    #expect(one.roster.names == ["Alex Rivera", "Alex Rivera", "Priya Shah"])
    #expect(one.rosterFromParticipantList)

    let two = try #require(
      RulesSpeakerReader.read(
        documents: [
          page(meetURL, [list(), list(), meetTile("Alex Rivera"), meetTile("Alex Rivera")])
        ], rule: rule))
    #expect(two.roster.names == ["Alex Rivera"])
    #expect(!two.rosterFromParticipantList)
  }

  @Test("Teams web: the tile label drops its exact Unverified suffix and nothing else")
  func teamsWebNames() throws {
    let rule = SpeakerSelectorRule(
      surface: .teamsWeb, tileRole: "AXMenuItem", tileClass: nil,
      nameSource: .ownLabel(removingSuffix: " Unverified"), talkingClasses: [],
      participantListClass: nil, verification: .unverified)
    let reading = try #require(
      RulesSpeakerReader.read(
        documents: [
          page(
            "https://teams.live.com/meet/9379651200261?p=x",
            [
              CallAXNode(role: "AXMenuItem", title: "Alex Rivera Unverified"),
              CallAXNode(role: "AXMenuItem", title: "Lee, Dana (Unverified Co.)"),
            ])
        ], rule: rule))
    #expect(reading.roster.names == ["Alex Rivera", "Lee, Dana (Unverified Co.)"])
    #expect(reading.speaking.isEmpty)
  }

  @Test("a roster-only surface never reports a talker, even with a verified talking token")
  func rosterOnly() throws {
    let rule = SpeakerSelectorRule(
      surface: .webex, tileRole: nil, tileClass: "tile", nameSource: .firstStaticText,
      talkingClasses: ["speaking"], participantListClass: nil, verification: .verified)
    let window = CallAXWindow(
      title: "Webex",
      root: CallAXNode(
        role: "AXWindow",
        children: [
          CallAXNode(
            role: "AXGroup", domClassList: ["tile", "speaking"],
            children: [CallAXNode(role: "AXStaticText", value: "Alex Rivera")])
        ]))
    let reading = try #require(RulesSpeakerReader.read(windows: [window], rule: rule))
    #expect(reading.speaking.isEmpty)
    #expect(reading.roster.names == ["Alex Rivera"])
  }

  @Test("an unconfigured surface reads nothing")
  func unconfigured() throws {
    let window = CallAXWindow(
      title: "FaceTime",
      root: CallAXNode(
        role: "AXWindow", children: [CallAXNode(role: "AXStaticText", value: "Alex Rivera")]))
    let reading = try #require(RulesSpeakerReader.read(windows: [window], rule: .unconfigured(.facetime)))
    #expect(reading.speaking.isEmpty)
    #expect(reading.roster.names.isEmpty)
  }

  @Test("Slack: competitor tokens stay unverified, so names only")
  func slackUnverified() throws {
    let rule = SpeakerSelectorRule(
      surface: .slackWeb, tileRole: nil, tileClass: "p-huddle_peer_tile",
      nameSource: .firstStaticText,
      talkingClasses: ["p-huddle_peer_tile__overlay--active_speaker"],
      participantListClass: nil, verification: .unverified)
    let tile = CallAXNode(
      role: "AXGroup", domClassList: ["p-huddle_peer_tile"],
      children: [
        CallAXNode(role: "AXStaticText", value: "Alex Rivera"),
        CallAXNode(role: "AXGroup", domClassList: ["p-huddle_peer_tile__overlay--active_speaker"]),
      ])
    let reading = try #require(
      RulesSpeakerReader.read(
        documents: [page("https://app.slack.com/huddle/T1/C1", [tile])], rule: rule)
    )
    #expect(reading.speaking.isEmpty)
    #expect(reading.roster.names == ["Alex Rivera"])
  }

  @Test("only the single matching call page is read")
  func documentSelection() {
    let call = page(meetURL, [meetTile("Alex Rivera", talking: true)])
    let other = page("https://example.com/notes", [meetTile("Somebody Else", talking: true)])
    let secondCall = page("https://meet.google.com/abc-defg-hij", [meetTile("Dana Lee")])
    #expect(
      RulesSpeakerReader.read(documents: [other, call], rule: meetRule)?
        .roster.names == ["Alex Rivera"])
    #expect(
      RulesSpeakerReader.read(documents: [call, secondCall], rule: meetRule)
        == nil)
    #expect(RulesSpeakerReader.read(documents: [other], rule: meetRule) == nil)
  }

  @Test("a list with an unreadable entry or an entry with two names is not trusted")
  func doubtfulParticipantList() throws {
    let rule = SpeakerSelectorRule(
      surface: .meet, tileRole: nil, tileClass: "dkjMxf", nameSource: .firstStaticText,
      talkingClasses: ["kssMZb"], participantListClass: "people-list", verification: .verified)
    let entry = { (texts: [String]) in
      CallAXNode(role: "AXGroup", children: texts.map { CallAXNode(role: "AXStaticText", value: $0) })
    }
    for badEntry in [entry([]), entry(["Alex Rivera", "Presenting"])] {
      let list = CallAXNode(
        role: "AXList", domClassList: ["people-list"], children: [entry(["Priya Shah"]), badEntry])
      let reading = try #require(
        RulesSpeakerReader.read(
          documents: [page(meetURL, [list, meetTile("Priya Shah"), meetTile("Alex Rivera")])],
          rule: rule))
      #expect(reading.roster.names == ["Priya Shah", "Alex Rivera"])
      #expect(!reading.rosterFromParticipantList)
    }
  }

  @Test("a rule reads only its own surface's pages, and app and web rules use their own entry")
  func surfaceAndEntrypoint() {
    let teamsPage = page("https://teams.live.com/meet/9379651200261?p=x", [meetTile("Alex Rivera")])
    #expect(RulesSpeakerReader.read(documents: [teamsPage], rule: meetRule) == nil)

    let slackWeb = SpeakerSelectorRule(
      surface: .slackWeb, tileRole: nil, tileClass: "p-huddle_peer_tile", nameSource: .firstStaticText,
      talkingClasses: [], participantListClass: nil, verification: .unverified)
    let slackApp = SpeakerSelectorRule(
      surface: .slackApp, tileRole: nil, tileClass: "p-huddle_peer_tile", nameSource: .firstStaticText,
      talkingClasses: [], participantListClass: nil, verification: .unverified)
    let window = CallAXWindow(title: "Huddle", root: CallAXNode(role: "AXWindow"))
    #expect(RulesSpeakerReader.read(windows: [window], rule: slackWeb) == nil)
    #expect(RulesSpeakerReader.read(windows: [window], rule: slackApp) != nil)
    let slackPage = page("https://app.slack.com/huddle/T1/C1", [])
    #expect(RulesSpeakerReader.read(documents: [slackPage], rule: slackApp) == nil)
    #expect(RulesSpeakerReader.read(documents: [slackPage], rule: slackWeb) != nil)
  }
}
