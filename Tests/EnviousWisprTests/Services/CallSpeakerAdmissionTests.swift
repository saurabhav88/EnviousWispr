import Testing

@testable import EnviousWisprServices

/// #4013 r5 item 1: when these fail, a meeting can give a name to the wrong one of two people
/// who share it, lose an unnamed talker so someone else looks like the only one talking, or
/// count a cut-short or other-call capture as naming evidence.
///
/// Zoom and Teams trees reuse the labels captured in the C1 calls of 2026-10-28
/// (`docs/audits/2026-10-27-4013/c1a-receipt.txt`, `c1b-receipt.txt`, `c1t-receipt.txt`) as small
/// SURVEY trees; SYNTHETIC cases vary them.
@Suite("Call speaker admission", .tags(.productOutcome))
struct CallSpeakerAdmissionTests {
  typealias Admission = CallSpeakerAdmission

  private static let good = CallCaptureContext(completeness: .complete, scope: .resolved)

  private func window(_ title: String, _ children: [CallAXNode]) -> CallAXWindow {
    CallAXWindow(title: title, root: CallAXNode(role: "AXWindow", title: title, children: children))
  }

  private func zoomTile(_ label: String) -> CallAXNode {
    CallAXNode(role: "AXTabGroup", description: label)
  }

  private func zoom(_ tiles: [String]) -> CallSpeakerReading {
    ZoomAppSpeakerReader.read(windows: [window("Zoom Meeting", tiles.map(zoomTile))])
  }

  // MARK: - One person shown twice vs two people with one name

  @Test("SURVEY Zoom: the large tile repeating Alex is one person; Alex talking is admitted")
  func onePersonTwoViews() {
    let reading = zoom([
      "Alex Rivera, Computer audio unmuted",
      "Saurabh A Vaish, Computer audio muted, Video off",
      "Alex Rivera, Computer audio unmuted, Video off, active speaker",
    ])
    #expect(reading.participants.count == 2)
    #expect(Admission.admission(of: reading, context: Self.good) == .admitted)
    #expect(Admission.observationSpeaking(reading, context: Self.good) == ["Alex Rivera"])
  }

  @Test("SURVEY Zoom: two thumbnails named Alex are two people; Alex talking is withheld")
  func twoPeopleOneName() {
    let reading = zoom([
      "Saurabh A Vaish, Computer audio muted, Video off",
      "Alex Rivera, Computer audio unmuted, Video off, active speaker",
      "Alex Rivera, Computer audio muted, Video off",
    ])
    #expect(reading.participants.count == 3)
    #expect(Admission.admission(of: reading, context: Self.good) == .withheld(.ambiguousTalker))
    #expect(Admission.observationSpeaking(reading, context: Self.good) == nil)
  }

  @Test("SURVEY Zoom: a duplicated quiet name does not stop the unique talker")
  func unrelatedDuplicate() {
    let reading = zoom([
      "Alex Rivera, Computer audio muted, Video off",
      "Alex Rivera, Computer audio muted, Video off",
      "Priya Shah, Computer audio unmuted, Video off, active speaker",
    ])
    #expect(Admission.observationSpeaking(reading, context: Self.good) == ["Priya Shah"])
    #expect(reading.roster.names == ["Alex Rivera", "Alex Rivera", "Priya Shah"])
  }

  @Test("SYNTHETIC Zoom: a talking flag on a tile that is not a thumbnail withholds identity")
  func flagOutsideThumbnails() {
    let reading = zoom([
      "Priya Shah, Computer audio unmuted, active speaker",
      "Priya Shah, Computer audio unmuted, Video off",
    ])
    #expect(!reading.participantIdentityEstablished)
    #expect(
      Admission.admission(of: reading, context: Self.good) == .withheld(.identityUnestablished))
  }

  @Test("SURVEY Zoom panel: duplicate rows are evidence even when only one Alex tile shows")
  func panelDuplicates() {
    let panel = CallAXNode(
      role: "AXOutline", description: "Participants list",
      children: ["Saurabh A Vaish (Host, me)", "Alex Rivera", "Alex Rivera"].map {
        CallAXNode(role: "AXRow", children: [CallAXNode(role: "AXStaticText", value: $0)])
      })
    let reading = ZoomAppSpeakerReader.read(windows: [
      window(
        "Zoom Meeting",
        [
          zoomTile("Saurabh A Vaish, Computer audio muted, Video off"),
          zoomTile("Alex Rivera, Computer audio unmuted, Video off, active speaker"),
          CallAXNode(role: "AXStaticText", value: "Participants (3)"),
          panel,
        ])
    ])
    #expect(reading.rosterFromParticipantList, "provenance stays factual")
    #expect(reading.sharedNames == ["Alex Rivera"])
    #expect(Admission.admission(of: reading, context: Self.good) == .withheld(.ambiguousTalker))
  }

  // MARK: - Self and partial rosters

  @Test("SURVEY Teams: the user plus one remote talker, from a partial gallery, is admitted")
  func selfPlusOneFromPartialRoster() {
    let reading = TeamsAppSpeakerReader.read(windows: [
      window(
        "Meeting compact view | Meeting with Saurabh Vaish",
        [CallAXNode(role: "AXGroup", description: "Alex Rivera (Guest) is speaking")]),
      window(
        "Meeting with Saurabh Vaish",
        [
          CallAXNode(
            role: "AXMenuItem", description: "Myself video, Saurabh Vaish, Muted, Has context menu"),
          CallAXNode(
            role: "AXMenuItem", description: "Alex Rivera (Guest), Context menu is available"),
        ]),
    ])
    #expect(!reading.rosterFromParticipantList, "no People list: provenance says so")
    #expect(Admission.observationSpeaking(reading, context: Self.good) == ["Alex Rivera"])
  }

  @Test("SURVEY Teams: two roster rows with one name make that talker ambiguous")
  func teamsDuplicateRows() {
    let reading = TeamsAppSpeakerReader.read(windows: [
      window(
        "Meeting with Saurabh Vaish",
        [
          CallAXNode(role: "AXRow", description: "Alex Rivera (Guest), Meeting guest, Muted"),
          CallAXNode(role: "AXRow", description: "Alex Rivera (Guest), Meeting guest, Unmuted"),
          CallAXNode(role: "AXGroup", description: "Alex Rivera (Guest) is speaking"),
        ])
    ])
    #expect(Admission.admission(of: reading, context: Self.good) == .withheld(.ambiguousTalker))
    #expect(reading.roster.names == ["Alex Rivera", "Alex Rivera"], "suggestions stay")
  }

  // MARK: - Unnamed talkers

  @Test("SYNTHETIC rules: an unnamed talking tile is kept and withholds the reading")
  func unnamedTalker() {
    let reading = CallSpeakerReading(
      speaking: [], roster: .init(names: ["Priya Shah"], selfNames: []),
      rosterFromParticipantList: false,
      participants: [
        CallParticipant(key: "a", name: nil, isTalking: true, isSelf: false),
        CallParticipant(key: "b", name: "Priya Shah", isTalking: true, isSelf: false),
      ],
      participantIdentityEstablished: true, sharedNames: [])
    #expect(Admission.admission(of: reading, context: Self.good) == .withheld(.unnamedTalker))
  }

  // MARK: - Capture context

  @Test("every incomplete, unreadable, unknown or unresolved capture withholds naming")
  func captureContext() {
    let reading = zoom(["Alex Rivera, Computer audio unmuted, Video off, active speaker"])
    let cases: [(CallCaptureContext, CallNamingAdmission.Reason)] = [
      (.init(completeness: .truncated, scope: .resolved), .captureTruncated),
      (.init(completeness: .unreadable, scope: .resolved), .captureUnreadable),
      (.init(completeness: .unknown, scope: .resolved), .completenessUnknown),
      (.init(completeness: .complete, scope: .unresolved), .callScopeUnresolved),
      (.init(completeness: .complete, scope: .unknown), .callScopeUnresolved),
    ]
    for (context, reason) in cases {
      #expect(Admission.admission(of: reading, context: context) == .withheld(reason), "\(reason)")
      #expect(Admission.observationSpeaking(reading, context: context) == nil)
    }
  }

  @Test("SYNTHETIC Teams: rosters in two windows (competing calls) establish no identity")
  func competingRosters() {
    let row = CallAXNode(role: "AXRow", description: "Alex Rivera (Guest), Meeting guest, Muted")
    let reading = TeamsAppSpeakerReader.read(windows: [
      window(
        "Meeting with A",
        [row, CallAXNode(role: "AXGroup", description: "Alex Rivera (Guest) is speaking")]),
      window("Meeting with B", [row]),
    ])
    #expect(
      Admission.admission(of: reading, context: Self.good) == .withheld(.identityUnestablished))
  }

  // MARK: - Quiet vs withheld, and surfaces without identity yet

  @Test("a valid quiet reading is an empty observation; a withheld one is none")
  func quietVersusWithheld() {
    let quiet = zoom([
      "Alex Rivera, Computer audio muted, Video off", "Priya Shah, Computer audio muted, Video off",
    ])
    #expect(Admission.observationSpeaking(quiet, context: Self.good) == [])
    #expect(
      Admission.observationSpeaking(
        quiet, context: .init(completeness: .truncated, scope: .resolved)) == nil)
  }

  @Test("rules and Zoom web readings keep their roster but never name anyone until step 3")
  func identityNotYetEstablished() {
    let rule = SpeakerSelectorRule.unconfigured(.meet)
    let reading = RulesSpeakerReader.read(root: CallAXNode(role: "AXApplication"), rule: rule)
    #expect(!reading.participantIdentityEstablished)
    #expect(
      Admission.admission(of: reading, context: Self.good) == .withheld(.identityUnestablished))
  }
}
