import AppKit
import ApplicationServices
import Foundation
import Testing

@testable import EnviousWisprPipeline
@testable import EnviousWisprServices

/// Product Outcome (#3423): the paste's activation and its last check, run on scripted
/// Accessibility answers.
///
/// When this fails, a key paste is sent to a floating launcher panel whose field is no longer the
/// one the user dictated into, a panel that already holds the focus is "activated" and closed, or
/// an ordinary front app suddenly pays for an extra Accessibility read before every paste.
@MainActor
@Suite(.tags(.productOutcome))
struct PasteActivationAdmissionTests {
  let ax = PastedRegionFakeAX()
  let scheduler = PastedRegionFakeScheduler()
  let app = NSRunningApplication.current
  var pid: pid_t { app.processIdentifier }
  var field: AXUIElement { PastedRegionFakeAX.field(pid) }
  var otherField: AXUIElement { PastedRegionFakeAX.field(9) }

  final class Effects { var activations = 0 }

  init() {
    _ = NSApplication.shared
    ax.runningPIDs = [app.processIdentifier]
    ax.focusedByApplication[app.processIdentifier] = .element(
      PastedRegionFakeAX.field(app.processIdentifier))
  }

  func executor(_ effects: Effects, advanceMs: Int = 0) -> PasteCascadeExecutor {
    let scheduler = self.scheduler
    return PasteCascadeExecutor(
      pasteboard: NSPasteboard.withUniqueName(), policy: .baseline, landingAX: ax,
      landingScheduler: scheduler,
      activationEffect: { _ in
        effects.activations += 1
        scheduler.advance(ms: advanceMs)
      })
  }

  @Test("a launcher that holds the focus on the captured field is never raised or activated")
  func confirmedOwnerSkipsActivation() async {
    ax.frontmost = 7
    ax.keyboardFocus = .focused(element: field, ownerPID: pid)
    let effects = Effects()
    let activation = await executor(effects).activate(
      app, element: field, recordedWindow: nil, target: nil, tier1BoundTheTarget: false)
    #expect(activation.activated)
    #expect(activation.windowRefusal == nil)
    #expect(effects.activations == 0)
    #expect(ax.keyboardFocusReads == 1, "one admission read")
  }

  @Test("an owner focused on another field gets today's activation, which times out")
  func unconfirmedOwnerRunsTodaysLoop() async {
    ax.frontmost = 7
    ax.keyboardFocus = .focused(element: otherField, ownerPID: pid)
    let effects = Effects()
    let activation = await executor(effects, advanceMs: 5_000).activate(
      app, element: field, recordedWindow: nil, target: nil, tier1BoundTheTarget: false)
    #expect(!activation.activated)
    #expect(effects.activations == 1)
    #expect(ax.keyboardFocusReads == 1, "the poll never reads the focus")
  }

  @Test("a front destination costs no focus read and activates as before")
  func frontDestinationIsUnchanged() async {
    ax.frontmost = pid
    ax.keyboardFocus = .focused(element: otherField, ownerPID: 9)
    let effects = Effects()
    let activation = await executor(effects).activate(
      app, element: field, recordedWindow: nil, target: nil, tier1BoundTheTarget: false)
    #expect(activation.activated)
    #expect(effects.activations == 1)
    #expect(ax.keyboardFocusReads == 0)
  }

  func gate(_ executor: PasteCascadeExecutor) -> PasteCascadeExecutor.DispatchGate {
    executor.dispatchGate(
      app: app, target: .none, element: field, tier1BoundTheTarget: false, takeID: nil,
      bundleId: "test")
  }

  func finalRefusal(_ executor: PasteCascadeExecutor, _ gate: PasteCascadeExecutor.DispatchGate)
    -> String?
  {
    PasteCascadeExecutor.appFrontRefusal(
      executor.finalDestinationActivity(app: app, element: field, gate: gate),
      ownerPathOnly: gate.ownerPath)
  }

  @Test("owner path: the gate admits the confirmed owner, and the last read must confirm it again")
  func ownerPathFinalRead() {
    ax.frontmost = 7
    ax.keyboardFocus = .focused(element: field, ownerPID: pid)
    let executor = executor(Effects())
    let admitted = gate(executor)
    #expect(admitted.refusal == nil)
    #expect(admitted.ownerPath)
    #expect(finalRefusal(executor, admitted) == nil, "still the captured field: dispatch")

    ax.keyboardFocus = .focused(element: otherField, ownerPID: pid)
    #expect(finalRefusal(executor, admitted) == "app_not_front", "moved to another field")
    ax.keyboardFocus = .focused(element: otherField, ownerPID: 9)
    #expect(finalRefusal(executor, admitted) == "app_not_front", "the panel lost the focus")
    ax.keyboardFocus = .unreadable
    #expect(finalRefusal(executor, admitted) == "app_not_front", "could not confirm")
    ax.frontmost = pid
    #expect(
      finalRefusal(executor, admitted) == "app_not_front",
      "turned front after the omnibox re-check was skipped")
  }

  @Test("the gate refuses an owner whose focus is on another field")
  func ownerOnAnotherFieldIsRefused() {
    ax.frontmost = 7
    ax.keyboardFocus = .focused(element: otherField, ownerPID: pid)
    let refused = gate(executor(Effects()))
    #expect(refused.refusal == "app_not_front")
    #expect(!refused.ownerPath)
  }

  @Test("front path: the gate and the last check read no focus, exactly as before")
  func frontPathIsUnchanged() {
    ax.frontmost = pid
    let executor = executor(Effects())
    let admitted = gate(executor)
    #expect(admitted.refusal == nil)
    #expect(!admitted.ownerPath)
    #expect(finalRefusal(executor, admitted) == nil)
    ax.frontmost = 7
    ax.keyboardFocus = .focused(element: field, ownerPID: pid)
    #expect(
      finalRefusal(executor, admitted) == "app_not_front",
      "the front path's last check is front-only: today's refusal")
    #expect(ax.keyboardFocusReads == 0)
  }
}
