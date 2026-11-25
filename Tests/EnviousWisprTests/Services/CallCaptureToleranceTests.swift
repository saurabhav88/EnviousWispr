import EnviousWisprCore
import Testing

@testable import EnviousWisprServices

/// #4013 reading resilience §3.1: when these fail, opening Zoom's chat panel makes every speaker
/// copy unreadable again (no names for the whole call), or a failed read that could hide a
/// person, a talking flag, the head count or the mute button is let through as complete.
///
/// Trees are SYNTHETIC literal trees read through the live walker. The chat-panel failures are
/// the ones probed on the live Zoom app on 2026-11-02 (`probe-chat.txt` in run
/// `20261102-164812-4013-speaker-names-live-repro-9ea5`): the chat input `AXTextArea` fails its
/// identifier and an `AXUnknown` in the chat list fails its description, on every read.
@Suite("Speaker capture tolerates reads no reader uses", .tags(.productOutcome))
struct CallCaptureToleranceTests {
  typealias Tree = CallSpeakerCaptureTests.Tree

  private func capture(
    _ tree: Tree, policy: CallAXCapturePolicy = .zoomApp, protectedRoles: Set<String> = []
  ) -> CallAXCapture {
    var host: UInt64 = 100
    return CallSpeakerCapture.capture(
      windows: [1], access: tree.access(), bounds: .standard, policy: policy,
      protectedRoles: protectedRoles, keepPage: { _ in true },
      hostTime: {
        host += 10
        return host
      })
  }

  /// A Zoom meeting window with a talking tile, the participants list, the count, the mute
  /// button and the open chat panel (SURVEY roles and labels).
  private func meetingTree() -> Tree {
    let tree = Tree()
    tree.node(1, "AXWindow", children: [2, 5, 10, 13, 40])
    tree.texts[1] = [.identifier: "zm.meeting.window.main", .title: "Zoom Meeting"]
    tree.node(2, "AXTabGroup", children: [3])
    tree.texts[2] = [.title: "Alex Rivera, Computer audio unmuted, Video off, active speaker"]
    tree.node(3, "AXGroup")
    tree.node(5, "AXOutline", children: [30, 31])
    tree.texts[5] = [.description: "Participants list"]
    tree.node(30, "AXCell", children: [6, 32])
    tree.texts[30] = [.identifier: "ZMHCTableItemType_PANELIST"]
    tree.node(6, "AXStaticText")
    tree.texts[6] = [.value: "Alex Rivera"]
    tree.node(32, "AXMenuButton")
    tree.texts[32] = [.description: "More options for Alex Rivera, collapsed"]
    tree.node(31, "AXCell", children: [7, 33])
    tree.texts[31] = [.identifier: "ZMHCTableItemType_PANELIST"]
    tree.node(7, "AXStaticText")
    tree.texts[7] = [.value: "Saurabh A Vaish (Host, me)"]
    tree.node(33, "AXMenuButton")
    tree.texts[33] = [.description: "More options for Saurabh A Vaish, collapsed"]
    tree.node(10, "AXStaticText")
    tree.texts[10] = [.value: "Participants (2)"]
    tree.node(13, "AXButton")
    tree.texts[13] = [.identifier: "audio", .description: "Unmute my audio"]
    // The chat panel: its list, then its input, then a later element that must still be read.
    tree.node(40, "AXGroup", children: [41, 42, 43])
    tree.node(41, "AXScrollArea", children: [44])
    tree.node(44, "AXUnknown")
    tree.node(42, "AXTextArea")
    tree.node(43, "AXGroup", children: [45])
    tree.node(45, "AXImage")
    return tree
  }

  private func chatFailures(_ tree: Tree) {
    tree.failing.formUnion(["42.AXIdentifier", "44.AXDescription"])
  }

  private func roles(_ copy: CallAXCapture) -> [String] {
    copy.windows.flatMap { $0.root.allNodes.map(\.role) }
  }

  @Test("the observed chat-panel failures leave a complete copy with both counted")
  func observedChatFailures() {
    let tree = meetingTree()
    chatFailures(tree)
    let copy = capture(tree)
    #expect(copy.completeness == .complete)
    #expect(copy.toleratedFailures == 2)
    #expect(copy.failedReads == 2)
    // The failing elements are kept and the walk goes on past them.
    #expect(roles(copy).contains("AXUnknown"))
    #expect(roles(copy).contains("AXTextArea"))
    #expect(tree.queried.contains("45.AXRole"))
    let reading = ZoomAppSpeakerReader.read(windows: copy.windows)
    #expect(reading.speaking == ["Alex Rivera"])
    #expect(reading.roster.names == ["Alex Rivera", "Saurabh A Vaish"])
    #expect(reading.participantListComplete)
    #expect(
      CallSelfMuteReader.read(surface: .zoomApp, capture: copy, rules: .testPackaged) == .muted)
    // Control: the same failures under the standard policy are unreadable, as before.
    let whole = meetingTree()
    chatFailures(whole)
    #expect(capture(whole, policy: .standard).completeness == .unreadable)
  }

  @Test(
    "each label attribute on an unread role is tolerated",
    arguments: ["AXTitle", "AXDescription", "AXValue", "AXIdentifier", "AXDOMClassList", "AXSize"])
  func eachAttributeTolerated(attribute: String) {
    let tree = meetingTree()
    tree.failing.insert("42.\(attribute)")
    let copy = capture(tree)
    #expect(copy.completeness == .complete)
    #expect(copy.toleratedFailures == 1)
  }

  @Test("the DOM id is tolerated by the same decision, though Zoom never reads it")
  func domIdentifierDecision() {
    let policy = CallAXCapturePolicy.zoomApp
    #expect(
      policy.tolerates(
        attribute: .domIdentifier, role: "AXTextArea", insideEvidence: false, isWindow: false,
        protectedRoles: []))
    #expect(policy.readsDOMIdentifier(role: "AXButton") == false)
    for attribute in [CallAXAttribute.role, .children, .url, .windows, .menuBar, .markChar] {
      #expect(
        policy.tolerates(
          attribute: attribute, role: "AXTextArea", insideEvidence: false, isWindow: false,
          protectedRoles: []) == false, "\(attribute)")
    }
  }

  @Test(
    "a failed label on a role a reader uses still makes the copy unreadable",
    arguments: [
      (2, "AXTabGroup"), (5, "AXOutline"), (13, "AXButton"), (10, "AXStaticText"),
      (30, "AXCell"), (32, "AXMenuButton"),
    ])
  func protectedRoles(id: Int, role: String) {
    // A list row's own description is the one Zoom 7.2.5 refuses and no reader uses (#4935).
    let label = role == "AXCell" ? "AXTitle" : "AXDescription"
    #expect(role == "AXCell" || CallAXCapturePolicy.zoomProtectedRoles.contains(role))
    let tree = meetingTree()
    #expect(tree.roles[id] == role)
    tree.failing.insert("\(id).\(label)")
    let copy = capture(tree)
    #expect(copy.completeness == .unreadable)
    #expect(copy.toleratedFailures == 0)
  }

  @Test("the protected roles are exactly the five read outside tiles and lists")
  func protectedRoleSet() {
    #expect(
      CallAXCapturePolicy.zoomProtectedRoles == [
        "AXTabGroup", "AXOutline", "AXButton", "AXStaticText", "AXMenuButton",
      ])
  }

  @Test("a failed label anywhere inside a tile or the list still makes the copy unreadable")
  func insideEvidence() {
    for failing in ["3.AXDescription", "3.AXIdentifier"] {
      let tree = meetingTree()
      tree.failing.insert(failing)
      #expect(capture(tree).completeness == .unreadable, "\(failing)")
    }
    // An unread role nested inside a list row.
    let tree = meetingTree()
    tree.children[30] = [6, 32, 34]
    tree.node(34, "AXGroup")
    tree.failing.insert("34.AXTitle")
    #expect(capture(tree).completeness == .unreadable)
  }

  @Test("a failed role, children or page address still makes the copy unreadable")
  func structuralFailures() {
    for failing in ["42.AXRole", "41.AXChildren", "43.AXChildren"] {
      let tree = meetingTree()
      tree.failing.insert(failing)
      #expect(capture(tree).completeness == .unreadable, "\(failing)")
    }
    let page = meetingTree()
    page.children[40] = [41, 42, 43, 46]
    page.node(46, "AXWebArea")
    page.failing.insert("46.AXURL")
    #expect(capture(page).completeness == .unreadable)
  }

  @Test("a window's title and identifier are never lost, its other labels are (#4943)")
  func windowIdentity() {
    for failing in ["1.AXIdentifier", "1.AXTitle", "1.AXChildren"] {
      let tree = meetingTree()
      tree.failing.insert(failing)
      #expect(capture(tree).completeness == .unreadable, "\(failing)")
    }
    let lost = meetingTree()
    lost.failing = ["1.AXDescription", "1.AXValue"]
    #expect(capture(lost).completeness == .complete)
    #expect(capture(lost).toleratedFailures == 2)
    // A cell outside a list: only its identifier is read.
    let cell = meetingTree()
    cell.roles[43] = "AXCell"
    cell.failing.insert("43.AXDescription")
    #expect(capture(cell).completeness == .complete)
    cell.failing.insert("43.AXIdentifier")
    #expect(capture(cell).completeness == .unreadable)
    // A window is one by its place, not by the role it reports; the share scan reads an
    // `AXUnknown` root's label, and a tile or a button is read as one.
    for role in ["AXWindow", "AXCell", "AXUnknown", "AXTabGroup", "AXButton"] {
      for attribute in CallAXCapturePolicy.zoomToleratedAttributes {
        let lost =
          ["AXWindow", "AXCell"].contains(role)
          && !CallAXCapturePolicy.zoomWindowAttributes.contains(attribute)
        #expect(
          CallAXCapturePolicy.zoomApp.tolerates(
            attribute: attribute, role: role, insideEvidence: false, isWindow: true,
            protectedRoles: []) == lost, "\(role) \(attribute)")
      }
    }
    #expect(CallAXCapturePolicy.zoomWindowAttributes == [.title, .identifier])
  }

  @Test("a role the mute rules select is protected like the fixed ones")
  func muteRuleRoles() {
    let tree = meetingTree()
    tree.children[1] = [2, 5, 10, 13, 40, 50]
    tree.node(50, "AXCheckBox")
    tree.failing.insert("50.AXDescription")
    #expect(capture(tree).completeness == .complete)
    let protected = meetingTree()
    protected.children[1] = [2, 5, 10, 13, 40, 50]
    protected.node(50, "AXCheckBox")
    protected.failing.insert("50.AXDescription")
    #expect(capture(protected, protectedRoles: ["AXCheckBox"]).completeness == .unreadable)
  }

  @Test(
    "a failed mute-button read still reads the mute state as unknown",
    arguments: ["AXIdentifier", "AXTitle", "AXDescription", "AXValue"])
  func failedMuteSelector(attribute: String) {
    let tree = meetingTree()
    chatFailures(tree)
    tree.failing.formUnion(["13.\(attribute)", "1.AXDescription"])
    let copy = capture(tree)
    #expect(copy.completeness == .unreadable)
    #expect(
      CallSelfMuteReader.read(surface: .zoomApp, capture: copy, rules: .testPackaged) == .unknown)
  }

  // MARK: - Consumer inventory

  /// Every text a Zoom consumer matches on, placed on elements whose failed labels tolerance
  /// copies as nothing. If any consumer read such an element (an unrestricted label scan as much
  /// as a role check), adding these would change what it reads.
  static let consumedTexts = [
    "Alex Rivera, Computer audio unmuted, Video off, active speaker",
    "Priya Shah, Computer audio muted, Video off", "Participants (5)", "Participants list",
    "Open participants panel, closed, 5 participants", "Priya Shah (Host, me)",
    "More options for Priya Shah, collapsed", "Unmute my audio", "Mute my audio", "audio",
    "leave", "more", "ZMHCTableItemType_PANELIST", "zm.meeting.window.main", "Talking: Zoe",
  ]
  private static let unreadRoles = [
    "AXGroup", "AXTextArea", "AXUnknown", "AXImage", "AXRow", "AXScrollArea", "AXCheckBox",
    "AXTextField", "AXList", "AXLink", "AXCell",
  ]

  private func decoys(role: String) -> [CallAXNode] {
    Self.consumedTexts.flatMap { text in
      [
        CallAXNode(role: role, title: text), CallAXNode(role: role, description: text),
        CallAXNode(role: role, value: text), CallAXNode(role: role, identifier: text),
      ]
    }
  }

  private func meetingWindow(extra: [CallAXNode]) -> CallAXWindow {
    let copy = capture(meetingTree())
    let root = copy.windows[0].root
    return CallAXWindow(
      title: copy.windows[0].title,
      root: CallAXNode(
        role: root.role, title: root.title, description: root.description, value: root.value,
        identifier: root.identifier, children: root.children + extra))
  }

  private struct Outcome: Equatable {
    let reading: CallSpeakerReading?
    let scope: CallCaptureContext.Scope
    let mute: CallSelfMute
    let shown: ZoomShownPeople
  }

  private func outcome(_ window: CallAXWindow) -> Outcome {
    let capture = CallAXCapture(
      windows: [window], documents: [], completeness: .complete, readStartHostTime: 0,
      readEndHostTime: 0)
    return Outcome(
      reading: CallSpeakerSurfaceReader.zoomReading(capture, labels: .builtIn),
      scope: CallSpeakerSurfaceReader.scope(
        surface: .zoomApp, capture: capture, family: .zoom, zoomLabels: .builtIn),
      mute: CallSelfMuteReader.read(surface: .zoomApp, capture: capture, rules: .testPackaged),
      shown: ZoomAppSpeakerReader.shownPeople(windows: [window]))
  }

  @Test("no Zoom consumer reads a role whose failed labels are tolerated", arguments: unreadRoles)
  func consumersIgnoreUnreadRoles(role: String) {
    #expect(CallAXCapturePolicy.zoomProtectedRoles.contains(role) == false)
    let plain = outcome(meetingWindow(extra: []))
    let decoyed = outcome(meetingWindow(extra: decoys(role: role)))
    #expect(decoyed == plain)
  }

  /// Control for the inventory: the same decoys on protected roles do change what is read, so
  /// the inventory can see a consumer.
  @Test("the inventory sees a consumer: decoys on read roles change the outcome")
  func inventoryControl() {
    let plain = outcome(meetingWindow(extra: []))
    for role in ["AXTabGroup", "AXButton", "AXStaticText"] {
      let decoyed = outcome(meetingWindow(extra: decoys(role: role)))
      #expect(decoyed != plain, "\(role)")
    }
  }
}
