import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprServices

/// #4356: when these fail, EnviousMeet can press Zoom's Participants button when it should not,
/// leave the panel open, close a panel the user opened, press a button in a replacement window,
/// or take a name Zoom never marked `(me)` for the user, which gives the guest's voice the
/// user's name.
///
/// Trees are SYNTHETIC: a small fake Zoom app (ids, attributes, a scripted clock) read through
/// the same capture walker and reader row parsing the live probe uses. Shapes follow the live
/// receipt `20261103-152130-zoom-self-name-competitors-5184/receipt-press.md`.
@Suite("Zoom self probe", .tags(.productOutcome))
struct ZoomSelfProbeTests {
  /// A fake Zoom app: element ids with attributes and children, a clock that moves one
  /// millisecond per message (plus `slow` extra on chosen reads) and on every pause, and a
  /// Participants button whose press opens or closes the panel.
  final class FakeZoom {
    static let app = 1
    static let meeting = 10
    static let button = 11
    static let panel = 20

    var texts: [Int: [CallAXAttribute: String]] = [:]
    var children: [Int: [Int]] = [:]
    var failing: Set<String> = []
    var windows: [Int] = [meeting]
    var offset: Duration = .zero
    let start = ContinuousClock.now
    /// Extra time one read of `id.attribute` costs (an AX message that overruns).
    var slow: [String: Duration] = [:]
    /// Ids pressed, in order, and the clock offset of each press.
    var presses: [Int] = []
    var pressedAt: [Duration] = []
    /// After a close press the button can no longer be read.
    var blindAfterClose = false
    /// Times at which `pause` was called (poll gaps), as offsets.
    var pauses: [Duration] = []
    /// What the press of the button does: open (the default) or nothing.
    var pressOpens = true
    var pressCloses = true
    var pressAnswer: ZoomSelfProbe.PressAnswer = .done
    /// Rows the panel shows once it has been open this long.
    var rowsDelay: Duration = .zero
    var rows: [CallAXNode] = []
    var openedAt: Duration?
    /// Runs at each pause, to script the user or Zoom changing things mid-probe.
    var onPause: (FakeZoom) -> Void = { _ in }
    private var nextId = 100

    init(label: String = "Open participants panel, closed, 2 participants") {
      texts[Self.meeting] = [.role: "AXWindow", .identifier: "zm.meeting.window.main"]
      texts[Self.button] = [.role: "AXButton", .identifier: "participant", .description: label]
      let other = 12
      texts[other] = [.role: "AXButton", .identifier: "share", .description: "Share"]
      children[Self.meeting] = [Self.button, other]
      if label.hasPrefix("Close participants panel") {
        openedAt = .zero
        children[Self.meeting]?.append(Self.panel)
      }
      texts[Self.panel] = [.role: "AXOutline", .description: "Participants list"]
    }

    var now: ContinuousClock.Instant { start.advanced(by: offset) }

    /// Turns literal reader nodes into fake elements under `parent`.
    func add(_ node: CallAXNode) -> Int {
      nextId += 1
      let id = nextId
      var t: [CallAXAttribute: String] = [:]
      t[.role] = node.role
      if let v = node.value { t[.value] = v }
      if let d = node.description { t[.description] = d }
      if let i = node.identifier { t[.identifier] = i }
      texts[id] = t
      children[id] = node.children.map(add)
      return id
    }

    func setLabel(_ label: String) { texts[Self.button]?[.description] = label }

    private func answer(_ id: Int, _ attribute: CallAXAttribute) -> CallAXRead<Int> {
      offset += .milliseconds(1) + (slow["\(id).\(attribute.rawValue)"] ?? .zero)
      if failing.contains("\(id).\(attribute.rawValue)") { return .failed }
      if id == Self.app, attribute == .windows { return .elements(windows) }
      if id == Self.panel, attribute == .children {
        guard let openedAt, offset - openedAt >= rowsDelay else { return .elements([]) }
        return .elements(rows.map(add))
      }
      if attribute == .children { return .elements(children[id] ?? []) }
      return texts[id]?[attribute].map { .text($0) } ?? .missing
    }

    func access() -> CallAXTreeAccess<Int> {
      CallAXTreeAccess<Int>(
        read: { [self] id, attribute in answer(id, attribute) },
        readMany: { [self] id, attributes in attributes.map { answer(id, $0) } },
        hash: { $0 }, same: { $0 == $1 }, now: { [self] in now })
    }

    func press(_ id: Int) -> ZoomSelfProbe.PressAnswer {
      presses.append(id)
      pressedAt.append(offset)
      guard id == Self.button || texts[id]?[.identifier] == "participant" else { return .refused }
      let label = texts[id]?[.description] ?? ""
      if label.hasPrefix("Open"), pressOpens {
        texts[id]?[.description] = "Close participants panel, opened, 2 participants"
        if id == Self.button {
          openedAt = offset
          children[Self.meeting]?.append(Self.panel)
        }
      } else if label.hasPrefix("Close"), blindAfterClose {
        failing.insert("\(id).AXDescription")
      } else if label.hasPrefix("Close"), pressCloses {
        texts[id]?[.description] = "Open participants panel, closed, 2 participants"
        if id == Self.button {
          openedAt = nil
          children[Self.meeting]?.removeAll { $0 == Self.panel }
        }
      }
      return pressAnswer
    }

    func run(stop: @escaping () -> Bool = { false }) -> ZoomSelfProbe.Result {
      ZoomSelfProbe.run(
        app: Self.app, access: access(), press: { [self] in press($0) },
        pause: { [self] gap in
          pauses.append(offset)
          offset += gap
          onPause(self)
        }, protectedRoles: [], shouldStop: stop)
    }
  }

  /// A joined, bound row; `bound` false is a row Zoom filled but has not bound to anyone.
  static func row(_ entry: String, bound: Bool = true) -> CallAXNode {
    let name = ZoomAppSpeakerReader.panelEntry(entry).name
    return CallAXNode(
      role: "AXRow",
      children: [
        CallAXNode(
          role: "AXCell", identifier: ZoomAppSpeakerReader.joinedRowIdentifier,
          children: [
            CallAXNode(role: "AXStaticText", value: entry),
            CallAXNode(
              role: "AXMenuButton",
              description: "More options for \(bound ? name : ""), collapsed"),
          ])
      ])
  }

  static let usual = [row("Saurabh Vaish (Host, me)"), row("Bea Chen")]

  @Test("opens the closed panel, learns the one (me) row, and closes it once")
  func learnsAndCloses() {
    let zoom = FakeZoom()
    zoom.rows = Self.usual
    let result = zoom.run()
    #expect(result.refusal == nil)
    #expect(result.pressedOpen)
    #expect(result.learned == "Saurabh Vaish")
    #expect(result.panelClosed == true)
    #expect(zoom.presses == [FakeZoom.button, FakeZoom.button])
    #expect(zoom.openedAt == nil, "the panel ends closed")
  }

  @Test("presses nothing when the button or the meeting window cannot be told")
  func refusals() {
    let missing = FakeZoom()
    missing.texts[FakeZoom.button]?[.identifier] = "chat"
    #expect(missing.run().refusal == .notFound)
    #expect(missing.presses.isEmpty)

    let twoButtons = FakeZoom()
    twoButtons.texts[13] = twoButtons.texts[FakeZoom.button]
    twoButtons.children[FakeZoom.meeting]?.append(13)
    #expect(twoButtons.run().refusal == .ambiguous)
    #expect(twoButtons.presses.isEmpty)

    let twoWindows = FakeZoom()
    twoWindows.texts[30] = twoWindows.texts[FakeZoom.meeting]
    twoWindows.windows.append(30)
    #expect(twoWindows.run().refusal == .ambiguous)
    #expect(twoWindows.presses.isEmpty)

    let unreadable = FakeZoom()
    unreadable.failing = ["\(FakeZoom.button).AXDescription"]
    #expect(unreadable.run().refusal == .unreadable)
    #expect(unreadable.presses.isEmpty)

    let none = FakeZoom()
    none.windows = []
    #expect(none.run().refusal == .notFound)
  }

  @Test("leaves a panel that is already open alone: it is the user's")
  func alreadyOpen() {
    let zoom = FakeZoom(label: "Close participants panel, opened, 2 participants")
    zoom.rows = Self.usual
    let result = zoom.run()
    #expect(result.refusal == .notInState)
    #expect(zoom.presses.isEmpty)
  }

  @Test("a stop before the press presses nothing; after the press the close still runs")
  func stopping() {
    let before = FakeZoom()
    before.rows = Self.usual
    #expect(before.run(stop: { true }).refusal == .skipped)
    #expect(before.presses.isEmpty)

    // The stop arrives after the open press: polling ends, the panel is still closed.
    let after = FakeZoom()
    after.rows = Self.usual
    after.rowsDelay = .milliseconds(200)
    let result = after.run(stop: { after.presses.count >= 1 })
    #expect(result.pressedOpen)
    #expect(result.learned == nil)
    #expect(result.panelClosed == true)
    #expect(after.presses == [FakeZoom.button, FakeZoom.button])
  }

  @Test("a press that could not complete may still have opened the panel")
  func indeterminateOpen() {
    let zoom = FakeZoom()
    zoom.rows = Self.usual
    zoom.pressAnswer = .indeterminate
    let result = zoom.run()
    #expect(result.pressedOpen)
    #expect(result.learned == "Saurabh Vaish")
    #expect(result.panelClosed == true)
    #expect(zoom.presses.count == 2)

    let refused = FakeZoom()
    refused.pressAnswer = .refused
    refused.pressOpens = false
    #expect(refused.run().refusal == .pressFailed)
    #expect(refused.presses.count == 1)
  }

  @Test("rows drawn late are still read before the deadline")
  func lateRows() {
    let zoom = FakeZoom()
    zoom.rows = Self.usual
    zoom.rowsDelay = .milliseconds(200)
    let result = zoom.run()
    #expect(result.learned == "Saurabh Vaish")
    #expect(result.elapsedMs >= 200)
    #expect(zoom.pauses.isEmpty == false)
  }

  @Test("only a complete copy with exactly one bound (me) row teaches a name")
  func onlyCompleteBoundRows() {
    // The list's rows cannot be read: the copy is unreadable, never complete.
    let broken = FakeZoom()
    broken.rows = Self.usual
    broken.failing = ["\(FakeZoom.panel).AXChildren"]
    let unreadable = broken.run()
    #expect(unreadable.learned == nil)
    #expect(unreadable.panelClosed == true, "the panel it opened is still closed")

    // A row Zoom has not bound to anyone.
    let unbound = FakeZoom()
    unbound.rows = [Self.row("Saurabh Vaish (Host, me)", bound: false), Self.row("Bea Chen")]
    #expect(unbound.run().learned == nil)

    // Two rows marked (me), even with the same name.
    let twice = FakeZoom()
    twice.rows = [Self.row("Saurabh Vaish (me)"), Self.row("Saurabh Vaish (me)")]
    #expect(twice.run().learned == nil)
    #expect(twice.presses.count == 2)
  }

  @Test("no poll starts after the deadline, and an AX message may overrun it")
  func deadline() throws {
    let zoom = FakeZoom()
    zoom.rows = [Self.row("Bea Chen")]
    let result = zoom.run()
    #expect(result.learned == nil)
    #expect(result.panelClosed == true)
    let deadline = try #require(zoom.pressedAt.first) + .milliseconds(600)
    #expect(zoom.pauses.isEmpty == false)
    // Every gap before a poll started before the deadline.
    #expect(zoom.pauses.allSatisfy { $0 < deadline })
    #expect(result.elapsedMs >= 600)

    // One slow read inside the first copy runs past the deadline; no new poll follows it.
    let slow = FakeZoom()
    slow.rows = Self.usual
    slow.slow["\(FakeZoom.panel).AXChildren"] = .milliseconds(700)
    let overrun = slow.run()
    #expect(overrun.elapsedMs > 700)
    #expect(overrun.learned == nil, "a copy cut short by its budget never teaches a name")
    #expect(slow.pauses.isEmpty)
    #expect(overrun.panelClosed == true)
  }

  @Test("a panel the user closes during the poll is not pressed again")
  func userCloses() {
    let zoom = FakeZoom()
    zoom.rows = Self.usual
    zoom.rowsDelay = .milliseconds(400)
    zoom.onPause = { z in
      if z.pauses.count == 2 {
        z.setLabel("Open participants panel, closed, 2 participants")
        z.children[FakeZoom.meeting]?.removeAll { $0 == FakeZoom.panel }
      }
    }
    let result = zoom.run()
    #expect(result.userClosed)
    #expect(result.panelClosed == true)
    #expect(zoom.presses == [FakeZoom.button])

    // Closed before the first look after the press: no polling, no close press.
    let early = FakeZoom()
    early.rows = Self.usual
    let quick = ZoomSelfProbe.run(
      app: FakeZoom.app, access: early.access(),
      press: { id in
        let answer = early.press(id)
        // The user's own click lands right behind the probe's.
        early.setLabel("Open participants panel, closed, 2 participants")
        early.children[FakeZoom.meeting]?.removeAll { $0 == FakeZoom.panel }
        return answer
      },
      pause: { gap in
        early.pauses.append(early.offset)
        early.offset += gap
      }, protectedRoles: [], shouldStop: { false })
    #expect(quick.userClosed)
    #expect(quick.learned == nil)
    #expect(early.presses == [FakeZoom.button])
    #expect(early.pauses.isEmpty)
  }

  @Test("one close press only: a close that does not take, or cannot be read, is reported")
  func oneClose() {
    let stuck = FakeZoom()
    stuck.rows = Self.usual
    stuck.pressCloses = false
    #expect(stuck.run().panelClosed == false)
    #expect(stuck.presses == [FakeZoom.button, FakeZoom.button])

    let blind = FakeZoom()
    blind.rows = Self.usual
    blind.blindAfterClose = true
    #expect(blind.run().panelClosed == nil)
    #expect(blind.presses == [FakeZoom.button, FakeZoom.button])
  }

  @Test("a replaced meeting window ends the poll and is never pressed")
  func replacedWindow() {
    let zoom = FakeZoom()
    zoom.rows = Self.usual
    zoom.rowsDelay = .milliseconds(400)
    zoom.onPause = { z in
      guard z.windows == [FakeZoom.meeting] else { return }
      // Zoom drops the meeting window and shows a new one with its own open panel button.
      z.texts[30] = [.role: "AXWindow", .identifier: "zm.meeting.window.main"]
      z.texts[31] = [
        .role: "AXButton", .identifier: "participant",
        .description: "Close participants panel, opened, 2 participants",
      ]
      z.children[30] = [31]
      z.windows = [30]
    }
    let result = zoom.run()
    #expect(result.learned == nil)
    #expect(result.panelClosed == nil)
    #expect(zoom.presses == [FakeZoom.button], "the replacement's button is never pressed")
  }
}
