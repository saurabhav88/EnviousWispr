import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprServices

/// #4249: a hand-started recording (menu bar or History) is stopped by its call ending only when
/// it was linked to that call. `manualLink` names the one check that linked it or refused to,
/// and the `CallDetection` log line carries it. When this is wrong, the log blames the wrong
/// check and the next missed stop cannot be diagnosed. Linking behavior itself is covered by
/// `CallDetectionPolicyTests`.
@Suite("Call detection hand-start link reasons (#4249)", .tags(.observabilityContract))
struct CallDetectionManualLinkLogTests {
  typealias Policy = CallDetectionPolicy
  typealias Story = CallDetectionPolicyTests.Story

  private static func zoom(_ input: Policy.Input) -> Policy.Holder {
    CallDetectionPolicyTests.zoom(input)
  }

  @Test("a start during one known call links, and says so")
  func linked() {
    var s = Story()
    s.ongoing(Self.zoom(.active))
    let request = s.acceptManual()
    #expect(s.policy.manualLink?.reason == .candidate)
    let id = UUID()
    s.meeting = .recording(meetingID: id)
    s.settleManual(request, recordingID: id)
    #expect(s.policy.manualLink?.generation == 1)
    #expect(s.policy.manualLink?.reason == .linked)
  }

  @Test("no call, two calls, or a busy meeting are named at acceptance and kept at settlement")
  func refusedAtAcceptance() {
    var none = Story()
    let alone = none.acceptManual()
    let first = UUID()
    none.meeting = .recording(meetingID: first)
    none.settleManual(alone, recordingID: first)
    #expect(none.policy.manualLink?.reason == .noCall)

    var two = Story()
    let zoom = Self.zoom(.active)
    let teams = Policy.Holder(
      pid: 300, rule: .callApp(.teams), input: .active,
      evidence: .call(family: .teams, room: "pid-300"))
    two.observeCall(.ongoing(family: .zoom, room: "w"), holder: zoom)
    two.observeCall(.ongoing(family: .teams, room: "pid-300"), holder: teams)
    two.ready([zoom, teams])
    let both = two.acceptManual()
    let second = UUID()
    two.meeting = .recording(meetingID: second)
    two.settleManual(both, recordingID: second)
    #expect(two.policy.manualLink?.reason == .severalCalls)

    var busy = Story()
    busy.ongoing(Self.zoom(.active))
    busy.meeting = .recording(meetingID: UUID())
    _ = busy.acceptManual()
    #expect(busy.policy.manualLink?.reason == .notReady)
  }

  @Test("a call app switched off after acceptance is named at settlement")
  func appOffAtSettlement() {
    var s = Story()
    s.ongoing(Self.zoom(.active))
    let request = s.acceptManual()
    s.appsOff = ["zoom"]
    let id = UUID()
    s.meeting = .recording(meetingID: id)
    s.settleManual(request, recordingID: id)
    #expect(s.policy.manualLink?.reason == .appOff)
  }

  @Test("after a manual Stop the same call is not taken again, and the line says overridden")
  func overriddenAfterManualStop() {
    var s = Story()
    let call = Self.zoom(.active)
    s.ongoing(call)
    let request = s.acceptManual()
    let first = UUID()
    s.meeting = .recording(meetingID: first)
    s.settleManual(request, recordingID: first)
    s.meeting = .idle
    s.step()
    s.ongoing(call)
    let next = s.acceptManual(generation: 2)
    let second = UUID()
    s.meeting = .recording(meetingID: second)
    s.settleManual(next, recordingID: second)
    #expect(s.policy.manualLink?.generation == 2)
    #expect(s.policy.manualLink?.reason == .overridden)
  }

  @Test("an older start replaced by a newer one is superseded; a start that never began says so")
  func supersededAndNotStarted() {
    var s = Story()
    s.ongoing(Self.zoom(.active))
    let old = s.acceptManual(generation: 1)
    let current = s.acceptManual(generation: 2)
    s.settleManual(old, recordingID: UUID())
    #expect(s.policy.manualLink?.generation == 1)
    #expect(s.policy.manualLink?.reason == .superseded)
    s.settleManual(current, recordingID: nil)
    #expect(s.policy.manualLink?.generation == 2)
    #expect(s.policy.manualLink?.reason == .notStarted)
  }

  @Test("a detected call's own start records no hand-start decision")
  func detectedRouteRecordsNothing() {
    var s = Story()
    s.ongoing(Self.zoom(.active))
    let request = s.acceptManual(route: .detected)
    s.settleManual(request, recordingID: UUID())
    #expect(s.policy.manualLink == nil)
  }
}
