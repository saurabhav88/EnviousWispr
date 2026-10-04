import ApplicationServices
import Foundation
import Testing

@testable import EnviousWisprPipeline
@testable import EnviousWisprServices

/// Product Outcome (#3423): whether a destination counts as "where keyboard input goes now".
///
/// When this fails, a person dictating into a floating launcher panel (Raycast) sees "Copied"
/// instead of their words, or a key paste reaches an application that does not hold the captured
/// field. The rule is additive: the front-app answer is today's and comes first; the focus owner
/// can only add a pass, and only a confirmed one.
@MainActor
@Suite(.tags(.productOutcome))
struct DestinationActivityEvaluatorTests {
  let pid: pid_t = 42
  let field = AXUIElementCreateApplication(10_042)
  let otherField = AXUIElementCreateApplication(10_043)

  final class Count { var focusReads = 0 }

  func evaluate(
    front: pid_t?, focus: KeyboardFocusRead, captured: AXUIElement?,
    mode: DestinationActivityMode = .full, count: Count = Count()
  ) -> DestinationActivity {
    DestinationActivityEvaluator.evaluate(
      pid: pid, capturedElement: captured, mode: mode, front: { front },
      focus: {
        count.focusReads += 1
        return focus
      })
  }

  @Test("the destination in front is active with no focus read, in either mode")
  func frontNeedsNoFocusRead() {
    for mode in [DestinationActivityMode.full, .frontOnly] {
      let count = Count()
      let answer = evaluate(
        front: pid, focus: .focused(element: otherField, ownerPID: 7), captured: field, mode: mode,
        count: count)
      #expect(answer == .frontApp, "\(mode)")
      #expect(count.focusReads == 0, "\(mode)")
    }
  }

  @Test("front-only mode never reads the focus, even when the destination owns it")
  func frontOnlyNeverReadsFocus() {
    let count = Count()
    let answer = evaluate(
      front: 7, focus: .focused(element: field, ownerPID: pid), captured: field, mode: .frontOnly,
      count: count)
    #expect(answer == .notActive)
    #expect(count.focusReads == 0)
  }

  @Test("the focus owner is active; the captured field confirms it for a key paste")
  func ownerIsActive() {
    let count = Count()
    #expect(
      evaluate(
        front: 7, focus: .focused(element: field, ownerPID: pid), captured: field, count: count)
        == .focusOwner(elementConfirmed: true))
    #expect(count.focusReads == 1, "one read, never a second")
    #expect(
      evaluate(front: 7, focus: .focused(element: otherField, ownerPID: pid), captured: field)
        == .focusOwner(elementConfirmed: false))
    #expect(
      evaluate(front: nil, focus: .focused(element: field, ownerPID: pid), captured: nil)
        == .focusOwner(elementConfirmed: false), "no captured field never confirms")
  }

  @Test(
    "every focus answer that cannot confirm the owner is today's refusal",
    arguments: ["other owner", "no element", "owner unreadable", "unreadable"])
  func unconfirmedIsNotActive(_ name: String) {
    let focus: KeyboardFocusRead =
      switch name {
      case "other owner": .focused(element: field, ownerPID: 7)
      case "no element": .noElement
      case "owner unreadable": .ownerUnreadable(element: field)
      default: .unreadable
      }
    #expect(evaluate(front: 7, focus: focus, captured: field) == .notActive)
  }

  @Test("a key paste may go to the front app or a confirmed owner, never to an unconfirmed one")
  func dispatchRule() {
    #expect(PasteCascadeExecutor.appFrontRefusal(.frontApp) == nil)
    #expect(PasteCascadeExecutor.appFrontRefusal(.focusOwner(elementConfirmed: true)) == nil)
    #expect(
      PasteCascadeExecutor.appFrontRefusal(.focusOwner(elementConfirmed: false)) == "app_not_front")
    #expect(PasteCascadeExecutor.appFrontRefusal(.notActive) == "app_not_front")
  }

  @Test("the switch token changes exactly when the front application changes")
  func switchToken() {
    let before = DestinationActivityEvaluator.switchToken(front: { 7 })
    #expect(DestinationActivityEvaluator.switchToken(front: { 7 }) == before)
    #expect(DestinationActivityEvaluator.switchToken(front: { 8 }) != before)
    #expect(DestinationActivityEvaluator.switchToken(front: { nil }) != before)
  }

  @Test(
    "the live seam makes no keyboard-focus read yet: every answer is front-only (#3423 chunk 1)")
  func liveSeamIsFrontOnly() {
    let live = LivePastedRegionAXOperations()
    let admitted = Count()
    let admit: @MainActor (AXUIElement) -> Bool = { _ in
      admitted.focusReads += 1
      return true
    }
    guard case .unreadable = live.keyboardFocusRead(admit: admit) else {
      Issue.record("a live focus read happened")
      return
    }
    // pid -1 is never the front application, so `.full` reaches the focus branch.
    #expect(
      live.destinationActivity(pid: -1, capturedElement: nil, mode: .full, admit: admit)
        == .notActive)
    #expect(admitted.focusReads == 0, "no system-wide handle was offered to the budget")
  }
}
