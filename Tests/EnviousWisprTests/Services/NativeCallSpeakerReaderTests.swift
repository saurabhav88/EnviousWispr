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
    #expect(reading.roster.names == ["Alex Rivera", "Saurabh A Vaish", "Priya Shah"])
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
    // The panel's tree was not captured, so its names are not read as a roster yet (#4013 C1).
    #expect(reading.roster.names.isEmpty)
    #expect(!reading.rosterFromParticipantList)
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
          CallAXNode(role: "AXRow", description: "In this meeting, 4 total"),
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
}
