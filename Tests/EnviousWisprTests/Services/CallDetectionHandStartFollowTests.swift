import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprServices

/// #4342: a meeting recording started by hand (menu bar or History) is stopped by its call ending
/// only when it is linked to that call. When this fails, the user leaves Zoom, Teams or Meet and
/// the recording keeps running until they stop it by hand. Live tests on 2026-11-02 found most
/// early hand starts refused (`source_not_frozen`: the newest observation came from a sibling
/// process of the same call app), a call joined later never adopted, and a restart after a hand
/// Stop refused. Founder decisions D1-D4 (issue #4342).
@Suite("Call detection: a hand-started recording follows the call (#4342)", .tags(.productOutcome))
struct CallDetectionHandStartFollowTests {
  typealias Policy = CallDetectionPolicy
  typealias Story = CallDetectionPolicyTests.Story

  private static let main = CallDetectionPolicyTests.zoom(.active)
  /// A second process of the same Zoom run (mic off), as Zoom shows during every call.
  private static let siblingSource = Policy.Source(id: 101, pid: 101, rule: .callWindow(.zoom))
  private static var mainOwner: CallEvidenceReader.AppRun { Story.owner(for: main) }
  private static let teams = Policy.Holder(
    pid: 300, rule: .callApp(.teams), input: .active,
    evidence: .call(family: .teams, room: "pid-300"))

  private static func isLinked(_ s: Story, _ id: UUID) -> Bool {
    s.policy.episodes.contains { $0.phase == .recording(meetingID: id) }
  }

  private static func asksSwitch(_ s: Story) -> Bool {
    if case .switchCall = s.interaction { return true }
    return false
  }

  /// A hand start during one known call whose newest observation came from a sibling process.
  private static func startWithSiblingNewest(
    _ value: CallEvidenceReader.Continuity = .ongoing(family: .zoom, room: "w")
  ) -> (Story, UUID) {
    var s = Story()
    s.ongoing(main)
    let request = s.acceptManual()
    s.observeCall(value, holder: main, sourceObservation: (siblingSource, mainOwner))
    s.read([main])
    let id = UUID()
    s.meeting = .recording(meetingID: id)
    s.settleManual(request, recordingID: id)
    return (s, id)
  }

  @Test("a start links at once even when a sibling Zoom process was read last")
  func instantLinkDespiteSibling() {
    let (s, id) = Self.startWithSiblingNewest()
    #expect(s.policy.manualLink?.reason == .linked)
    #expect(Self.isLinked(s, id))
  }

  @Test("a sibling that says the call ended still refuses, and nothing follows it")
  func siblingEndedRefuses() {
    var (s, id) = Self.startWithSiblingNewest(.ended(family: .zoom, room: "w"))
    #expect(s.policy.manualLink?.reason == .endedAtSettle)
    s.wait(1)
    s.read([Self.main])
    #expect(!Self.isLinked(s, id))
  }

  @Test("a start whose frozen call was dropped still follows the live call on the next step")
  func invalidatedStartFollows() {
    var s = Story()
    s.ongoing(Self.main)
    let request = s.acceptManual()
    s.policy.invalidateAcceptedStart()
    let id = UUID()
    s.meeting = .recording(meetingID: id)
    s.settleManual(request, recordingID: id)
    #expect(s.policy.manualLink?.reason == .invalidated)
    #expect(!Self.isLinked(s, id))
    s.wait(1)
    s.read([Self.main])
    #expect(Self.isLinked(s, id))
    let links = s.policy.drainLaterLinks()
    #expect(
      links == [
        .init(recordingID: id, episode: links.first?.episode ?? -1, route: .menu, generation: 1)
      ])
    #expect(s.policy.drainLaterLinks().isEmpty)
  }

  @Test(
    "D1: a recording started before the call takes the call when it starts, with no Switch question"
  )
  func startBeforeCall() {
    var s = Story()
    let request = s.acceptManual(route: .history)
    let id = UUID()
    s.meeting = .recording(meetingID: id)
    s.settleManual(request, recordingID: id)
    #expect(s.policy.manualLink?.reason == .noCall)
    #expect(s.policy.callFacts(for: id).link == .noCall)
    s.wait(30)
    s.ongoing(Self.main)
    #expect(Self.isLinked(s, id))
    #expect(!Self.asksSwitch(s))
    #expect(s.policy.drainLaterLinks().map(\.route) == [.history])
    // meeting.ended must report the later link, not the start-time no_call.
    #expect(s.policy.callFacts(for: id).link == .manual)
  }

  @Test("D2: after a hand Stop, a new hand Start in the same call is linked")
  func restartAfterHandStop() {
    var s = Story()
    s.ongoing(Self.main)
    let first = s.acceptManual()
    let a = UUID()
    s.meeting = .recording(meetingID: a)
    s.settleManual(first, recordingID: a)
    #expect(Self.isLinked(s, a))
    s.meeting = .idle
    s.step()
    s.ongoing(Self.main)
    let second = s.acceptManual(generation: 2)
    let b = UUID()
    s.meeting = .recording(meetingID: b)
    s.settleManual(second, recordingID: b)
    #expect(s.policy.manualLink?.reason == .overridden)
    s.wait(1)
    s.read([Self.main])
    #expect(Self.isLinked(s, b))
  }

  @Test("D3: two live calls link nothing and ask nothing; when one is left, it is followed")
  func twoCallsWait() {
    var s = Story()
    let request = s.acceptManual()
    let id = UUID()
    s.meeting = .recording(meetingID: id)
    s.settleManual(request, recordingID: id)
    s.observeCall(.ongoing(family: .zoom, room: "w"), holder: Self.main)
    s.observeCall(.ongoing(family: .teams, room: "pid-300"), holder: Self.teams)
    s.ready([Self.main, Self.teams])
    s.hold([Self.main, Self.teams], for: 6)
    #expect(!Self.isLinked(s, id))
    #expect(!Self.asksSwitch(s))
    #expect(s.policy.drainLaterLinks().isEmpty)
    // Teams leaves; its last observation goes stale.
    s.wait(Policy.staleAfter + 1)
    s.observeCall(.ongoing(family: .zoom, room: "w"), holder: Self.main)
    s.read([Self.main])
    #expect(Self.isLinked(s, id))
  }

  @Test(
    "D3 at settlement: a second live call keeps the instant link from happening",
    arguments: [false, true])
  func secondCallAtSettlement(teamsFirst: Bool) {
    var s = Story()
    s.ongoing(Self.main)
    let request = s.acceptManual()
    if teamsFirst {
      s.observeCall(.ongoing(family: .teams, room: "pid-300"), holder: Self.teams)
      s.observeCall(.ongoing(family: .zoom, room: "w"), holder: Self.main)
    } else {
      s.observeCall(.ongoing(family: .zoom, room: "w"), holder: Self.main)
      s.observeCall(.ongoing(family: .teams, room: "pid-300"), holder: Self.teams)
    }
    s.read([Self.main, Self.teams])
    let id = UUID()
    s.meeting = .recording(meetingID: id)
    s.settleManual(request, recordingID: id)
    #expect(s.policy.manualLink?.reason == .severalCallsAtSettle)
    #expect(!Self.isLinked(s, id))
    #expect(!Self.asksSwitch(s))
  }

  @Test(
    "two Meet rooms in one Chrome run, in either read order, link nothing",
    arguments: [false, true])
  func twoBrowserRooms(roomBLast: Bool) {
    let a = CallDetectionPolicyTests.chrome(.active, url: CallDetectionPolicyTests.meetA, pid: 200)
    let b = CallDetectionPolicyTests.chrome(.active, url: CallDetectionPolicyTests.meetB, pid: 201)
    guard case .call(_, let roomA)? = a.evidence, case .call(_, let roomB)? = b.evidence else {
      Issue.record("Meet fixtures must classify")
      return
    }
    let owner = Story.owner(for: a)
    let sourceB = Policy.Source(id: 201, pid: 201, rule: .browser(.chrome))
    var s = Story()
    let request = s.acceptManual()
    let id = UUID()
    s.meeting = .recording(meetingID: id)
    s.settleManual(request, recordingID: id)
    func observeB(_ s: inout Story) {
      s.observeCall(
        .ongoing(family: .googleMeet, room: roomB), holder: b, sourceObservation: (sourceB, owner))
    }
    if roomBLast {
      s.observeCall(.ongoing(family: .googleMeet, room: roomA), holder: a)
      observeB(&s)
    } else {
      observeB(&s)
      s.observeCall(.ongoing(family: .googleMeet, room: roomA), holder: a)
    }
    s.ready([a, b])
    s.hold([a, b], for: 4)
    #expect(!Self.isLinked(s, id))
    #expect(!Self.asksSwitch(s))
  }

  @Test("a later link is reported once, even when its recording stopped before the drain")
  func laterLinkSurvivesStop() {
    var s = Story()
    let request = s.acceptManual()
    let id = UUID()
    s.meeting = .recording(meetingID: id)
    s.settleManual(request, recordingID: id)
    s.ongoing(Self.main)
    s.meeting = .idle
    s.step()
    #expect(s.policy.drainLaterLinks().map(\.recordingID) == [id])
    #expect(s.policy.drainLaterLinks().isEmpty)
  }

  @Test("an older completion replaced by a newer start never follows a call")
  func supersededNeverFollows() {
    var s = Story()
    let old = s.acceptManual(generation: 1)
    _ = s.acceptManual(generation: 2)
    let id = UUID()
    s.meeting = .recording(meetingID: id)
    s.settleManual(old, recordingID: id)
    s.ongoing(Self.main)
    #expect(!Self.isLinked(s, id))
    #expect(s.policy.drainLaterLinks().isEmpty)
  }

  @Test("a recording that was not started by hand is never followed")
  func detectedRouteNotFollowed() {
    var s = Story()
    let request = s.acceptManual(route: .detected)
    let id = UUID()
    s.meeting = .recording(meetingID: id)
    s.settleManual(request, recordingID: id)
    s.ongoing(Self.main)
    #expect(!Self.isLinked(s, id))
  }

  @Test("with call detection Off nothing follows; turned back on, the call is followed")
  func detectionOff() {
    var s = Story()
    let request = s.acceptManual()
    let id = UUID()
    s.meeting = .recording(meetingID: id)
    s.settleManual(request, recordingID: id)
    s.mode = .off
    s.ongoing(Self.main)
    #expect(!Self.isLinked(s, id))
    s.mode = .ask
    s.ongoing(Self.main)
    #expect(Self.isLinked(s, id))
  }
}
