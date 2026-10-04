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
    #expect(PasteCascadeExecutor.appFrontRefusal(.frontApp, ownerPathOnly: false) == nil)
    for ownerPathOnly in [false, true] {
      #expect(
        PasteCascadeExecutor.appFrontRefusal(
          .focusOwner(elementConfirmed: true), ownerPathOnly: ownerPathOnly) == nil)
      #expect(
        PasteCascadeExecutor.appFrontRefusal(
          .focusOwner(elementConfirmed: false), ownerPathOnly: ownerPathOnly) == "app_not_front")
      #expect(
        PasteCascadeExecutor.appFrontRefusal(.notActive, ownerPathOnly: ownerPathOnly)
          == "app_not_front")
    }
    #expect(
      PasteCascadeExecutor.appFrontRefusal(.frontApp, ownerPathOnly: true) == "app_not_front",
      "admitted as the owner, a destination that turned front skipped the omnibox re-check")
  }

  @Test("the switch token holds the front app, plus the focus owner only while the destination is not front")
  func switchToken() {
    let count = Count()
    func token(front: pid_t?, owner: pid_t?) -> DestinationSwitchToken {
      DestinationActivityEvaluator.switchToken(
        pid: pid, front: { front },
        focus: {
          count.focusReads += 1
          return owner.map { .focused(element: field, ownerPID: $0) } ?? .unreadable
        })
    }
    let frontBefore = token(front: pid, owner: 7)
    #expect(count.focusReads == 0, "a front destination costs no focus read")
    #expect(token(front: pid, owner: 9) == frontBefore, "the owner is ignored while front")
    let launcher = token(front: 7, owner: pid)
    #expect(token(front: 7, owner: pid) == launcher)
    #expect(token(front: 7, owner: 9) != launcher, "the panel lost the focus: a switch")
    #expect(token(front: 8, owner: pid) != launcher, "the front app changed: a switch")
    #expect(token(front: 7, owner: nil) != launcher, "the owner could not be confirmed again")
    #expect(token(front: 8, owner: nil) != token(front: 7, owner: nil), "B to C, as before")
  }

  @Test("active applications: front first, the confirmed owner second, one entry per pid")
  func activeApplications() {
    let front = ActiveApplication(pid: 7, bundleID: "front", isFocusOwner: false)
    func resolve(_ pid: pid_t) -> ActiveApplication? {
      ActiveApplication(pid: pid, bundleID: "owner", isFocusOwner: true)
    }
    #expect(
      DestinationActivityEvaluator.activeApplications(
        front: front, focus: { .focused(element: field, ownerPID: pid) }, application: resolve)
        == [front, ActiveApplication(pid: pid, bundleID: "owner", isFocusOwner: true)])
    #expect(
      DestinationActivityEvaluator.activeApplications(
        front: front, focus: { .focused(element: field, ownerPID: 7) }, application: resolve)
        == [ActiveApplication(pid: 7, bundleID: "front", isFocusOwner: true)], "no duplicate pid")
    for unconfirmed in [KeyboardFocusRead.noElement, .unreadable, .ownerUnreadable(element: field)] {
      #expect(
        DestinationActivityEvaluator.activeApplications(
          front: front, focus: { unconfirmed }, application: resolve) == [front],
        "\(unconfirmed.logLabel): today's front-only answer")
    }
    #expect(
      DestinationActivityEvaluator.activeApplications(
        front: front, focus: { .focused(element: field, ownerPID: pid) }, application: { _ in nil })
        == [front], "an owner that cannot be resolved adds nothing")
  }
}
