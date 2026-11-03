import EnviousWisprCore
import Testing

@testable import EnviousWisprServices

/// #4013 reading resilience §3.2: when these fail, a Zoom call in full screen, with a popped-out
/// video or during a screen share gets no speaker names (its tiles sit in another window), or
/// tiles from two windows are merged into people who are not there, or the mute button is
/// trusted outside the meeting window.
///
/// Window shapes are SYNTHETIC from the 2026-11-02 repro probe (full screen: windows `None, None,
/// zm.meeting.window.main`) and Granola's fallback (`granola-multiwindow.md` in run
/// `20261102-172728-4013-competitor-ax-failure-handling-e7ce`). Tile labels are SURVEY.
@Suite("Zoom app window choice", .tags(.productOutcome))
struct ZoomWindowScopeTests {

  private static let alexTalking = "Alex Rivera, Computer audio unmuted, Video off, active speaker"
  private static let saurabh = "Saurabh A Vaish, Computer audio muted, Video off"
  private static let priya = "Priya Shah, Computer audio muted, Video off"

  private func tile(_ label: String) -> CallAXNode {
    CallAXNode(role: "AXTabGroup", description: label)
  }

  private func meeting(_ tiles: [String] = [], extra: [CallAXNode] = []) -> CallAXWindow {
    CallAXWindow(
      title: "Zoom Meeting",
      root: CallAXNode(
        role: "AXWindow", identifier: "zm.meeting.window.main",
        children: tiles.map(tile) + extra))
  }

  /// A window that is not the meeting window: untitled (full screen), "Zoom" (popped-out
  /// video, floating or minimized), or the screen-share strip.
  private func other(_ title: String?, _ tiles: [String], extra: [CallAXNode] = []) -> CallAXWindow
  {
    CallAXWindow(
      title: title, root: CallAXNode(role: "AXWindow", children: tiles.map(tile) + extra))
  }

  private func capture(_ windows: [CallAXWindow], complete: Bool = true) -> CallAXCapture {
    CallAXCapture(
      windows: windows, documents: [], completeness: complete ? .complete : .unreadable,
      readStartHostTime: 0, readEndHostTime: 0)
  }

  private func scope(_ windows: [CallAXWindow]) -> CallCaptureContext.Scope {
    CallSpeakerSurfaceReader.scope(surface: .zoomApp, capture: capture(windows), family: .zoom)
  }

  private func reading(_ windows: [CallAXWindow]) -> CallSpeakerReading? {
    CallSpeakerSurfaceReader.read(
      surface: .zoomApp, capture: capture(windows), rules: TalkerRulesSnapshot.empty.rules)
  }

  private func chosen(_ windows: [CallAXWindow]) -> [CallAXWindow]? {
    CallSpeakerSurfaceReader.zoomWindows(
      windows, share: ZoomAppSpeakerReader.shareContext(windows: windows))
  }

  private static let muteButton = CallAXNode(
    role: "AXButton", description: "Unmute my audio", identifier: "audio")
  private static let unmuteButton = CallAXNode(
    role: "AXButton", description: "Mute my audio", identifier: "audio")

  private func mute(_ windows: [CallAXWindow], complete: Bool = true) -> CallSelfMute {
    CallSelfMuteReader.read(
      surface: .zoomApp, capture: capture(windows, complete: complete), rules: .testPackaged)
  }

  // MARK: - Rule 1: how many meeting windows

  @Test("several meeting windows stay unresolved, even when each shows tiles")
  func severalMeetingWindows() {
    let windows = [meeting([Self.alexTalking]), meeting([Self.priya])]
    #expect(chosen(windows) == nil)
    #expect(scope(windows) == .unresolved)
    #expect(reading(windows) == nil)
  }

  @Test("no meeting window: the window with strictly the most tiles is read alone")
  func noMeetingWindowStrictWinner() {
    let winner = other(nil, [Self.alexTalking, Self.saurabh])
    let windows = [other("Zoom", [Self.priya]), winner]
    #expect(chosen(windows) == [winner])
    #expect(scope(windows) == .resolved)
    #expect(reading(windows)?.speaking == ["Alex Rivera"])
    #expect(reading(windows)?.roster.names == ["Alex Rivera", "Saurabh A Vaish"])
  }

  @Test("no meeting window: a tie for most tiles, or no tiles at all, stays unresolved")
  func noMeetingWindowTieOrNone() {
    let tie = [other(nil, [Self.alexTalking]), other("Zoom", [Self.priya])]
    #expect(chosen(tie) == nil)
    #expect(scope(tie) == .unresolved)
    let none = [other(nil, []), other("Zoom", [])]
    #expect(chosen(none) == nil)
    #expect(scope(none) == .unresolved)
    #expect(scope([]) == .unresolved)
  }

  // MARK: - Rule 2: the meeting window shows tiles

  @Test("a meeting window with tiles is read alone; tiles, talkers and lists elsewhere are ignored")
  func meetingWithTilesAlone() {
    let call = meeting([Self.alexTalking, Self.saurabh])
    let windows = [
      call,
      other(nil, [Self.priya, Self.priya, "Dana Lee, Computer audio unmuted, active speaker"]),
      other(
        "Participants (5)", [],
        extra: [CallAXNode(role: "AXOutline", description: "Participants list")]),
    ]
    #expect(chosen(windows) == [call])
    #expect(scope(windows) == .resolved)
    #expect(reading(windows)?.speaking == ["Alex Rivera"])
    #expect(reading(windows)?.roster.names == ["Alex Rivera", "Saurabh A Vaish"])
  }

  // MARK: - Rule 3: the meeting window shows no tile

  @Test(
    "an empty meeting window reads its strict winner's tiles",
    arguments: [
      "full screen" as String?, "popped-out video", "floating", "minimized", "share strip",
    ])
  func emptyMeetingStrictWinner(shape: String?) {
    // Full screen moves the tiles to an untitled window; the others are titled windows.
    let title: String? = shape == "full screen" ? nil : "Zoom"
    let call = meeting()
    let winner = other(title, [Self.alexTalking, Self.saurabh])
    let windows = [call, other(nil, [Self.priya]), winner]
    #expect(chosen(windows) == [call, winner])
    #expect(scope(windows) == .resolved)
    #expect(reading(windows)?.speaking == ["Alex Rivera"])
    #expect(reading(windows)?.roster.names == ["Alex Rivera", "Saurabh A Vaish"])
  }

  /// SURVEY (live full-screen take, 2026-11-02): the meeting window keeps only the large
  /// Speaker-view tile and its toolbar; the thumbnails move to "zoom floating video window".
  @Test(
    "full screen: the large tile alone does not hold the meeting window; the floating thumbnails are read"
  )
  func fullScreenLargeTileOnly() {
    let call = meeting(
      ["Alex Rivera, Computer audio unmuted, active speaker"],
      extra: [
        CallAXNode(role: "AXButton", description: "Open participants panel, closed, 2 participants")
      ])
    let floating = other(
      "zoom floating video window", ["Saurabh A Vaish, Computer audio unmuted, Video off"])
    let windows = [floating, other(nil, []), call]
    #expect(CallSpeakerSurfaceReader.zoomTileCount(call) == 0)
    #expect(chosen(windows) == [call, floating])
    #expect(scope(windows) == .resolved)
    let read = reading(windows)
    #expect(read?.participants.map(\.name) == ["Saurabh A Vaish", "Alex Rivera"])
    #expect(read?.participantIdentityEstablished == true)
    #expect(read?.speaking == ["Alex Rivera"])
    // The meeting window alone, as before this fix, establishes no one.
    #expect(ZoomAppSpeakerReader.read(windows: [call]).participantIdentityEstablished == false)
    // A meeting window with only its large tile and nothing elsewhere is still read alone.
    #expect(chosen([call]) == [call])
  }

  @Test("an empty meeting window with a tie for most tiles stays unresolved")
  func emptyMeetingTie() {
    let windows = [meeting(), other(nil, [Self.alexTalking]), other("Zoom", [Self.priya])]
    #expect(chosen(windows) == nil)
    #expect(scope(windows) == .unresolved)
    #expect(reading(windows) == nil)
  }

  @Test("an empty meeting window with no tiles anywhere is read alone, as before")
  func emptyMeetingAlone() {
    let call = meeting(extra: [
      CallAXNode(role: "AXButton", description: "Open participants panel, closed, 2 participants")
    ])
    let windows = [call, other("Zoom", [])]
    #expect(chosen(windows) == [call])
    #expect(scope(windows) == .resolved)
    #expect(reading(windows)?.participantCount == 2)
  }

  @Test("a popped-out participants list shows no tile and is never chosen")
  func poppedOutListIgnored() {
    let list = other(
      "Participants (2)", [],
      extra: [
        CallAXNode(role: "AXStaticText", value: "Participants (2)"),
        CallAXNode(role: "AXOutline", description: "Participants list"),
      ])
    let call = meeting([Self.alexTalking, Self.saurabh])
    #expect(chosen([call, list]) == [call])
    #expect(reading([call, list])?.rosterFromParticipantList == false)
    let empty = meeting()
    #expect(chosen([empty, list]) == [empty])
  }

  // MARK: - Naming through the chosen windows

  /// The meeting window's toolbar count stays in the reading while the tiles come from the
  /// other window, so the large-tile rule still has its count.
  @Test("the meeting window's count and the winner's tiles keep the large-tile rule")
  func largeTileAcrossChosenWindows() {
    let call = meeting(extra: [
      CallAXNode(role: "AXButton", description: "Open participants panel, closed, 2 participants")
    ])
    let strip = other(nil, ["Alex Rivera, Computer audio unmuted", Self.saurabh])
    let windows = [call, strip]
    #expect(reading(windows)?.participants.map(\.name) == ["Saurabh A Vaish", "Alex Rivera"])
    #expect(reading(windows)?.participantIdentityEstablished == true)
    // A count that disagrees keeps the large tile a repeat.
    let three = meeting(extra: [
      CallAXNode(role: "AXButton", description: "Open participants panel, closed, 3 participants")
    ])
    #expect(reading([three, strip])?.participants.map(\.name) == ["Saurabh A Vaish"])
  }

  @Test("counts that disagree across the chosen windows leave the count unknown")
  func conflictingCountsAcrossChosenWindows() {
    let call = meeting(extra: [
      CallAXNode(role: "AXButton", description: "Open participants panel, closed, 2 participants")
    ])
    let strip = other(
      nil, [Self.alexTalking, Self.saurabh],
      extra: [CallAXNode(role: "AXStaticText", value: "Participants (3)")])
    #expect(reading([call, strip])?.participantCount == nil)
  }

  @Test("a shared name in the winner's tiles still withholds the talker")
  func duplicateNamesAcrossChosenWindows() throws {
    let strip = other(nil, [Self.alexTalking, "Alex Rivera, Computer audio muted, Video off"])
    let read = try #require(reading([meeting(), strip]))
    #expect(read.sharedNames == ["Alex Rivera"])
    let context = CallCaptureContext(completeness: .complete, scope: scope([meeting(), strip]))
    #expect(
      CallSpeakerAdmission.admission(of: read, context: context) == .withheld(.ambiguousTalker))
  }

  @Test("a tie is withheld as an unresolved call, never named")
  func tieIsWithheld() throws {
    let windows = [meeting(), other(nil, [Self.alexTalking]), other("Zoom", [Self.priya])]
    var log = CallSpeakerAccumulator(surface: .zoomApp, rules: nil, lag: nil)
    log.add(
      reading(windows), context: CallCaptureContext(completeness: .complete, scope: scope(windows)),
      observationMs: 1_000)
    #expect(log.health.unresolvedScopeCaptures == 1)
    #expect(log.log.observations.isEmpty)
  }

  // MARK: - Mute follows only the meeting window

  @Test("mute reads the meeting window's button under each chosen layout")
  func muteInMeetingWindow() {
    let tiles = [Self.alexTalking, Self.saurabh]
    // Rule 2: tiles in the meeting window.
    #expect(mute([meeting(tiles, extra: [Self.muteButton])]) == .muted)
    #expect(mute([meeting(tiles, extra: [Self.unmuteButton])]) == .unmuted)
    // Rule 3: the meeting window is empty; its button still counts, the winner's never does.
    #expect(mute([meeting(extra: [Self.muteButton]), other(nil, tiles)]) == .muted)
    #expect(mute([meeting(extra: [Self.unmuteButton]), other(nil, tiles)]) == .unmuted)
    #expect(mute([meeting(), other(nil, tiles, extra: [Self.muteButton])]) == .unknown)
    // A button only in another window while the meeting window shows tiles is not trusted.
    #expect(mute([meeting(tiles), other(nil, [], extra: [Self.unmuteButton])]) == .unknown)
  }

  @Test("with no meeting window, mute stays unknown so the microphone stays live")
  func muteWithoutMeetingWindow() {
    let windows = [other(nil, [Self.alexTalking, Self.saurabh], extra: [Self.muteButton])]
    #expect(scope(windows) == .resolved)
    #expect(mute(windows) == .unknown)
  }

  @Test("an unresolved layout or an unreadable copy reads mute as unknown")
  func muteUnknownCases() {
    let tie = [
      meeting(extra: [Self.muteButton]), other(nil, [Self.alexTalking]),
      other("Zoom", [Self.priya]),
    ]
    #expect(mute(tie) == .unknown)
    // A failed selector identifier makes the copy unreadable (chunk 2), which reads unknown.
    #expect(
      mute([meeting([Self.alexTalking], extra: [Self.muteButton])], complete: false) == .unknown)
  }

  // MARK: - Screen share context and the collapsed floating window (#4013 share plan §3.0-3.1)
  // Window titles, mode buttons and labels are SURVEY from the 2026-11-03 discovery run
  // (`20261103-083021-4013-share-talking-label-discovery-c469`).

  private static let toolbar = CallAXWindow(
    title: "zoom share toolbar window",
    root: CallAXNode(
      role: "AXWindow",
      children: [CallAXNode(role: "AXButton", title: "Participants", description: "participant")]))

  private static func modeButtons(_ labels: [String]) -> [CallAXNode] {
    labels.map { CallAXNode(role: "AXButton", description: $0) }
  }

  private static let allModes = modeButtons([
    "Hide thumbnail video", "Show active speaker video", "Show thumbnail video", "Show grid video",
    "Show full meeting window",
  ])

  private func talkingText(_ value: String) -> CallAXNode {
    CallAXNode(role: "AXStaticText", value: value)
  }

  private func compact(_ labels: [String], tiles: [String] = [], modes: [CallAXNode]? = nil)
    -> CallAXWindow
  {
    other(
      "zoom floating video window", tiles, extra: labels.map(talkingText) + (modes ?? Self.allModes)
    )
  }

  private static let receiving = CallAXNode(role: "AXUnknown", description: "Share content")

  @Test(
    "share context reads the host toolbar, the guest share content and any count, in any window")
  func shareContext() {
    let none = ZoomAppSpeakerReader.shareContext(windows: [meeting([Self.saurabh])])
    #expect(none == .none)
    let host = ZoomAppSpeakerReader.shareContext(windows: [Self.toolbar, compact(["Talking: "])])
    #expect(host.hostShare == true)
    #expect(host.guestShare == false)
    #expect(host.countShown == false)
    let guest = ZoomAppSpeakerReader.shareContext(windows: [
      meeting([Self.alexTalking], extra: [Self.receiving])
    ])
    #expect(guest.guestShare == true)
    #expect(guest.hostShare == false)
    // "Share content" outside the meeting window is not a guest share.
    #expect(
      ZoomAppSpeakerReader.shareContext(windows: [other(nil, [], extra: [Self.receiving])])
        .guestShare == false)
    // Counts in any window, in any shape Zoom draws them, parsed or not.
    let button = { (label: String) in CallAXNode(role: "AXButton", description: label) }
    for label in [
      "Open participants panel, closed, 3 participants",
      "Open participants panel, closed, 2 participants, 1 person is waiting",
      "Close participants panel, opened, 4 participants",
    ] {
      #expect(
        ZoomAppSpeakerReader.shareContext(windows: [
          Self.toolbar, other(nil, [], extra: [button(label)]),
        ]).countShown)
    }
    #expect(
      ZoomAppSpeakerReader.shareContext(windows: [
        other(nil, [], extra: [talkingText("Participants (3)")])
      ]).countShown)
    #expect(
      ZoomAppSpeakerReader.shareContext(windows: [
        other(nil, [], extra: [CallAXNode(role: "AXOutline", description: "Participants list")])
      ]).countShown)
    // The share toolbar's own Participants button carries no count.
    #expect(ZoomAppSpeakerReader.shareContext(windows: [Self.toolbar]).countShown == false)
  }

  @Test("the user's name: one panel mark, else exactly one account; disagreement is unknown")
  func identifiedSelf() {
    #expect(
      ZoomAppSpeakerReader.identifiedSelf(marks: [], account: ["Saurabh A Vaish"])
        == "Saurabh A Vaish")
    #expect(ZoomAppSpeakerReader.identifiedSelf(marks: ["Dana"], account: []) == "Dana")
    #expect(
      ZoomAppSpeakerReader.identifiedSelf(marks: ["Dana", "Dana"], account: ["Dana"]) == "Dana")
    #expect(
      ZoomAppSpeakerReader.identifiedSelf(marks: ["Dana"], account: ["Saurabh A Vaish"]) == nil)
    #expect(ZoomAppSpeakerReader.identifiedSelf(marks: ["Dana", "Lee"], account: []) == nil)
    #expect(ZoomAppSpeakerReader.identifiedSelf(marks: [], account: []) == nil)
  }

  @Test("a compact window needs both observed mode buttons and is never the meeting window")
  func compactRecognition() {
    #expect(ZoomAppSpeakerReader.isCompactWindow(compact([])))
    // The full-screen floating window shows only some modes; the two required ones suffice.
    #expect(
      ZoomAppSpeakerReader.isCompactWindow(
        compact(
          [],
          modes: Self.modeButtons([
            "Hide thumbnail video", "Show active speaker video", "Show thumbnail video",
          ]))))
    #expect(
      ZoomAppSpeakerReader.isCompactWindow(
        compact([], modes: Self.modeButtons(["Hide thumbnail video"]))) == false)
    #expect(ZoomAppSpeakerReader.isCompactWindow(meeting(extra: Self.allModes)) == false)
    #expect(ZoomAppSpeakerReader.talkingName("Talking: Bea Chen") == "Bea Chen")
    #expect(ZoomAppSpeakerReader.talkingName("Talking: ") == "")
    #expect(ZoomAppSpeakerReader.talkingName("Talking:Bea") == nil)
    #expect(ZoomAppSpeakerReader.talkingName("Sprechen: Bea") == nil)
  }

  @Test(
    "during a share with no tile anywhere, the one compact window with one Talking label is read")
  func collapsedWindowChosen() {
    let label = compact(["Talking: Bea Chen"])
    #expect(chosen([Self.toolbar, label]) == [label])
    // An empty label ("nobody talking") is still the window to read.
    let quiet = compact(["Talking: "])
    #expect(chosen([Self.toolbar, quiet]) == [quiet])
    // With a tile-free meeting window, both are read.
    let empty = meeting(extra: [Self.receiving])
    #expect(chosen([empty, label]) == [empty, label])
  }

  @Test("the collapsed window is refused when ambiguous, outside a share, or not compact")
  func collapsedWindowRefused() {
    // No share evidence: as before, nothing to choose.
    #expect(chosen([compact(["Talking: Bea Chen"])]) == nil)
    // Two labelled compact windows, or two labels in one.
    #expect(
      chosen([Self.toolbar, compact(["Talking: Bea Chen"]), compact(["Talking: Alex Rivera"])])
        == nil)
    #expect(chosen([Self.toolbar, compact(["Talking: Bea Chen", "Talking: Alex Rivera"])]) == nil)
    // A Talking text in a window without the mode buttons is not Zoom's floating window.
    #expect(chosen([Self.toolbar, compact(["Talking: Bea Chen"], modes: [])]) == nil)
  }

  @Test("tiles anywhere win over the collapsed window, large tiles included")
  func tilesWinOverLabel() {
    let label = compact(["Talking: Bea Chen"])
    // A thumbnail in another window: the existing strict-winner rule.
    let strip = other(nil, [Self.saurabh])
    #expect(chosen([Self.toolbar, meeting(), label, strip]) == [meeting(), strip])
    // A large tile (no video state) in the meeting window: the meeting window alone, as before.
    let large = meeting(["Bea Chen, Computer audio unmuted"])
    #expect(chosen([Self.toolbar, large, label]) == [large])
    // Thumbnails in the meeting window: the meeting window alone.
    let full = meeting([Self.saurabh, Self.alexTalking])
    #expect(chosen([Self.toolbar, full, label]) == [full])
  }

  @Test("the collapsed window resolves scope, and mute stays unknown without a meeting window")
  func collapsedScopeAndMute() {
    let windows = [Self.toolbar, compact(["Talking: Bea Chen"])]
    #expect(scope(windows) == .resolved)
    #expect(mute(windows) == .unknown)
    #expect(
      mute([meeting(extra: [Self.muteButton, Self.receiving]), compact(["Talking: Bea Chen"])])
        == .muted)
  }
}
