import Darwin
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline
@testable import EnviousWisprServices

/// #4013 chunk 13A: when these fail, a live speaker copy can run forever on a looping or huge
/// tree, copy another web page's content, pass a broken copy off as complete, place a reading
/// at the wrong meeting time, or save names it should not (a repeated view counted as two
/// people, a known shared name forgotten, a withheld reading saved as quiet).
///
/// Trees are SYNTHETIC literal trees read through the same walker the live copy uses.
@Suite("Speaker capture and evidence", .tags(.productOutcome))
struct CallSpeakerCaptureTests {

  /// A literal tree: element ids, their attributes and children. `hashes` lets two elements
  /// share a hash; `failing` makes reads of an attribute fail.
  final class Tree {
    var roles: [Int: String] = [:]
    var texts: [Int: [CallAXAttribute: String]] = [:]
    var classes: [Int: [String]] = [:]
    var children: [Int: [Int]] = [:]
    var hashes: [Int: Int] = [:]
    var failing: Set<String> = []
    var ticks = 0
    var tickPerRead: Duration = .zero
    let start = ContinuousClock.now

    func access() -> CallAXTreeAccess<Int> {
      CallAXTreeAccess<Int>(
        read: { [self] id, attribute in
          ticks += 1
          if failing.contains("\(id).\(attribute.rawValue)") { return .failed }
          switch attribute {
          case .role: return roles[id].map { .text($0) } ?? .missing
          case .children: return .elements(children[id] ?? [])
          case .domClassList: return classes[id].map { .texts($0) } ?? .missing
          case .size: return .missing
          default: return texts[id]?[attribute].map { .text($0) } ?? .missing
          }
        },
        hash: { [self] in hashes[$0] ?? $0 }, same: { $0 == $1 },
        now: { [self] in start.advanced(by: tickPerRead * ticks) })
    }

    func node(_ id: Int, _ role: String = "AXGroup", children kids: [Int] = []) {
      roles[id] = role
      children[id] = kids
    }
  }

  private func capture(
    _ tree: Tree, windows: [Int] = [1], bounds: CallAXBounds = .standard,
    keepPage: @escaping (String) -> Bool = { _ in true }
  ) -> CallAXCapture {
    var host: UInt64 = 100
    return CallSpeakerCapture.capture(
      windows: windows, access: tree.access(), bounds: bounds, keepPage: keepPage,
      hostTime: {
        host += 10
        return host
      })
  }

  // MARK: - Walking

  @Test("a full small tree is complete; a missing optional attribute is not a failure")
  func completeTree() {
    let tree = Tree()
    tree.node(1, "AXWindow", children: [2, 3])
    tree.node(2, "AXButton")
    tree.node(3, "AXStaticText")
    tree.texts[3] = [.value: "Alex Rivera"]
    let copy = capture(tree)
    #expect(copy.completeness == .complete)
    #expect(copy.windows.first?.root.allNodes.count == 3)
    #expect(copy.windows.first?.root.children.last?.value == "Alex Rivera")
    #expect(copy.readEndHostTime > copy.readStartHostTime)
  }

  @Test("the node, depth and time bounds each stop the copy as truncated")
  func boundsTruncate() {
    let wide = Tree()
    wide.node(1, "AXWindow", children: Array(2...50))
    for id in 2...50 { wide.node(id) }
    #expect(
      capture(wide, bounds: CallAXBounds(maxNodes: 10, maxDepth: 64, budget: .seconds(5)))
        .completeness == .truncated)

    let deep = Tree()
    for id in 1...20 { deep.node(id, children: id < 20 ? [id + 1] : []) }
    #expect(
      capture(deep, bounds: CallAXBounds(maxNodes: 1_000, maxDepth: 5, budget: .seconds(5)))
        .completeness == .truncated)

    let slow = Tree()
    slow.tickPerRead = .milliseconds(10)
    slow.node(1, "AXWindow", children: Array(2...40))
    for id in 2...40 { slow.node(id) }
    #expect(
      capture(slow, bounds: CallAXBounds(maxNodes: 1_000, maxDepth: 64, budget: .milliseconds(100)))
        .completeness == .truncated)
  }

  @Test("a single slow last element still makes the copy truncated")
  func slowLastLeaf() {
    let tree = Tree()
    tree.node(1, "AXWindow")
    // Each read advances the clock 50 ms: the one element's eight reads end past 100 ms.
    tree.tickPerRead = .milliseconds(50)
    #expect(
      capture(tree, bounds: CallAXBounds(maxNodes: 1_000, maxDepth: 64, budget: .milliseconds(100)))
        .completeness == .truncated)
  }

  @Test("once the budget is spent the app is asked nothing more")
  func noReadsPastBudget() {
    let tree = Tree()
    tree.node(1, "AXWindow", children: Array(2...40))
    for id in 2...40 { tree.node(id) }
    tree.tickPerRead = .milliseconds(10)
    let copy = capture(
      tree, bounds: CallAXBounds(maxNodes: 1_000, maxDepth: 64, budget: .milliseconds(100)))
    #expect(copy.completeness == .truncated)
    // Ten reads fit the budget; the read that finds it spent is not sent.
    #expect(tree.ticks <= 10)
  }

  @Test("a failed role, children or optional read makes the copy unreadable")
  func failedReadsAreUnreadable() {
    for failing in ["2.AXRole", "1.AXChildren", "2.AXTitle"] {
      let tree = Tree()
      tree.node(1, "AXWindow", children: [2])
      tree.node(2)
      tree.failing = [failing]
      #expect(capture(tree).completeness == .unreadable, "\(failing)")
    }
  }

  @Test("a cycle is copied once; elements sharing a hash are still each copied")
  func cyclesAndCollisions() {
    let tree = Tree()
    tree.node(1, "AXWindow", children: [2, 3, 4])
    tree.node(2, children: [1])
    tree.node(3, children: [2])
    tree.node(4)
    tree.hashes = [1: 7, 2: 7, 3: 7, 4: 7]
    let copy = capture(tree)
    #expect(copy.completeness == .complete)
    #expect(copy.windows.first?.root.allNodes.count == 4)
  }

  @Test("only the meeting page is copied below its own node, and kept as a page")
  func onlyTheMeetingPage() {
    let tree = Tree()
    tree.node(1, "AXWindow", children: [2, 5])
    tree.node(2, "AXWebArea", children: [3])
    tree.texts[2] = [.url: "https://meet.google.com/abc-defg-hij"]
    tree.node(3, "AXStaticText")
    tree.node(5, "AXWebArea", children: [6])
    tree.texts[5] = [.url: "https://mail.google.com/"]
    tree.node(6, "AXStaticText")
    tree.texts[6] = [.value: "an email"]
    let copy = capture(tree) { CallSpeakerSurfaceChoice.isMeetingPage($0, family: .googleMeet) }
    #expect(copy.completeness == .complete)
    #expect(copy.documents.map(\.url) == ["https://meet.google.com/abc-defg-hij"])
    let mail = copy.windows.first?.root.children.last
    #expect(mail?.role == "AXWebArea")
    #expect(mail?.children.isEmpty == true, "the other page's content is not copied")
  }

  // MARK: - Timeline

  @Test("a reading's meeting time is the middle of its reads after the anchor; before it, none")
  func timeline() {
    let base = mach_timebase_info_data_t(numer: 1, denom: 1)
    #expect(
      CallSpeakerTimeline.observationMs(
        readStart: 3_000_000_000, readEnd: 3_002_000_000, anchor: 1_000_000_000, timebase: base)
        == 2_001)
    #expect(
      CallSpeakerTimeline.observationMs(
        readStart: 999_000_000, readEnd: 1_001_000_000, anchor: 1_000_000_000, timebase: base)
        == nil)
    let scaled = mach_timebase_info_data_t(numer: 125, denom: 3)
    #expect(
      CallSpeakerTimeline.observationMs(
        readStart: 24_000_000, readEnd: 24_000_000, anchor: 0, timebase: scaled) == 1_000)
  }

  // MARK: - Accumulation

  private static let good = CallCaptureContext(completeness: .complete, scope: .resolved)

  private func reading(_ names: [(String, Bool)], selfName: String? = nil) -> CallSpeakerReading {
    let participants = names.enumerated().map {
      CallParticipant(
        key: "\($0.offset)", name: $0.element.0, isTalking: $0.element.1,
        isSelf: $0.element.0 == selfName)
    }
    return CallSpeakerReading(
      speaking: names.filter(\.1).map(\.0),
      roster: CallSpeakerRoster(names: names.map(\.0), selfNames: selfName.map { [$0] } ?? []),
      rosterFromParticipantList: false, participants: participants,
      participantIdentityEstablished: true, sharedNames: [])
  }

  @Test("withheld readings add no observation; quiet ones add an empty one")
  func withheldAndQuiet() {
    var log = CallSpeakerAccumulator(surface: .meet, rules: nil, lag: nil)
    log.add(reading([("Alex Rivera", true)]), context: Self.good, observationMs: 1_000)
    log.add(reading([("Alex Rivera", false)]), context: Self.good, observationMs: 1_500)
    log.add(
      reading([("Alex Rivera", true), ("Alex Rivera", false)]), context: Self.good,
      observationMs: 2_000)
    log.add(
      reading([("Priya Shah", true)]),
      context: CallCaptureContext(completeness: .truncated, scope: .resolved), observationMs: 2_500)
    #expect(
      log.log.observations == [
        CallSpeakerObservation(observationMs: 1_000, speaking: ["Alex Rivera"]),
        CallSpeakerObservation(observationMs: 1_500, speaking: []),
      ])
    #expect(log.status == .observed)
  }

  @Test("the roster keeps each name as often as one reading showed it, and keeps self names")
  func rosterAccumulation() {
    var log = CallSpeakerAccumulator(surface: .meet, rules: nil, lag: nil)
    log.add(
      reading([("Alex Rivera", false), ("Sam", false)], selfName: "Sam"), context: Self.good,
      observationMs: 1)
    log.add(reading([("Alex Rivera", false)]), context: Self.good, observationMs: 2)
    #expect(log.log.roster.names == ["Alex Rivera", "Sam"], "a repeated view is one person")
    log.add(
      reading([("Alex Rivera", false), ("Alex Rivera", false)]), context: Self.good,
      observationMs: 3)
    log.add(reading([("Alex Rivera", false)]), context: Self.good, observationMs: 4)
    #expect(
      log.log.roster.names.filter { $0 == "Alex Rivera" }.count == 2,
      "two people sharing a name stay two")
    #expect(log.log.roster.selfNames == ["Sam"])
  }

  @Test("a name a reader proved two people share is never nameable, even after a single view")
  func sharedNamesStay() {
    var log = CallSpeakerAccumulator(surface: .meet, rules: nil, lag: nil)
    log.add(reading([("Alex Rivera", true)]), context: Self.good, observationMs: 1)
    let proof = CallSpeakerReading(
      speaking: [], roster: CallSpeakerRoster(names: ["Alex Rivera"], selfNames: []),
      rosterFromParticipantList: false,
      participants: [CallParticipant(key: "0", name: "Alex Rivera", isTalking: false, isSelf: false)],
      participantIdentityEstablished: true, sharedNames: ["Alex Rivera"])
    log.add(proof, context: Self.good, observationMs: 2)
    log.add(reading([("Alex Rivera", true)]), context: Self.good, observationMs: 3)
    #expect(log.log.roster.names.filter { $0 == "Alex Rivera" }.count == 2)
    #expect(MeetingSpeakerNamer.uniqueRosterNames(log.log.roster).isEmpty)
  }

  @Test("status: unreadable copies only, then observed; no permission only before any use")
  func status() {
    var log = CallSpeakerAccumulator(surface: .meet, rules: nil, lag: nil)
    log.add(
      nil, context: CallCaptureContext(completeness: .unreadable, scope: .resolved),
      observationMs: 1)
    #expect(log.status == .unreadable)
    log.noteNoPermission()
    #expect(log.status == .noPermission)
    log.add(reading([("Alex Rivera", false)]), context: Self.good, observationMs: 2)
    #expect(log.status == .observed)
    log.noteNoPermission()
    #expect(log.status == .observed, "earlier evidence is not erased")
  }

  @Test("Teams app: the compact view and its main window are one meeting; two meetings are not")
  func teamsAppScope() {
    func window(_ title: String?, _ label: String) -> CallAXWindow {
      CallAXWindow(
        title: title,
        root: CallAXNode(role: "AXWindow", children: [CallAXNode(role: "AXGroup", description: label)]))
    }
    func scope(_ windows: [CallAXWindow]) -> CallCaptureContext.Scope {
      CallSpeakerSurfaceReader.scope(
        surface: .teamsApp,
        capture: CallAXCapture(
          windows: windows, documents: [], completeness: .complete, readStartHostTime: 0,
          readEndHostTime: 0),
        family: .teams)
    }
    let compact = window(
      "Meeting compact view | Meeting with Saurabh Vaish", "Alex Rivera (Guest) is speaking")
    let main = window("Meeting with Saurabh Vaish", "Priya Shah is speaking")
    let other = window("Weekly sync", "Sam Lee is speaking")
    let chat = window("Chat | Microsoft Teams", "nothing a reader reads")
    #expect(scope([compact, main, chat]) == .resolved)
    #expect(scope([compact, other]) == .unresolved, "a held call and the current one")
    #expect(scope([window(nil, "Alex Rivera is speaking")]) == .unresolved)
  }

  @Test("Zoom app: exactly one meeting window, and no meeting content anywhere else")
  func zoomAppScope() {
    func meeting() -> CallAXWindow {
      CallAXWindow(
        title: "Zoom Meeting", root: CallAXNode(role: "AXWindow", identifier: "zm.meeting.window.main"))
    }
    func scope(_ windows: [CallAXWindow]) -> CallCaptureContext.Scope {
      CallSpeakerSurfaceReader.scope(
        surface: .zoomApp,
        capture: CallAXCapture(
          windows: windows, documents: [], completeness: .complete, readStartHostTime: 0,
          readEndHostTime: 0),
        family: .zoom)
    }
    let panel = CallAXWindow(
      title: "Participants (2)",
      root: CallAXNode(
        role: "AXWindow",
        children: [
          CallAXNode(
            role: "AXTabGroup",
            description: "Alex Rivera, Computer audio unmuted, Video off, active speaker")
        ]))
    let home = CallAXWindow(title: "Zoom Workplace", root: CallAXNode(role: "AXWindow"))
    #expect(scope([meeting(), home]) == .resolved)
    #expect(scope([meeting(), meeting()]) == .unresolved, "two meeting windows")
    #expect(scope([home]) == .unresolved, "no meeting window")
    #expect(scope([meeting(), panel]) == .unresolved, "meeting content in another window")
  }

  @Test("the surface comes from the call family and whether a browser held the microphone")
  func surfaceChoice() {
    #expect(CallSpeakerSurfaceChoice.surface(family: .zoom, rule: .callApp(.zoom)) == .zoomApp)
    #expect(CallSpeakerSurfaceChoice.surface(family: .zoom, rule: .browser(.chrome)) == .zoomWeb)
    #expect(CallSpeakerSurfaceChoice.surface(family: .teams, rule: .callApp(.teams)) == .teamsApp)
    #expect(CallSpeakerSurfaceChoice.surface(family: .teams, rule: .browser(.safari)) == .teamsWeb)
    #expect(CallSpeakerSurfaceChoice.surface(family: .googleMeet, rule: .browser(.chrome)) == .meet)
    #expect(
      CallSpeakerSurfaceChoice.surface(family: .googleMeet, rule: .callApp(.googleMeet)) == nil)
    #expect(CallSpeakerSurfaceChoice.source(for: .meet) == .rules)
    #expect(CallSpeakerSurfaceChoice.source(for: .zoomApp) == .app)
  }
}
