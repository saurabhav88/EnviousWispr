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
    /// Every `id.attribute` the walk asked for.
    var queried: Set<String> = []
    var ticks = 0
    var tickPerRead: Duration = .zero
    let start = ContinuousClock.now

    func access() -> CallAXTreeAccess<Int> {
      CallAXTreeAccess<Int>(
        read: { [self] id, attribute in
          ticks += 1
          queried.insert("\(id).\(attribute.rawValue)")
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
    policy: CallAXCapturePolicy = .standard, keepPage: @escaping (String) -> Bool = { _ in true }
  ) -> CallAXCapture {
    var host: UInt64 = 100
    return CallSpeakerCapture.capture(
      windows: windows, access: tree.access(), bounds: bounds, policy: policy, keepPage: keepPage,
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
      participants: [
        CallParticipant(key: "0", name: "Alex Rivera", isTalking: false, isSelf: false)
      ],
      participantIdentityEstablished: true, sharedNames: ["Alex Rivera"])
    log.add(proof, context: Self.good, observationMs: 2)
    log.add(reading([("Alex Rivera", true)]), context: Self.good, observationMs: 3)
    #expect(log.log.roster.names.filter { $0 == "Alex Rivera" }.count == 2)
    #expect(MeetingSpeakerNamer.uniqueRosterNames(log.log.roster).isEmpty)
  }

  // MARK: - Presence and health (13B)

  /// A complete participant list showing `names`, nobody talking.
  private func list(_ names: [String], complete: Bool = true) -> CallSpeakerReading {
    CallSpeakerReading(
      speaking: [], roster: CallSpeakerRoster(names: names, selfNames: []),
      rosterFromParticipantList: complete,
      participants: names.enumerated().map {
        CallParticipant(key: "\($0.offset)", name: $0.element, isTalking: false, isSelf: false)
      },
      participantIdentityEstablished: true, sharedNames: [], participantListComplete: complete)
  }

  private func presence(_ log: CallSpeakerAccumulator, _ name: String) -> CallNamePresence? {
    log.log.segments.first?.presence?.first { $0.name == name }
  }

  @Test("a late joiner's first sighting is when the list first showed them")
  func lateJoin() {
    var log = CallSpeakerAccumulator(surface: .teamsApp, rules: nil, lag: nil)
    log.add(list(["Alex Rivera"]), context: Self.good, observationMs: 1_000)
    log.add(list(["Alex Rivera", "Priya Shah"]), context: Self.good, observationMs: 4_000)
    log.add(list(["Alex Rivera", "Priya Shah"]), context: Self.good, observationMs: 4_500)
    #expect(
      presence(log, "Priya Shah")?.sightings == [
        .init(firstSeenMs: 4_000, lastSeenMs: 4_500, absenceConfirmed: false)
      ])
    #expect(presence(log, "Alex Rivera")?.sightings.first?.firstSeenMs == 1_000)
  }

  @Test("one or two missing lists never close a sighting; three over a second do; return reopens")
  func leaveAndReturn() {
    var log = CallSpeakerAccumulator(surface: .teamsApp, rules: nil, lag: nil)
    log.add(list(["Alex Rivera", "Priya Shah"]), context: Self.good, observationMs: 1_000)
    log.add(list(["Alex Rivera"]), context: Self.good, observationMs: 1_500)
    log.add(list(["Alex Rivera", "Priya Shah"]), context: Self.good, observationMs: 2_000)
    #expect(
      presence(log, "Priya Shah")?.absences.isEmpty == true, "one missing list is not a leave")
    for ms in [2_500, 3_000] {
      log.add(list(["Alex Rivera"]), context: Self.good, observationMs: ms)
    }
    #expect(presence(log, "Priya Shah")?.absences.isEmpty == true, "two lists over 500 ms")
    log.add(list(["Alex Rivera"]), context: Self.good, observationMs: 3_500)
    let gone = presence(log, "Priya Shah")
    #expect(gone?.absences == [.init(firstMissingMs: 2_500, confirmedAtMs: 3_500)])
    #expect(
      gone?.sightings == [.init(firstSeenMs: 1_000, lastSeenMs: 2_000, absenceConfirmed: true)])
    #expect(gone?.isConfirmedAbsent(at: 3_000) == true)
    log.add(list(["Alex Rivera", "Priya Shah"]), context: Self.good, observationMs: 9_000)
    let back = presence(log, "Priya Shah")
    #expect(back?.sightings.count == 2)
    #expect(
      back?.sightings.last == .init(firstSeenMs: 9_000, lastSeenMs: 9_000, absenceConfirmed: false))
    #expect(back?.isConfirmedAbsent(at: 8_999) == true)
    #expect(back?.isConfirmedAbsent(at: 9_000) == false)
    #expect(back?.isConfirmedAbsent(at: 500) == false, "before the first sighting is not absence")
  }

  @Test(
    "tiles only, a partial list, a gap, an unreadable copy or a dictation pause never prove a leave"
  )
  func noLeaveWithoutCompleteLists() {
    // Tiles only: never.
    var tiles = CallSpeakerAccumulator(surface: .meet, rules: nil, lag: nil)
    tiles.add(
      list(["Alex Rivera", "Priya Shah"], complete: false), context: Self.good, observationMs: 0)
    for ms in stride(from: 500, through: 5_000, by: 500) {
      tiles.add(list(["Alex Rivera"], complete: false), context: Self.good, observationMs: ms)
    }
    #expect(presence(tiles, "Priya Shah")?.absences.isEmpty == true)

    // Each break restarts the run of three.
    func run(_ interrupt: (inout CallSpeakerAccumulator) -> Void) -> CallSpeakerAccumulator {
      var log = CallSpeakerAccumulator(surface: .teamsApp, rules: nil, lag: nil)
      log.add(list(["Alex Rivera", "Priya Shah"]), context: Self.good, observationMs: 0)
      log.add(list(["Alex Rivera"]), context: Self.good, observationMs: 500)
      log.add(list(["Alex Rivera"]), context: Self.good, observationMs: 1_000)
      interrupt(&log)
      log.add(list(["Alex Rivera"]), context: Self.good, observationMs: 1_500)
      return log
    }
    let unreadable = run {
      $0.add(
        nil, context: CallCaptureContext(completeness: .unreadable, scope: .resolved),
        observationMs: 1_200)
    }
    #expect(presence(unreadable, "Priya Shah")?.absences.isEmpty == true)
    let dictation = run { $0.noteDictationSkip() }
    #expect(presence(dictation, "Priya Shah")?.absences.isEmpty == true)
    let stale = run { $0.noteStaleDrop() }
    #expect(presence(stale, "Priya Shah")?.absences.isEmpty == true)
    let partial = run {
      $0.add(list(["Alex Rivera"], complete: false), context: Self.good, observationMs: 1_200)
    }
    #expect(presence(partial, "Priya Shah")?.absences.isEmpty == true)
    let control = run { _ in }
    #expect(
      presence(control, "Priya Shah")?.absences.count == 1, "without a break the run confirms")

    // A list read more than 1.5 s after the one before starts a new run.
    var gap = CallSpeakerAccumulator(surface: .teamsApp, rules: nil, lag: nil)
    gap.add(list(["Alex Rivera", "Priya Shah"]), context: Self.good, observationMs: 0)
    for ms in [500, 1_000, 3_000] {
      gap.add(list(["Alex Rivera"]), context: Self.good, observationMs: ms)
    }
    #expect(presence(gap, "Priya Shah")?.absences.isEmpty == true)
  }

  @Test("an interruption between lists restarts the run")
  func interruptionBreaksRun() {
    var log = CallSpeakerAccumulator(surface: .teamsApp, rules: nil, lag: nil)
    log.add(list(["Alex Rivera", "Priya Shah"]), context: Self.good, observationMs: 0)
    log.add(list(["Alex Rivera"]), context: Self.good, observationMs: 500)
    log.add(list(["Alex Rivera"]), context: Self.good, observationMs: 1_000)
    log.noteInterruption()
    log.add(list(["Alex Rivera"]), context: Self.good, observationMs: 1_500)
    #expect(presence(log, "Priya Shah")?.absences.isEmpty == true)
  }

  @Test("a name seen again after its sightings are full is no longer treated as gone")
  func sightingsFull() throws {
    var log = CallSpeakerAccumulator(surface: .teamsApp, rules: nil, lag: nil)
    var ms = 0
    for _ in 0..<CallNamePresence.maximumSightings {
      log.add(list(["Alex Rivera", "Priya Shah"]), context: Self.good, observationMs: ms)
      for _ in 0..<3 {
        ms += 500
        log.add(list(["Alex Rivera"]), context: Self.good, observationMs: ms)
      }
      ms += 500
    }
    #expect(presence(log, "Priya Shah")?.sightings.count == CallNamePresence.maximumSightings)
    let last = ms
    log.add(list(["Alex Rivera", "Priya Shah"]), context: Self.good, observationMs: last)
    let saved = try #require(presence(log, "Priya Shah"))
    #expect(saved.sightingsFull == true)
    #expect(!saved.isConfirmedAbsent(at: last + 1_000), "seen again: not known to be gone")
    let back = try JSONDecoder().decode(
      CallSpeakerLog.self, from: JSONEncoder().encode(log.log))
    #expect(back.segments.first?.presence?.first { $0.name == "Priya Shah" }?.sightingsFull == true)
  }

  @Test("health counts every capture, admission and skipped tick, with no names")
  func healthCounts() {
    var log = CallSpeakerAccumulator(surface: .meet, rules: nil, lag: nil)
    log.add(reading([("Alex Rivera", true)]), context: Self.good, observationMs: 1)
    log.add(reading([("Alex Rivera", false)]), context: Self.good, observationMs: 2)
    log.add(
      reading([("Alex Rivera", true), ("Alex Rivera", false)]), context: Self.good,
      observationMs: 3)
    log.add(
      nil, context: CallCaptureContext(completeness: .truncated, scope: .resolved), observationMs: 4
    )
    log.add(
      nil, context: CallCaptureContext(completeness: .complete, scope: .unresolved),
      observationMs: 5)
    log.noteBusySkip()
    log.noteDictationSkip()
    log.noteNoPermission()
    log.noteStaleDrop()
    log.noteWalk(durationUs: 300, nodes: 40)
    log.noteWalk(durationUs: 100, nodes: 90)
    let health = log.log.segments.first?.health
    #expect(health?.captureAttempts == 5)
    #expect(health?.completeCaptures == 4)
    #expect(health?.truncatedCaptures == 1)
    #expect(health?.unresolvedScopeCaptures == 1)
    #expect(health?.admittedSpeakingObservations == 1)
    #expect(health?.admittedQuietObservations == 1)
    #expect(health?.withheldByReason == ["ambiguousTalker": 1])
    #expect(health?.skippedBusyTicks == 1)
    #expect(health?.skippedDictationTicks == 1)
    #expect(health?.missingPermissionTicks == 1)
    #expect(health?.staleResultDrops == 1)
    #expect(health?.walkDurationCount == 2)
    #expect(health?.walkDurationTotalUs == 400)
    #expect(health?.walkDurationMaxUs == 300)
    #expect(health?.nodesVisitedTotal == 130)
    #expect(health?.nodesVisitedMax == 90)
    #expect(log.log.presencePolicy == .current)
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
        root: CallAXNode(
          role: "AXWindow", children: [CallAXNode(role: "AXGroup", description: label)]))
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
        title: "Zoom Meeting",
        root: CallAXNode(role: "AXWindow", identifier: "zm.meeting.window.main"))
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

  // MARK: - Capacity (#4013 13B.5)

  @Test(
    "a reading that would pass a cap is not kept at all, and collection stops keeping what it had")
  func capacityIsWholeReading() {
    var limits = CallEvidenceLimits.current
    limits.names = 3
    var log = CallSpeakerAccumulator(surface: .meet, rules: nil, lag: nil, limits: limits)
    log.add(
      reading([("Alex Rivera", true), ("Priya Shah", false)]), context: Self.good,
      observationMs: 1_000)
    let kept = log.log
    log.add(
      reading([("Alex Rivera", true), ("Sam", false), ("Dana Okafor", false)]), context: Self.good,
      observationMs: 1_500)
    #expect(log.capacityReached == .names)
    #expect(log.log.roster == kept.roster, "no part of the reading is kept")
    #expect(log.log.observations == kept.observations)
    #expect(log.log.segments.first?.presence == kept.segments.first?.presence)
    log.add(reading([("Alex Rivera", true)]), context: Self.good, observationMs: 2_000)
    #expect(log.log.observations == kept.observations, "stopped for good")
    #expect(log.health.evidenceCapacityDrops == 2)
    #expect(log.log.shapeProblem == nil)
  }

  @Test("each cap stops collection at the reading that would pass it")
  func eachCap() {
    func reached(
      _ set: (inout CallEvidenceLimits) -> Void, baseline: CallEvidenceUsage = .init(),
      _ readings: [CallSpeakerReading]
    ) -> CallEvidenceCapacity? {
      var limits = CallEvidenceLimits.current
      set(&limits)
      var log = CallSpeakerAccumulator(
        surface: .meet, rules: nil, lag: nil, limits: limits, baseline: baseline)
      for (n, reading) in readings.enumerated() {
        log.add(reading, context: Self.good, observationMs: 1_000 + n * 500)
      }
      return log.capacityReached
    }
    let alex = reading([("Alex Rivera", true)])
    let priya = reading([("Priya Shah", true), ("Alex Rivera", false)])
    #expect(reached({ $0.runs = 1 }, [alex, alex]) == nil, "control: one run")
    #expect(reached({ $0.runs = 1 }, [alex, priya]) == .runs)
    #expect(reached({ $0.samples = 2 }, [alex, alex, alex]) == .samples)
    #expect(reached({ $0.speakingReferences = 1 }, [alex, priya]) == .speakingReferences)
    #expect(reached({ $0.rosterReferences = 1 }, [priya]) == .rosterReferences)
    #expect(reached({ $0.presenceEntries = 1 }, [priya]) == .presenceEntries)
    var earlier = CallEvidenceUsage()
    earlier.insertNames(["Dana Okafor", "Sam"])
    #expect(
      reached({ $0.names = 3 }, baseline: earlier, [priya]) == .names,
      "earlier segments count too")
  }

  @Test("a reading with a name too long for the log is not kept and proves no one left")
  func overlongName() {
    var log = CallSpeakerAccumulator(surface: .meet, rules: nil, lag: nil)
    log.add(reading([("Alex Rivera", true)]), context: Self.good, observationMs: 1_000)
    let kept = log.log
    log.add(
      reading([(String(repeating: "x", count: 300), true)]), context: Self.good,
      observationMs: 1_500)
    #expect(log.log.roster == kept.roster)
    #expect(log.log.observations == kept.observations)
    #expect(log.log.segments.first?.presence == kept.segments.first?.presence)
    #expect(log.health.invalidNameReadings == 1)
    #expect(log.capacityReached == nil)
  }

  // MARK: - Zoom app policy (#4013 13B runtime receipt)

  /// The live Zoom app as measured on 2026-10-29: a meeting window with a talking tile, the
  /// "End" and "More meeting controls" buttons whose children fail to read, the participants
  /// list (with a button inside it), and the home window whose banner's identifier fails.
  private static func zoomTree() -> Tree {
    let tree = Tree()
    tree.node(1, "AXWindow", children: [2, 3, 4, 5, 10])
    tree.texts[1] = [.identifier: "zm.meeting.window.main", .title: "Zoom Meeting"]
    tree.node(2, "AXTabGroup")
    tree.texts[2] = [.title: "Alex Rivera, Computer audio unmuted, Video off, active speaker"]
    tree.node(3, "AXButton")
    tree.texts[3] = [.title: "End"]
    tree.node(4, "AXButton")
    tree.texts[4] = [.title: "More meeting controls, collapsed"]
    tree.failing = ["3.AXChildren", "4.AXChildren", "21.AXIdentifier"]
    tree.node(5, "AXOutline", children: [6, 7, 8])
    tree.texts[5] = [.description: "Participants list"]
    tree.node(6, "AXStaticText")
    tree.texts[6] = [.value: "Alex Rivera"]
    tree.node(7, "AXStaticText")
    tree.texts[7] = [.value: "Priya Shah"]
    tree.node(8, "AXButton", children: [9])
    tree.node(9, "AXImage")
    tree.node(10, "AXStaticText")
    tree.texts[10] = [.value: "Participants (2)"]
    tree.node(20, "AXWindow", children: [21])
    tree.texts[20] = [.title: "Zoom Workplace"]
    tree.node(21, "AXUnknown")
    return tree
  }

  @Test("the Zoom app copy leaves out its home window and toolbar buttons and reads the call")
  func zoomPolicyReadsTheCall() throws {
    let tree = Self.zoomTree()
    let copy = capture(tree, windows: [1, 20], policy: .zoomApp)
    #expect(copy.completeness == .complete)
    #expect(!tree.queried.contains("3.AXChildren"))
    #expect(!tree.queried.contains("4.AXChildren"))
    #expect(!tree.queried.contains("21.AXIdentifier"), "the home window is never walked")
    #expect(tree.queried.contains("8.AXChildren"), "a button inside the list is still read")
    #expect(copy.prunedControls == 2)
    #expect(copy.skippedWindows == 1)
    #expect(copy.failedReads == 0)
    let reading = ZoomAppSpeakerReader.read(windows: copy.windows)
    #expect(reading.roster.names == ["Alex Rivera", "Priya Shah"])
    #expect(reading.speaking == ["Alex Rivera"])
    #expect(reading.participantListComplete)
    // Control: read whole, the same app is unreadable.
    let whole = Self.zoomTree()
    #expect(capture(whole, windows: [1, 20]).completeness == .unreadable)
  }

  @Test("under the Zoom policy a failed read the call needs still makes the copy unreadable")
  func zoomPolicyKeepsRealFailures() {
    for failing in ["6.AXValue", "5.AXChildren", "8.AXChildren", "2.AXRole"] {
      let tree = Self.zoomTree()
      tree.failing.insert(failing)
      #expect(
        capture(tree, windows: [1, 20], policy: .zoomApp).completeness == .unreadable,
        "\(failing)")
    }
    // A window that only looks like home (it has an identifier) is walked.
    let tree = Self.zoomTree()
    tree.texts[20] = [.title: "Zoom Workplace", .identifier: "zm.other"]
    #expect(capture(tree, windows: [1, 20], policy: .zoomApp).completeness == .unreadable)
  }

  @Test("only the Zoom app gets the Zoom policy")
  func zoomPolicySelection() {
    #expect(
      CallSpeakerSurfaceChoice.capturePolicy(family: .zoom, rule: .callWindow(.zoom)) == .zoomApp)
    #expect(
      CallSpeakerSurfaceChoice.capturePolicy(family: .zoom, rule: .browser(.chrome)) == .standard)
    #expect(
      CallSpeakerSurfaceChoice.capturePolicy(family: .teams, rule: .callApp(.teams)) == .standard)
  }
}
