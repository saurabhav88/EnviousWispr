import Testing

@testable import EnviousWisprServices

/// #4013 r4: when these fail, EnviousMeet opens Zoom's participants panel when the user turned
/// that off, presses twice, reopens a panel the user closed, presses in another call's window, or
/// presses while the user dictates or the recording has stopped.
///
/// Trees are SURVEY labels from the C1a/C1b Zoom calls (`docs/audits/2026-10-27-4013/`), rebuilt
/// small; SYNTHETIC cases vary them.
@Suite("Zoom participants panel policy", .tags(.productOutcome))
struct ZoomParticipantsPanelPolicyTests {
  typealias Policy = ZoomParticipantsPanelPolicy

  private static let closedButton = CallAXNode(
    role: "AXButton", description: "Open participants panel, closed, 3 participants")
  private static let openList = CallAXNode(role: "AXOutline", description: "Participants list")

  private static func window(_ children: [CallAXNode], id: String? = "zm.meeting.window.main")
    -> CallAXWindow
  {
    CallAXWindow(
      title: "Zoom Meeting",
      root: CallAXNode(role: "AXWindow", title: "Zoom Meeting", identifier: id, children: children))
  }

  private static func snap(
    _ windows: [CallAXWindow], complete: Bool = true, at: UInt64 = 1_000, generation: UInt64 = 7,
    started: UInt64? = nil
  ) -> Policy.Snapshot {
    Policy.Snapshot(
      windows: windows, isComplete: complete, startedAtNanos: started ?? at - 50,
      finishedAtNanos: at, linkGeneration: generation)
  }

  private static let closed = snap([window([closedButton])])
  private static let open = snap([window([openList])])

  private func decide(
    _ snapshot: Policy.Snapshot?, state: Policy.State = .init(), setting: Bool = true,
    generation: UInt64 = 7, now: UInt64 = 1_200
  ) -> Policy.Decision {
    Policy.decide(
      settingOn: setting, snapshot: snapshot, state: state, currentLinkGeneration: generation,
      nowNanos: now, maxAgeNanos: 500)
  }

  @Test("a closed panel with one button in the one meeting window is pressed")
  func pressesClosedPanel() {
    #expect(decide(Self.closed) == .press)
  }

  @Test("every refusal before the press, each for its own reason")
  func refusals() {
    var spent = Policy.State()
    _ = spent.admit()
    let cases: [(Policy.Decision, Policy.Refusal)] = [
      (decide(Self.closed, setting: false), .settingOff),
      (decide(Self.closed, state: spent), .attemptSpent),
      (decide(nil), .noSnapshot),
      (decide(Self.snap([Self.window([Self.closedButton])], complete: false)), .incompleteSnapshot),
      (decide(Self.closed, now: 2_000), .staleSnapshot),
      (decide(Self.snap([Self.window([Self.closedButton])], at: 5_000)), .staleSnapshot),
      (decide(Self.closed, generation: 8), .otherCall),
      (decide(Self.open), .panelOpen),
      (decide(Self.snap([Self.window([])])), .noButton),
      (decide(Self.snap([Self.window([Self.closedButton, Self.closedButton])])), .ambiguousButton),
      (
        decide(Self.snap([Self.window([Self.closedButton]), Self.window([Self.closedButton])])),
        .notOneMeetingWindow
      ),
      (decide(Self.snap([Self.window([Self.closedButton], id: nil)])), .notOneMeetingWindow),
    ]
    for (decision, reason) in cases {
      #expect(decision == .refuse(reason), "\(reason)")
    }
  }

  @Test("a panel seen open and then closed by the user is never reopened")
  func respectsUserClose() {
    var state = Policy.State()
    state.observe(Self.open)
    #expect(decide(Self.closed, state: state) == .refuse(.observedOpenBefore))
  }

  @Test("only one admission per meeting, whatever happens after it")
  func oneAdmission() {
    var state = Policy.State()
    let first = state.admit()
    let second = state.admit()
    #expect(first)
    #expect(!second, "a duplicate or retry is never admitted")
    #expect(decide(Self.closed, state: state) == .refuse(.attemptSpent))
  }

  private func final(
    recording: Bool = true, paused: Bool = false, generation: UInt64 = 7,
    invalidation: UInt64 = 3, setting: Bool = true, permission: Bool = true, idle: Bool = true,
    snapshot: Policy.Snapshot = closed, state: Policy.State = .init(), now: UInt64 = 1_200
  ) -> Policy.Decision {
    Policy.finalCheck(
      Policy.FinalCheck(
        recording: recording, paused: paused, linkGeneration: generation,
        invalidationGeneration: invalidation, settingOn: setting, accessibilityAllowed: permission,
        dictationIdle: idle, snapshot: snapshot),
      state: state, admitted: Policy.Admission(linkGeneration: 7, invalidationGeneration: 3),
      nowNanos: now, maxAgeNanos: 500)
  }

  @Test("the final check refuses an old or out-of-order snapshot, measured from its start")
  func finalFreshness() {
    #expect(final(now: 2_000) == .refuse(.staleSnapshot))
    // A long walk: finished recently, but started too long ago for its first reads to count.
    #expect(final(snapshot: Self.snap([Self.window([Self.closedButton])], at: 1_150, started: 600)) == .refuse(.staleSnapshot))
    #expect(final(snapshot: Self.snap([Self.window([Self.closedButton])], at: 1_500)) == .refuse(.staleSnapshot))
    #expect(final(snapshot: Self.snap([Self.window([Self.closedButton])], at: 1_100, started: 1_150)) == .refuse(.staleSnapshot))
  }

  @Test("a panel seen open after admission and then closed by the user is not reopened")
  func finalRespectsLaterClose() {
    var state = Policy.State()
    _ = state.admit()
    state.observe(Self.open)
    #expect(final(snapshot: Self.closed, state: state) == .refuse(.observedOpenBefore))
  }

  @Test("a pause and resume between admission and the press keeps the old action refused")
  func finalInvalidatedByPause() {
    #expect(final(paused: false, invalidation: 4) == .refuse(.invalidated))
  }

  @Test(
    "the last check before the press refuses on stop, pause, relink, setting, permission, dictation or a changed panel"
  )
  func finalCheckRefusals() {
    #expect(final() == .press)
    let cases: [(Policy.Decision, Policy.Refusal)] = [
      (final(recording: false), .notRecording),
      (final(paused: true), .paused),
      (final(generation: 8), .otherCall),
      (final(snapshot: Self.snap([Self.window([Self.closedButton])], generation: 8)), .otherCall),
      (final(setting: false), .settingOff),
      (final(permission: false), .noPermission),
      (final(idle: false), .dictating),
      (
        final(snapshot: Self.snap([Self.window([Self.closedButton])], complete: false)),
        .incompleteSnapshot
      ),
      (final(snapshot: Self.open), .panelOpen),
      (final(snapshot: Self.snap([Self.window([])])), .noButton),
      (
        final(snapshot: Self.snap([Self.window([Self.closedButton, Self.closedButton])])),
        .ambiguousButton
      ),
    ]
    for (decision, reason) in cases {
      #expect(decision == .refuse(reason), "\(reason)")
    }
  }

  @Test("an open list anywhere in the meeting window counts as open, even beside the button label")
  func openBeatsButton() {
    #expect(
      decide(Self.snap([Self.window([Self.closedButton, Self.openList])])) == .refuse(.panelOpen))
  }
}
