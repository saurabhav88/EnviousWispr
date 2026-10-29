import EnviousWisprCore
import Testing

@testable import EnviousWisprServices

/// #4013: when these fail, a Zoom or Teams call shows the wrong person as talking, the user's
/// own name lands on someone else, or a role is mistaken for the user.
///
/// Fixture provenance: trees marked SURVEY reuse the exact labels and roles read from real calls
/// on 2026-10-27 (`docs/audits/2026-10-27-4013/zoom-mac-names-findings.md`,
/// `teams-mac-names-findings.md`), rebuilt as small trees; they are not raw captures. Trees marked
/// SYNTHETIC vary those labels to cover cases the calls did not show.
@Suite("Native call speaker readers", .tags(.productOutcome))
struct NativeCallSpeakerReaderTests {

  private func window(_ title: String?, _ children: [CallAXNode]) -> CallAXWindow {
    CallAXWindow(title: title, root: CallAXNode(role: "AXWindow", title: title, children: children))
  }

  private func zoomTile(_ label: String) -> CallAXNode {
    CallAXNode(role: "AXTabGroup", description: label)
  }

  // MARK: - Zoom

  /// SURVEY: Speaker view with three people, Alex talking.
  @Test("Zoom: the tile marked active speaker is the talker, and every tile is on the roster")
  func zoomActiveSpeaker() {
    let reading = ZoomAppSpeakerReader.read(windows: [
      window(
        "Zoom Meeting  40-minutes",
        [
          zoomTile("Alex Rivera, Computer audio unmuted"),
          zoomTile("Saurabh A Vaish, Computer audio muted, Video off"),
          zoomTile("Priya Shah, Computer audio muted, Video off"),
          zoomTile("Alex Rivera, Computer audio unmuted, Video off, active speaker"),
        ])
    ])
    #expect(reading.speaking == ["Alex Rivera"])
    // The thumbnails are the people, in their order; the large tile repeats Alex.
    #expect(reading.roster.names == ["Saurabh A Vaish", "Priya Shah", "Alex Rivera"])
    #expect(reading.roster.selfNames.isEmpty)
    #expect(!reading.rosterFromParticipantList)
  }

  /// SURVEY: the large Speaker-view tile names the last talker but carries no flag, and in the
  /// quiet sample nobody was flagged.
  @Test("Zoom: with no active-speaker flag nobody is talking, even on the large tile")
  func zoomQuiet() {
    let reading = ZoomAppSpeakerReader.read(windows: [
      window(
        "Zoom Meeting",
        [
          zoomTile("Alex Rivera, Computer audio unmuted"),
          zoomTile("Alex Rivera, Computer audio unmuted, Video off"),
          zoomTile("Saurabh A Vaish, No audio connected, Video off"),
        ])
    ])
    #expect(reading.speaking.isEmpty)
    #expect(reading.roster.names == ["Alex Rivera", "Saurabh A Vaish"])
  }

  /// SURVEY label for the participants panel; SYNTHETIC "(Host)" without "me".
  @Test("Zoom: only an explicit (me) marks the user; Host alone does not")
  func zoomSelf() {
    let reading = ZoomAppSpeakerReader.read(windows: [
      window(
        "Zoom Meeting",
        [
          CallAXNode(role: "AXStaticText", value: "Saurabh A Vaish (Host, me)"),
          CallAXNode(role: "AXStaticText", value: "Dana Lee (Host)"),
          CallAXNode(role: "AXStaticText", value: "Priya Shah"),
        ])
    ])
    #expect(reading.roster.selfNames == ["Saurabh A Vaish"])
    // Texts outside the "Participants list" outline are not a roster.
    #expect(reading.roster.names.isEmpty)
    #expect(!reading.rosterFromParticipantList)
  }

  /// SURVEY (C1a, 2026-10-28): the open participants panel with four people, two of them named
  /// "Alex Rivera", beside the Speaker-view tiles.
  private func zoomPanel(entries: [String], counts: [String]) -> CallAXWindow {
    window(
      "Zoom Meeting  40-minutes",
      [
        zoomTile("Priya Shah, Computer audio unmuted"),
        zoomTile("Saurabh A Vaish, Computer audio muted, Video off"),
        zoomTile("Alex Rivera, Computer audio muted, Video off"),
        zoomTile("Alex Rivera, Computer audio muted, Video off"),
        zoomTile("Priya Shah, Computer audio unmuted, Video off, active speaker"),
      ]
        + counts.map { CallAXNode(role: "AXStaticText", value: $0) }
        + [
          CallAXNode(
            role: "AXOutline", description: "Participants list",
            children: entries.map { entry in
              CallAXNode(
                role: "AXRow",
                children: [
                  CallAXNode(role: "AXStaticText", value: entry),
                  CallAXNode(
                    role: "AXMenuButton",
                    description: "More options for \(entry), collapsed"),
                ])
            })
        ])
  }

  @Test("Zoom: an open, complete participants panel is the roster, duplicates kept")
  func zoomParticipantsPanel() {
    let reading = ZoomAppSpeakerReader.read(windows: [
      zoomPanel(
        entries: ["Saurabh A Vaish (Host, me)", "Alex Rivera", "Alex Rivera", "Priya Shah"],
        counts: ["Participants (4)", "Participants (4)"])
    ])
    #expect(reading.rosterFromParticipantList)
    #expect(
      reading.roster.names == ["Saurabh A Vaish", "Alex Rivera", "Alex Rivera", "Priya Shah"])
    #expect(reading.roster.selfNames == ["Saurabh A Vaish"])
    #expect(reading.speaking == ["Priya Shah"])
  }

  /// SYNTHETIC: a panel Zoom draws only partly, a panel with no count, and two counts that
  /// disagree. None of them is a complete list, so the tiles' roster is kept and flagged.
  @Test("Zoom: an incomplete or uncounted panel is not the participant list")
  func zoomIncompletePanel() {
    let entries = ["Saurabh A Vaish (Host, me)", "Alex Rivera", "Priya Shah"]
    for counts in [["Participants (12)"], [], ["Participants (3)", "Participants (4)"]] {
      let reading = ZoomAppSpeakerReader.read(windows: [zoomPanel(entries: entries, counts: counts)])
      #expect(!reading.rosterFromParticipantList, "\(counts)")
      // The thumbnails keep both people named Alex Rivera; the large tile repeats Priya.
      #expect(
        reading.roster.names == ["Saurabh A Vaish", "Alex Rivera", "Alex Rivera", "Priya Shah"])
    }
  }

  /// SYNTHETIC: two different lists with equal counts, in either order, and a count shown only
  /// in another window. None identifies one complete list, so the tiles' roster is kept.
  @Test("Zoom: two lists, or a count from another window, are not the participant list")
  func zoomAmbiguousPanels() {
    let a = zoomPanel(
      entries: ["Saurabh A Vaish (Host, me)", "Alex Rivera", "Priya Shah"],
      counts: ["Participants (3)"])
    let b = zoomPanel(
      entries: ["Saurabh A Vaish (Host, me)", "Dana Lee", "Ben Ode"],
      counts: ["Participants (3)"])
    for windows in [[a, b], [b, a]] {
      #expect(!ZoomAppSpeakerReader.read(windows: windows).rosterFromParticipantList)
    }
    let uncounted = zoomPanel(
      entries: ["Saurabh A Vaish (Host, me)", "Alex Rivera", "Priya Shah"], counts: [])
    let countElsewhere = window("Zoom", [CallAXNode(role: "AXStaticText", value: "Participants (3)")])
    #expect(
      !ZoomAppSpeakerReader.read(windows: [uncounted, countElsewhere]).rosterFromParticipantList)
  }

  // MARK: - Zoom head count (#4013 chunk 14)

  @Test("Zoom: the closed-panel button's count is read only in its observed shape")
  func zoomClosedPanelCount() {
    #expect(ZoomAppSpeakerReader.closedPanelCount("Open participants panel, closed, 4 participants") == 4)
    #expect(ZoomAppSpeakerReader.closedPanelCount("Open participants panel, closed, 1 participant") == 1)
    for text in [
      "Open participants panel, closed, 2 participant", "Open participants panel, closed, 1 participants",
      "Open participants panel, closed, participants", "Participants, 2",
      "Ouvrir le panneau des participants, fermé, 2 participants",
      "Open participants panel, closed, 2 participants, 3 waiting",
    ] {
      #expect(ZoomAppSpeakerReader.closedPanelCount(text) == nil, "\(text)")
    }
  }

  private func zoomOneOnOne(button: String?, extra: [CallAXNode] = []) -> CallAXWindow {
    window(
      "Zoom Meeting",
      [
        zoomTile("Saurabh A Vaish, Computer audio muted, Video off"),
        zoomTile("Alex Rivera, Computer audio unmuted, Video off"),
      ] + (button.map { [CallAXNode(role: "AXButton", description: $0)] } ?? []) + extra)
  }

  @Test("Zoom: with the panel closed the button's count is the call's head count")
  func zoomHeadCount() {
    let closed = ZoomAppSpeakerReader.read(windows: [
      zoomOneOnOne(button: "Open participants panel, closed, 2 participants")
    ])
    #expect(closed.participantCount == 2)
    #expect(CallSpeakerAccumulator.pairEvidence(closed)?.names == ["Saurabh A Vaish", "Alex Rivera"])
    #expect(closed.roster.selfNames.isEmpty, "a closed panel never marks the user")
    #expect(ZoomAppSpeakerReader.read(windows: [zoomOneOnOne(button: nil)]).participantCount == nil)
    // Two buttons that disagree.
    let twoCounts = zoomOneOnOne(
      button: "Open participants panel, closed, 2 participants",
      extra: [CallAXNode(role: "AXButton", description: "Open participants panel, closed, 3 participants")])
    #expect(ZoomAppSpeakerReader.read(windows: [twoCounts]).participantCount == nil)
  }

  @Test("Zoom: an open panel's count stands only when the list matches it and the button agrees")
  func zoomPanelHeadCount() {
    let entries = ["Saurabh A Vaish (Host, me)", "Alex Rivera"]
    #expect(
      ZoomAppSpeakerReader.read(windows: [zoomPanel(entries: entries, counts: ["Participants (2)"])])
        .participantCount == 2)
    // A list that does not match its own count leaves the head count unknown, button or not.
    let partial = zoomPanel(entries: entries, counts: ["Participants (3)"])
    #expect(ZoomAppSpeakerReader.read(windows: [partial]).participantCount == nil)
    let disagreeing = window(
      "Zoom Meeting",
      zoomPanel(entries: entries, counts: ["Participants (2)"]).root.children + [
        CallAXNode(role: "AXButton", description: "Open participants panel, closed, 3 participants")
      ])
    #expect(ZoomAppSpeakerReader.read(windows: [disagreeing]).participantCount == nil)
  }

  @Test("Zoom: a header count with no list beside it must agree with the button")
  func zoomHeaderAndButtonDisagree() {
    let window = zoomOneOnOne(
      button: "Open participants panel, closed, 2 participants",
      extra: [CallAXNode(role: "AXStaticText", value: "Participants (3)")])
    #expect(ZoomAppSpeakerReader.read(windows: [window]).participantCount == nil)
  }

  @Test("Teams: the complete list's count stands only when no window of the call shows another")
  func teamsHeadCount() {
    let rows = ["Saurabh Vaish, Organizer, Muted", "Alex Rivera (Guest), Meeting guest, Muted"]
    let complete = teamsRoster(rows, counts: ["In this meeting, 2 total"])
    #expect(TeamsAppSpeakerReader.read(windows: [complete]).participantCount == 2)
    let otherWindow = window(
      "Meeting compact view | Meeting with Saurabh Vaish",
      [CallAXNode(role: "AXGroup", description: "In this meeting, 3 total")])
    #expect(TeamsAppSpeakerReader.read(windows: [complete, otherWindow]).participantCount == nil)
    #expect(
      TeamsAppSpeakerReader.read(windows: [teamsRoster(rows, counts: [])]).participantCount == nil)
  }

  @Test("Teams: a quiet tile this reader cannot parse never hides a third person")
  func teamsUnparsedTile() {
    let rows = ["Saurabh Vaish, Organizer, Muted", "Alex Rivera (Guest), Meeting guest, Muted"]
    let unknownTile = CallAXNode(role: "AXMenuItem", description: "Someone, a state never seen")
    // With the complete, counted list, the list is everyone: the app itself says two.
    let listed = TeamsAppSpeakerReader.read(windows: [
      window(
        "Meeting with Saurabh Vaish",
        [CallAXNode(role: "AXGroup", description: "In this meeting, 2 total")]
          + rows.map { CallAXNode(role: "AXRow", description: $0) } + [unknownTile])
    ])
    #expect(listed.participantCount == 2)
    // Without the list there is no count, so the tiles alone never make a two-person stretch.
    let tilesOnly = TeamsAppSpeakerReader.read(windows: [
      window(
        "Meeting with Saurabh Vaish",
        [
          CallAXNode(role: "AXMenuItem", description: "Myself video, Saurabh Vaish, Muted"),
          CallAXNode(role: "AXMenuItem", description: "Alex Rivera, Context menu is available"),
          unknownTile,
        ])
    ])
    #expect(tilesOnly.participantCount == nil)
    #expect(CallSpeakerAccumulator.pairEvidence(tilesOnly) == nil)
  }

  @Test("Zoom: only Zoom's own tags are taken off a panel entry")
  func zoomPanelEntry() {
    #expect(ZoomAppSpeakerReader.panelEntry("Saurabh A Vaish (Host, me)").name == "Saurabh A Vaish")
    #expect(ZoomAppSpeakerReader.panelEntry("Dana Lee (Co-host)").name == "Dana Lee")
    #expect(ZoomAppSpeakerReader.panelEntry("Dana (Design)").name == "Dana (Design)")
    #expect(ZoomAppSpeakerReader.panelEntry("(Host)").name == "(Host)")
    #expect(ZoomAppSpeakerReader.participantCount("Participants (4)") == 4)
    for text in ["Participants ()", "Participants (four)", "Participants (4", "Attendees (4)"] {
      #expect(ZoomAppSpeakerReader.participantCount(text) == nil, "\(text)")
    }
  }

  /// SYNTHETIC: a name with a comma, two people flagged at once, and look-alike labels outside a
  /// participant tile.
  @Test("Zoom: commas in names survive, simultaneous talkers are all kept, other labels ignored")
  func zoomEdges() {
    let reading = ZoomAppSpeakerReader.read(windows: [
      window(
        "Zoom Meeting",
        [
          zoomTile("Lee, Dana, Computer audio unmuted, Video off, active speaker"),
          zoomTile("Priya Shah, Computer audio unmuted, Video off, active speaker"),
          CallAXNode(
            role: "AXButton", description: "Alex Rivera, Computer audio unmuted, active speaker"),
          zoomTile("View options, Speaker"),
        ])
    ])
    #expect(reading.speaking == ["Lee, Dana", "Priya Shah"])
    #expect(reading.roster.names == ["Lee, Dana", "Priya Shah"])
  }

  /// SYNTHETIC: a name containing look-alike status words, an unknown ending, and one person
  /// shown as thumbnail and large tile.
  @Test("Zoom: the name is read from Zoom's fixed ending, an unknown ending is skipped")
  func zoomStructuralSuffix() {
    let reading = ZoomAppSpeakerReader.read(windows: [
      window(
        "Zoom Meeting",
        [
          zoomTile("Dana, Computer audio engineer, Computer audio unmuted, Video off, active speaker"),
          zoomTile("Priya Shah, Computer audio muted, Video off, Hand raised"),
          zoomTile("Alex Rivera, Computer audio unmuted"),
          zoomTile("Alex Rivera, Computer audio unmuted, Video off"),
        ])
    ])
    #expect(reading.speaking == ["Dana, Computer audio engineer"])
    #expect(reading.roster.names == ["Dana, Computer audio engineer", "Alex Rivera"])
  }

  // MARK: - Teams

  /// SURVEY: the compact meeting view while Alex talks, plus the main window's roster rows and
  /// the user's own tile.
  @Test("Teams: 'is speaking' names the talker; roster rows give names without the guest tag")
  func teamsSpeaking() {
    let reading = TeamsAppSpeakerReader.read(windows: [
      window(
        "Meeting compact view | Meeting with Saurabh Vaish",
        [
          CallAXNode(
            role: "AXGroup", title: "Alex Rivera (Guest) is speaking",
            description: "Alex Rivera (Guest) is speaking")
        ]),
      window(
        "Meeting with Saurabh Vaish",
        [
          CallAXNode(role: "AXRow", description: "In this meeting, 3 total Mute all"),
          CallAXNode(role: "AXRow", description: "Saurabh Vaish, Organizer, Muted"),
          CallAXNode(role: "AXRow", description: "Alex Rivera (Guest), Meeting guest, Muted"),
          CallAXNode(role: "AXRow", description: "Priya Shah (Guest), Meeting guest, Muted"),
          CallAXNode(
            role: "AXMenuItem", description: "Myself video, Saurabh Vaish, Muted, Has context menu"),
          CallAXNode(
            role: "AXMenuItem", description: "Alex Rivera (Guest), muted, Context menu is available"
          ),
        ]),
    ])
    #expect(reading.speaking == ["Alex Rivera"])
    #expect(reading.roster.names == ["Saurabh Vaish", "Alex Rivera", "Priya Shah"])
    #expect(reading.roster.selfNames == ["Saurabh Vaish"])
    #expect(reading.rosterFromParticipantList)
  }

  private func teamsRoster(_ rows: [String], counts: [String], title: String = "Meeting with Saurabh Vaish")
    -> CallAXWindow
  {
    window(
      title,
      counts.map { CallAXNode(role: "AXGroup", description: $0) }
        + rows.map { CallAXNode(role: "AXRow", description: $0) })
  }

  /// SURVEY (C1 Teams run, 2026-10-28): four people, two named "Alex Rivera", counted
  /// "In this meeting, 4 total". SYNTHETIC: partial, uncounted, conflicting, elsewhere-counted
  /// and doubled lists.
  @Test("Teams: only one counted, complete roster is the participant list; names stay either way")
  func teamsRosterCompleteness() {
    let rows = [
      "Saurabh Vaish, Organizer, Muted", "Alex Rivera (Guest), Meeting guest, Muted",
      "Alex Rivera (Guest), Meeting guest, Unmuted", "Priya Shah (Guest), Meeting guest, Muted",
    ]
    let complete = TeamsAppSpeakerReader.read(windows: [
      teamsRoster(rows, counts: ["In this meeting, 4 total", "In this meeting, 4 total Mute all"])
    ])
    #expect(complete.rosterFromParticipantList)
    #expect(complete.roster.names == ["Saurabh Vaish", "Alex Rivera", "Alex Rivera", "Priya Shah"])

    let incomplete: [[CallAXWindow]] = [
      [teamsRoster(rows, counts: ["In this meeting, 12 total"])],
      [teamsRoster(rows, counts: [])],
      [teamsRoster(rows, counts: ["In this meeting, 4 total", "In this meeting, 5 total"])],
      [teamsRoster(rows, counts: []), window("Other", [CallAXNode(role: "AXGroup", description: "In this meeting, 4 total")])],
      [teamsRoster(rows, counts: ["In this meeting, 4 total"]), teamsRoster(rows, counts: ["In this meeting, 4 total"], title: "Second")],
    ]
    for windows in incomplete {
      let reading = TeamsAppSpeakerReader.read(windows: windows)
      #expect(!reading.rosterFromParticipantList)
      #expect(reading.roster.names.contains("Priya Shah"), "names stay for suggestions")
    }
    #expect(TeamsAppSpeakerReader.meetingCount("In this meeting, 3 total Mute all") == 3)
    for text in ["In this meeting, total", "In this meeting, 3 totally", "In the lobby, 2 total", "In this meeting, 3 total Admit all"] {
      #expect(TeamsAppSpeakerReader.meetingCount(text) == nil, "\(text)")
    }
  }

  /// SURVEY (C1 Teams run 2, 2026-10-28): in the main window the talker's gallery tile holds a
  /// frame group with class `vdi-frame-occlusion`; quiet tiles hold none.
  @Test("Teams: the main window's talking frame names the talker on its gallery tile")
  func teamsMainWindowFrame() {
    func tile(_ label: String, talking: Bool) -> CallAXNode {
      CallAXNode(
        role: "AXMenuItem", description: label,
        children: [
          CallAXNode(role: "AXGroup", domClassList: talking ? ["fui-Flex", "vdi-frame-occlusion"] : ["fui-Flex", "vdi-occlusion"])
        ])
    }
    let reading = TeamsAppSpeakerReader.read(windows: [
      window(
        "Meeting with Saurabh Vaish",
        [
          tile("Alex Rivera (Guest), muted, Context menu is available", talking: false),
          tile("Priya Shah (Guest), Context menu is available", talking: true),
          CallAXNode(
            role: "AXMenuItem", description: "Myself video, Saurabh Vaish, Muted, Has context menu"),
        ])
    ])
    #expect(reading.speaking == ["Priya Shah"])
    #expect(reading.roster.selfNames == ["Saurabh Vaish"])
    let good = CallCaptureContext(completeness: .complete, scope: .resolved)
    #expect(CallSpeakerAdmission.observationSpeaking(reading, context: good) == ["Priya Shah"])
  }

  /// SYNTHETIC: an unnamed tile with the talking frame beside a named talking tile, and a
  /// participant tile nested inside another tile.
  @Test("Teams: an unnamed talking tile withholds; a nested tile's frame is not the outer tile's")
  func teamsMainWindowFrameEdges() {
    let frame = CallAXNode(role: "AXGroup", domClassList: ["vdi-frame-occlusion"])
    let good = CallCaptureContext(completeness: .complete, scope: .resolved)
    let unnamed = TeamsAppSpeakerReader.read(windows: [
      window(
        "Meeting",
        [
          CallAXNode(role: "AXMenuItem", description: "Context menu is available", children: [frame]),
          CallAXNode(
            role: "AXMenuItem", description: "Priya Shah (Guest), Context menu is available",
            children: [frame]),
        ])
    ])
    #expect(
      CallSpeakerAdmission.admission(of: unnamed, context: good) == .withheld(.unnamedTalker))
    // A tile with no label at all, alone and beside Priya.
    let unlabelled = CallAXNode(role: "AXMenuItem", children: [frame])
    for children in [
      [unlabelled],
      [
        unlabelled,
        CallAXNode(
          role: "AXMenuItem", description: "Priya Shah (Guest), Context menu is available",
          children: [frame]),
      ],
    ] {
      let reading = TeamsAppSpeakerReader.read(windows: [window("Meeting", children)])
      #expect(
        CallSpeakerAdmission.admission(of: reading, context: good) == .withheld(.unnamedTalker))
    }
    let nested = TeamsAppSpeakerReader.read(windows: [
      window(
        "Meeting",
        [
          CallAXNode(
            role: "AXMenuItem", description: "Alex Rivera (Guest), Context menu is available",
            children: [
              CallAXNode(
                role: "AXMenuItem", description: "Priya Shah (Guest), Context menu is available",
                children: [frame])
            ])
        ])
    ])
    #expect(nested.speaking == ["Priya Shah"])
  }

  /// SURVEY main window alone (no compact view): roster yes, talker no. SYNTHETIC: Organizer
  /// without a "Myself video" tile is not the user.
  @Test("Teams: the main window gives the roster but no talker, and Organizer is not the user")
  func teamsMainWindowOnly() {
    let reading = TeamsAppSpeakerReader.read(windows: [
      window(
        "Meeting with Saurabh Vaish",
        [
          CallAXNode(role: "AXRow", description: "Saurabh Vaish, Organizer, Muted"),
          CallAXNode(role: "AXRow", description: "Alex Rivera (Guest), Meeting guest, Unmuted"),
        ])
    ])
    #expect(reading.speaking.isEmpty)
    #expect(reading.roster.names == ["Saurabh Vaish", "Alex Rivera"])
    #expect(reading.roster.selfNames.isEmpty)
  }

  /// SYNTHETIC: two guests with one display name stay two roster entries; a comma inside a name
  /// is kept; the self tile matches the full name.
  @Test("Teams: duplicate names stay duplicated, comma names survive, self matches the full name")
  func teamsEdges() {
    let reading = TeamsAppSpeakerReader.read(windows: [
      window(
        "Meeting with Lee, Dana",
        [
          CallAXNode(role: "AXRow", description: "Lee, Dana, Organizer, Muted"),
          CallAXNode(role: "AXRow", description: "Alex Rivera (Guest), Meeting guest, Muted"),
          CallAXNode(role: "AXRow", description: "Alex Rivera (Guest), Meeting guest, Muted"),
          CallAXNode(
            role: "AXMenuItem", description: "Myself video, Lee, Dana, Muted, Has context menu"),
          CallAXNode(role: "AXGroup", description: "Lee, Dana is speaking"),
          CallAXNode(role: "AXGroup", description: "Alex Rivera (Guest) is speaking"),
        ])
    ])
    #expect(reading.roster.names == ["Lee, Dana", "Alex Rivera", "Alex Rivera"])
    #expect(reading.roster.selfNames == ["Lee, Dana"])
    #expect(reading.speaking == ["Lee, Dana", "Alex Rivera"])
  }

  /// SYNTHETIC: "Lee" and "Lee, Dana" on one call; only the full name is the user.
  @Test("Teams: a shorter roster name that prefixes the user's name is not the user")
  func teamsSelfCollision() {
    let reading = TeamsAppSpeakerReader.read(windows: [
      window(
        "Meeting",
        [
          CallAXNode(role: "AXRow", description: "Lee, Attendee, Muted"),
          CallAXNode(role: "AXRow", description: "Lee, Dana, Organizer, Muted"),
          CallAXNode(role: "AXMenuItem", description: "Myself video, Lee, Dana, Muted, Has context menu"),
        ])
    ])
    #expect(reading.roster.names == ["Lee", "Lee, Dana"])
    #expect(reading.roster.selfNames == ["Lee, Dana"])
  }

  /// SYNTHETIC: a role word inside a name, and an unknown row ending.
  @Test("Teams: the name is read from the row's fixed ending, an unknown ending is skipped")
  func teamsStructuralSuffix() {
    let reading = TeamsAppSpeakerReader.read(windows: [
      window(
        "Meeting",
        [
          CallAXNode(role: "AXRow", description: "Dana, Presenter, Lee (Guest), Meeting guest, Muted"),
          CallAXNode(role: "AXRow", description: "Priya Shah, Attendee"),
          CallAXNode(role: "AXRow", description: "Alex Rivera, Attendee, Raised hand"),
        ])
    ])
    #expect(reading.roster.names == ["Dana, Presenter, Lee", "Priya Shah"])
  }

  /// SYNTHETIC: only "Lee" is visible in the roster and the user's name continues with a word
  /// that starts like a state.
  @Test("Teams: a self tile is matched only when everything after the name is a tile state")
  func teamsSelfPartialRoster() {
    let reading = TeamsAppSpeakerReader.read(windows: [
      window(
        "Meeting",
        [
          CallAXNode(role: "AXRow", description: "Lee, Attendee, Muted"),
          CallAXNode(
            role: "AXMenuItem", description: "Myself video, Lee, Muted engineer, Muted, Has context menu"),
        ])
    ])
    #expect(reading.roster.selfNames.isEmpty)
  }

  /// SYNTHETIC: an audio part that only starts like Zoom's audio state is not one.
  @Test("Zoom: only Zoom's exact audio states end a name")
  func zoomExactAudioState() {
    let reading = ZoomAppSpeakerReader.read(windows: [
      window(
        "Zoom Meeting",
        [
          zoomTile("Dana, Computer audio engineer, Video off, active speaker"),
          zoomTile("Priya Shah, No audio connected"),
        ])
    ])
    #expect(reading.speaking.isEmpty)
    #expect(reading.roster.names == ["Priya Shah"])
  }
}
