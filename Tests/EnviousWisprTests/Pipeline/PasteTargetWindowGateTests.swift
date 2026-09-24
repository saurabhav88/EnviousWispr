import ApplicationServices
import Foundation
import SwiftParser
import SwiftSyntax
import Testing

@testable import EnviousWisprPipeline
@testable import EnviousWisprServices

/// Product Outcome: a key paste reaches the window the user dictated into, or does not run (#3121).
///
/// When this fails, a dictation started in one window of an app (a Chrome profile) and stopped
/// after switching to another window of the same app is pasted into that other window or nowhere,
/// and the words vanish silently; or a normal paste is refused and shows "Copied" for no reason.
///
/// The system-paste tiers are inert on the isolated boards tests use, so the decision is tested
/// here over scripted Accessibility answers and its placement by the drift guard below.
@Suite("Key paste requires the captured field's window to be front (#3121)", .tags(.productOutcome))
@MainActor
struct PasteTargetWindowGateTests {
  let ax = PastedRegionFakeAX()
  let scheduler = PastedRegionFakeScheduler()
  let pid: pid_t = 42
  /// The captured field (its handle pid is 10_042 in the fake).
  var field: AXUIElement { PastedRegionFakeAX.field(pid) }
  /// Stand-in window handles: distinct AX elements that `CFEqual` tells apart.
  let windowA = AXUIElementCreateApplication(5001)
  let windowB = AXUIElementCreateApplication(5002)
  let otherField = AXUIElementCreateApplication(5003)

  private func budget(totalMs: Int = 500) -> PasteLandingPrepareBudget {
    PasteLandingPrepareBudget(totalMs: totalMs, scheduler: scheduler, ax: ax)
  }

  private func resolved(_ element: AXUIElement?) -> PasteTargetWindow {
    PasteTargetWindowGate.resolve(element: element, ax: ax, admit: budget().admit)
  }

  private func refusal(_ target: PasteTargetWindow, element: AXUIElement? = nil)
    -> PasteTargetWindowGate.Refusal?
  {
    PasteTargetWindowGate.refusal(
      target: target, element: element ?? field, pid: pid, ax: ax, admit: budget().admit)
  }

  // MARK: Resolution

  @Test("No captured field resolves to none and reads nothing")
  func noFieldIsNone() {
    guard case .none = resolved(nil) else {
      Issue.record("expected .none")
      return
    }
    #expect(ax.landingCalls.isEmpty)
  }

  @Test("A readable window resolves to that window")
  func readableWindow() {
    ax.windows[10_042] = .window(windowA)
    guard case .window(let window) = resolved(field) else {
      Issue.record("expected .window")
      return
    }
    #expect(CFEqual(window, windowA))
  }

  @Test("Every unreadable window answer resolves to unreadable")
  func unreadableAnswers() {
    // A loop, not test arguments: `PastedRegionWindowRead` carries an `AXUIElement` and is not
    // Sendable.
    let answers: [PastedRegionWindowRead] = [
      .absent, .notElement, .failed(.invalidUIElement), .failed(.cannotComplete),
    ]
    for answer in answers {
      ax.windows[10_042] = answer
      ax.landingCalls = []
      guard case .unreadable = resolved(field) else {
        Issue.record("expected .unreadable for \(answer)")
        continue
      }
      #expect(ax.landingCalls.map(\.call) == ["window"])
    }
  }

  @Test("A bound that cannot be installed resolves to unreadable without reading the window")
  func unboundedReadIsRefused() {
    ax.windows[10_042] = .window(windowA)
    ax.timeoutFailsFor = [10_042]
    guard case .unreadable = resolved(field) else {
      Issue.record("expected .unreadable")
      return
    }
    #expect(ax.landingCalls.isEmpty)
  }

  // MARK: The gate

  @Test("No captured field always passes and reads nothing (behaviour before #3121)")
  func noneAlwaysPasses() {
    #expect(refusal(.none) == nil)
    #expect(ax.landingCalls.isEmpty)
  }

  @Test("The captured window being the app's focused window passes")
  func sameWindowPasses() {
    ax.focusedWindows[pid] = .window(windowA)
    #expect(refusal(.window(windowA)) == nil)
    #expect(ax.landingCalls.map(\.call) == ["focusedWindow"])
  }

  @Test("Another window front with the focus elsewhere is refused (the #3121 repro)")
  func otherWindowRefused() {
    ax.focusedWindows[pid] = .window(windowB)
    ax.focusedByApplication[pid] = .element(otherField)
    #expect(refusal(.window(windowA)) == .windowMismatch)
    #expect(ax.landingCalls.map(\.call) == ["focusedWindow", "focusedElement"])
  }

  @Test("A sheet owning window focus while the field keeps focus passes")
  func sheetWithFieldFocusPasses() {
    ax.focusedWindows[pid] = .window(windowB)
    ax.focusedByApplication[pid] = .element(field)
    #expect(refusal(.window(windowA)) == nil)
  }

  @Test("An unreadable focused window falls back to the focused-element match")
  func unreadableFocusedWindowFallsBack() {
    ax.focusedWindows[pid] = .failed(.cannotComplete)
    ax.focusedByApplication[pid] = .element(field)
    #expect(refusal(.window(windowA)) == nil)
    ax.focusedByApplication[pid] = .noFocus
    #expect(refusal(.window(windowA)) == .focusedWindowUnreadable, "unread is not a different window")
    ax.focusedWindows[pid] = .absent
    #expect(refusal(.window(windowA)) == .focusedWindowUnreadable)
  }

  @Test("An unreadable captured window passes only while the field itself is focused")
  func unreadableWindowNeedsFocusMatch() {
    ax.focusedByApplication[pid] = .element(field)
    #expect(refusal(.unreadable) == nil)
    ax.focusedByApplication[pid] = .element(otherField)
    #expect(refusal(.unreadable) == .windowUnreadableFocusMismatch)
    ax.focusedByApplication[pid] = .queryFailed(.cannotComplete)
    #expect(refusal(.unreadable) == .windowUnreadableFocusMismatch)
    #expect(!ax.landingCalls.map(\.call).contains("focusedWindow"))
  }

  @Test("A budget that refuses the read fails closed")
  func budgetRefusalFailsClosed() {
    ax.focusedWindows[pid] = .window(windowA)
    ax.timeoutFailsFor = [pid]
    #expect(refusal(.window(windowA)) == .budget)
    #expect(refusal(.unreadable) == .budget)
    #expect(ax.landingCalls.isEmpty)

    ax.timeoutFailsFor = []
    let spent = budget(totalMs: 500)
    scheduler.advance(ms: 500)
    #expect(
      PasteTargetWindowGate.refusal(
        target: .window(windowA), element: field, pid: pid, ax: ax, admit: spent.admit) == .budget)
  }

  @Test("Refusal reasons are the strings logged and sent as paste.tier_failures")
  func reasonStrings() {
    #expect(PasteTargetWindowGate.Refusal.windowMismatch.rawValue == "window_mismatch")
    #expect(
      PasteTargetWindowGate.Refusal.focusedWindowUnreadable.rawValue == "focused_window_unreadable")
    #expect(
      PasteTargetWindowGate.Refusal.windowUnreadableFocusMismatch.rawValue
        == "window_unreadable_focus_mismatch")
    #expect(PasteTargetWindowGate.Refusal.budget.rawValue == "budget")
  }
}

/// Drift Guard: every key-paste dispatch sits behind the window gate (#3121).
///
/// Parsed with `SwiftParser`, so comments and strings can never satisfy it. For each of the three
/// system-paste calls: it runs only on the else-path of both the activation-time refusal
/// (`activation.windowRefusal`) and the dispatch-time gate (`gate.refusal`); its tier is recorded
/// as attempted only on that path; and, for Tier 2 and 2b, the Chromium omnibox re-check runs
/// between the gate and the dispatch, and 2b's clipboard write follows the gate.
@Suite("Key-paste dispatches sit behind the window gate (#3121)", .tags(.driftGuard))
struct PasteTargetWindowGateWiringTests {

  private final class Calls: SyntaxVisitor {
    var found: [(callee: String, node: FunctionCallExprSyntax)] = []
    init() { super.init(viewMode: .sourceAccurate) }
    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
      found.append((node.calledExpression.trimmedDescription, node))
      return .visitChildren
    }
  }

  private static func parse() throws -> (Calls, SourceFileSyntax) {
    let text = try String(
      contentsOf: RepoRoot.sourceURL("Sources/EnviousWisprPipeline/PasteCascadeExecutor.swift"),
      encoding: .utf8)
    let tree = Parser.parse(source: text)
    let calls = Calls()
    calls.walk(tree)
    return (calls, tree)
  }

  /// Whether `node` is reached only through the ELSE side of an `if` whose conditions mention
  /// `condition`.
  private static func onElseOf(_ condition: String, _ node: some SyntaxProtocol) -> Bool {
    var child = Syntax(node)
    while let parent = child.parent {
      if let ifx = parent.as(IfExprSyntax.self),
        ifx.conditions.trimmedDescription.contains(condition)
      {
        return child.position >= ifx.body.endPosition
      }
      child = parent
    }
    return false
  }

  private static func only(_ callee: String, in calls: Calls) throws -> FunctionCallExprSyntax {
    let hits = calls.found.filter { $0.callee == callee }
    try #require(hits.count == 1, "\(callee): \(hits.count) call sites")
    return hits[0].node
  }

  /// The one `dispatchGate` call nearest before `node`.
  private static func gate(before node: some SyntaxProtocol, in calls: Calls) -> AbsolutePosition? {
    calls.found.filter { $0.callee == "dispatchGate" && $0.node.position < node.position }
      .map(\.node.position).max()
  }

  @Test(
    "Each system paste runs only after both window checks",
    arguments: [
      "PasteService.pasteToActiveApp", "PasteService.pasteViaAppleScript",
      "PasteService.pressMenuItem",
    ])
  func dispatchBehindGate(_ dispatch: String) throws {
    let (calls, _) = try Self.parse()
    let node = try Self.only(dispatch, in: calls)
    #expect(Self.onElseOf("activation.windowRefusal", node), "\(dispatch) activation check")
    #expect(Self.onElseOf("gate.refusal", node), "\(dispatch) dispatch-time gate")
    #expect(Self.gate(before: node, in: calls) != nil)
  }

  @Test("Three dispatch-time gates, one per key tier")
  func threeGates() throws {
    let (calls, _) = try Self.parse()
    #expect(calls.found.filter { $0.callee == "dispatchGate" }.count == 3)
  }

  @Test("A key tier is recorded as attempted only past its gate")
  func attemptsPastTheGate() throws {
    let (calls, _) = try Self.parse()
    for tier in [".cgEvent", ".appleScript", ".menuPaste"] {
      let appends = calls.found.filter {
        $0.callee == "tiersAttempted.append" && $0.node.arguments.trimmedDescription == tier
      }
      try #require(appends.count == 1, "\(tier): \(appends.count)")
      #expect(Self.onElseOf("gate.refusal", appends[0].node), "\(tier)")
    }
  }

  @Test("Tier 2 and 2b re-check the omnibox after the gate, as the last step before dispatch")
  func omniboxStaysLast() throws {
    let (calls, _) = try Self.parse()
    let omnibox = calls.found.filter {
      $0.callee == "PasteService.freshFocusedElement"
        && $0.node.arguments.trimmedDescription.contains("remainingGateSeconds")
    }
    #expect(omnibox.count == 2)
    for dispatch in ["PasteService.pasteToActiveApp", "PasteService.pasteViaAppleScript"] {
      let node = try Self.only(dispatch, in: calls)
      let gate = try #require(Self.gate(before: node, in: calls))
      let between = omnibox.filter { $0.node.position > gate && $0.node.position < node.position }
      #expect(between.count == 1, "\(dispatch)")
    }
  }

  @Test("Tier 2b writes the clipboard only after its gate")
  func appleScriptWritesAfterGate() throws {
    let (calls, _) = try Self.parse()
    let dispatch = try Self.only("PasteService.pasteViaAppleScript", in: calls)
    let gate = try #require(Self.gate(before: dispatch, in: calls))
    let writes = calls.found.filter {
      ($0.callee == "PasteService.copyToClipboardReturningChangeCount"
        || $0.callee == "ClipboardCleanup.snapshotForDelivery")
        && $0.node.position > gate && $0.node.position < dispatch.position
    }
    #expect(writes.count == 2)
    #expect(writes.allSatisfy { Self.onElseOf("gate.refusal", $0.node) })
  }
}

/// Product Outcome: an activation Accessibility call never outlives its deadline (#3121 R3-1).
///
/// When this fails, a frozen target app can hold the dictation's paste longer than the activation
/// deadline says, or a call runs with a zero timeout, which installs the unbounded system default.
@Suite("Activation calls spend only what remains of their deadline (#3121)", .tags(.productOutcome))
@MainActor
struct PasteActivationCallBoundTests {
  @Test("The bound is what remains, capped at 0.5 s, and nothing once the deadline is spent")
  func bound() {
    #expect(PasteCascadeExecutor.activationCallSeconds(1000) == 0.5)
    #expect(PasteCascadeExecutor.activationCallSeconds(500) == 0.5)
    #expect(PasteCascadeExecutor.activationCallSeconds(120) == 0.12)
    #expect(PasteCascadeExecutor.activationCallSeconds(1) == 0.001)
    #expect(PasteCascadeExecutor.activationCallSeconds(0) == nil)
    #expect(PasteCascadeExecutor.activationCallSeconds(-40) == nil)
  }
}
