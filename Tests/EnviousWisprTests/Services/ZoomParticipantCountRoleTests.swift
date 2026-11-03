import EnviousWisprCore
import Testing

@testable import EnviousWisprServices

/// #4013 reading resilience §3.1: when these fail, a label on some other Zoom element (a chat
/// line, a window button) that happens to read "Participants (N)" becomes the call's head count,
/// or contradicts the real one, so the app trusts a wrong count or refuses a right one.
///
/// The count comes only from the `AXStaticText` Zoom draws above its participants list (C1a,
/// 2026-10-28). Capture tolerance (§3.1) copies a failed label as nothing on an unprotected role
/// outside a tile or the list, so such a role must never feed the count. SYNTHETIC trees built
/// from SURVEY labels.
@Suite("Zoom participant count reads only static text", .tags(.productOutcome))
struct ZoomParticipantCountRoleTests {

  private func window(_ children: [CallAXNode]) -> CallAXWindow {
    CallAXWindow(
      title: "Zoom Meeting",
      root: CallAXNode(role: "AXWindow", title: "Zoom Meeting", children: children))
  }

  private func tile(_ label: String) -> CallAXNode {
    CallAXNode(role: "AXTabGroup", description: label)
  }

  private func count(_ text: String) -> CallAXNode {
    CallAXNode(role: "AXStaticText", value: text)
  }

  /// A joined participants-list row, as observed 2026-10-29.
  private func row(_ entry: String) -> CallAXNode {
    let name = ZoomAppSpeakerReader.panelEntry(entry).name
    return CallAXNode(
      role: "AXRow",
      children: [
        CallAXNode(
          role: "AXCell", identifier: ZoomAppSpeakerReader.joinedRowIdentifier,
          children: [
            CallAXNode(role: "AXStaticText", value: entry),
            CallAXNode(role: "AXMenuButton", description: "More options for \(name), collapsed"),
          ])
      ])
  }

  private func list(_ names: [String]) -> CallAXNode {
    CallAXNode(role: "AXOutline", description: "Participants list", children: names.map(row))
  }

  private let thumbnails = [
    CallAXNode(role: "AXTabGroup", description: "Saurabh A Vaish, Computer audio muted, Video off"),
    CallAXNode(role: "AXTabGroup", description: "Alex Rivera, Computer audio muted, Video off"),
  ]

  /// Labels Zoom never uses for the count, on roles other than static text.
  private let otherRoles: [CallAXNode] = [
    CallAXNode(role: "AXGroup", title: "Participants (5)"),
    CallAXNode(role: "AXButton", description: "Participants (5)"),
    CallAXNode(role: "AXTextArea", value: "Participants (5)"),
    CallAXNode(role: "AXUnknown", description: "Participants (5)"),
  ]

  @Test("a static-text count is the call's count")
  func staticTextCounts() {
    let reading = ZoomAppSpeakerReader.read(windows: [
      window(thumbnails + [count("Participants (2)")])
    ])
    #expect(reading.participantCount == 2)
  }

  @Test("the same text on any other role never supplies a count", arguments: 0..<4)
  func otherRoleNeverSupplies(index: Int) {
    let reading = ZoomAppSpeakerReader.read(windows: [window(thumbnails + [otherRoles[index]])])
    #expect(reading.participantCount == nil)
  }

  @Test("the same text on any other role never contradicts a static-text count", arguments: 0..<4)
  func otherRoleNeverConflicts(index: Int) {
    let reading = ZoomAppSpeakerReader.read(windows: [
      window(thumbnails + [count("Participants (2)"), otherRoles[index]])
    ])
    #expect(reading.participantCount == 2)
  }

  @Test("two static-text counts that disagree still leave the count unknown")
  func staticTextConflictWithholds() {
    let reading = ZoomAppSpeakerReader.read(windows: [
      window(thumbnails + [count("Participants (2)"), count("Participants (3)")])
    ])
    #expect(reading.participantCount == nil)
  }

  @Test("an open list stays complete when another role shows a different count")
  func openListCompleteDespiteOtherRole() {
    let reading = ZoomAppSpeakerReader.read(windows: [
      window(
        thumbnails + [
          count("Participants (2)"), list(["Saurabh A Vaish (Host, me)", "Alex Rivera"]),
        ]
          + otherRoles)
    ])
    #expect(reading.rosterFromParticipantList)
    #expect(reading.participantListComplete)
    #expect(reading.participantCount == 2)
  }

  @Test("an open list whose static-text count disagrees is still not complete")
  func openListStaticConflict() {
    let reading = ZoomAppSpeakerReader.read(windows: [
      window(
        thumbnails + [
          count("Participants (3)"), list(["Saurabh A Vaish (Host, me)", "Alex Rivera"]),
        ])
    ])
    #expect(reading.rosterFromParticipantList == false)
    #expect(reading.participantListComplete == false)
  }

  /// The large tile is a person of its own only when the call's count says one more than the
  /// thumbnails; a label on another role must not make it one.
  @Test("a count on another role never turns the large tile into a person")
  func largeTileNeedsStaticCount() {
    let large = tile("Priya Shah, Computer audio unmuted")
    let real = ZoomAppSpeakerReader.read(windows: [
      window(thumbnails + [large, count("Participants (3)")])
    ])
    #expect(real.participants.map(\.name) == ["Saurabh A Vaish", "Alex Rivera", "Priya Shah"])
    let other = ZoomAppSpeakerReader.read(windows: [
      window(thumbnails + [large, CallAXNode(role: "AXGroup", title: "Participants (3)")])
    ])
    #expect(other.participants.map(\.name) == ["Saurabh A Vaish", "Alex Rivera"])
  }
}
