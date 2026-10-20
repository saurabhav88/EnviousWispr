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
    PasteTargetWindowGate.resolve(
      element: element, startFieldWindow: nil, ax: ax, admit: budget().admit)
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
    #expect(
      refusal(.window(windowA)) == .focusedWindowUnreadable, "unread is not a different window")
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

  // MARK: The recorded window (#3304)

  @Test("A captured field's window wins; else the recorded window; else none")
  func resolvePrecedence() {
    ax.windows[10_042] = .window(windowA)
    guard
      case .window(let window) = PasteTargetWindowGate.resolve(
        element: field, recordedWindow: windowB, startFieldWindow: nil, ax: ax,
        admit: budget().admit)
    else {
      Issue.record("expected the field's own window")
      return
    }
    #expect(CFEqual(window, windowA))
    ax.landingCalls = []
    guard
      case .recordedWindow(let recorded) = PasteTargetWindowGate.resolve(
        element: nil, recordedWindow: windowB, startFieldWindow: nil, ax: ax,
        admit: budget().admit)
    else {
      Issue.record("expected .recordedWindow")
      return
    }
    #expect(CFEqual(recorded, windowB))
    #expect(ax.landingCalls.isEmpty, "the recorded window needs no read to resolve")
    guard
      case .none = PasteTargetWindowGate.resolve(
        element: nil, recordedWindow: nil, startFieldWindow: nil, ax: ax,
        admit: budget().admit)
    else {
      Issue.record("expected .none")
      return
    }
  }

  @Test("The recorded window being the app's focused window passes, with no focus fallback read")
  func recordedSameWindowPasses() {
    ax.focusedWindows[pid] = .window(windowA)
    #expect(
      PasteTargetWindowGate.decide(
        target: .recordedWindow(windowA), element: nil, pid: pid, ax: ax, admit: budget().admit)
        == .pass(.sameWindow))
    #expect(ax.landingCalls.map(\.call) == ["focusedWindow"])
  }

  @Test("Another window READ as focused is refused (the #3304 repro)")
  func recordedOtherWindowRefused() {
    ax.focusedWindows[pid] = .window(windowB)
    #expect(refusal(.recordedWindow(windowA), element: nil) == .windowMismatch)
    #expect(ax.landingCalls.map(\.call) == ["focusedWindow"], "no field, so no focus fallback")
  }

  @Test("An unreadable focused window is not evidence of a move and passes")
  func recordedUnreadablePasses() {
    let answers: [PastedRegionWindowRead] = [
      .absent, .notElement, .failed(.invalidUIElement), .failed(.cannotComplete),
    ]
    for answer in answers {
      ax.focusedWindows[pid] = answer
      #expect(
        PasteTargetWindowGate.decide(
          target: .recordedWindow(windowA), element: nil, pid: pid, ax: ax, admit: budget().admit)
          == .pass(.focusedWindowUnreadable), "\(answer)")
    }
  }

  @Test("A refused or spent budget passes a recorded window, and reads nothing")
  func recordedBudgetPasses() {
    ax.focusedWindows[pid] = .window(windowB)
    ax.timeoutFailsFor = [pid]
    #expect(
      PasteTargetWindowGate.decide(
        target: .recordedWindow(windowA), element: nil, pid: pid, ax: ax, admit: budget().admit)
        == .pass(.budget))
    #expect(ax.landingCalls.isEmpty)
    ax.timeoutFailsFor = []
    let spent = budget(totalMs: 500)
    scheduler.advance(ms: 500)
    #expect(
      PasteTargetWindowGate.refusal(
        target: .recordedWindow(windowA), element: nil, pid: pid, ax: ax, admit: spent.admit)
        == nil)
  }

  // MARK: The field's window recorded at record start (#3961)

  /// A focused replacement box: same process, a text role, in `window`. Its handle pid is 5003 in
  /// the fake, so `elementOwners` makes it belong to the target app.
  private func replacement(role: String = "AXTextArea", in window: AXUIElement? = nil) {
    ax.focusedByApplication[pid] = .element(otherField)
    ax.elementOwners[5003] = pid
    ax.rolesByElement[5003] = role
    ax.windows[5003] = .window(window ?? windowA)
  }

  private func decideStart(_ admit: ((AXUIElement) -> Bool)? = nil)
    -> PasteTargetWindowGate.Decision
  {
    PasteTargetWindowGate.decide(
      target: .startFieldWindow(windowA), element: field, pid: pid, ax: ax,
      admit: admit ?? budget().admit)
  }

  @Test("An unreadable field window falls back to the start window; with none, unreadable")
  func resolveStartFieldWindow() {
    ax.windows[10_042] = .failed(.invalidUIElement)
    guard
      case .startFieldWindow(let window) = PasteTargetWindowGate.resolve(
        element: field, startFieldWindow: windowB, ax: ax, admit: budget().admit)
    else {
      Issue.record("expected .startFieldWindow")
      return
    }
    #expect(CFEqual(window, windowB))
    guard case .unreadable = resolved(field) else {
      Issue.record("expected .unreadable without a start window")
      return
    }
    ax.windows[10_042] = .window(windowA)
    guard
      case .window(let live) = PasteTargetWindowGate.resolve(
        element: field, startFieldWindow: windowB, ax: ax, admit: budget().admit)
    else {
      Issue.record("a readable field window wins over the start window")
      return
    }
    #expect(CFEqual(live, windowA))
    guard
      case .none = PasteTargetWindowGate.resolve(
        element: nil, startFieldWindow: windowB, ax: ax, admit: budget().admit)
    else {
      Issue.record("no captured field stays .none")
      return
    }
  }

  @Test("The captured field still passes when it is the focus, before any candidate read")
  func startWindowFieldFocused() {
    ax.focusedByApplication[pid] = .element(field)
    #expect(decideStart() == .pass(.fieldFocused))
    #expect(ax.landingCalls.map(\.call) == ["focusedElement"])
  }

  @Test("A text box of the same app in the start window receives the paste (the #3961 repro)")
  func startWindowReplacementPasses() {
    for role in ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField"] {
      replacement(role: role)
      ax.landingCalls = []
      #expect(decideStart() == .pass(.replacementField), "\(role)")
      #expect(ax.landingCalls.map(\.call) == ["focusedElement", "pid", "window"])
    }
  }

  @Test("Another window, another app, a password box or a non-text focus is refused")
  func startWindowRefusals() {
    replacement(in: windowB)
    #expect(decideStart() == .refuse(.windowUnreadableFocusMismatch), "another window")

    replacement()
    ax.elementOwners[5003] = 77
    #expect(decideStart() == .refuse(.windowUnreadableFocusMismatch), "another process")

    replacement()
    ax.subroles["\(CFHash(otherField))"] = .subrole(kAXSecureTextFieldSubrole as String)
    #expect(decideStart() == .refuse(.windowUnreadableFocusMismatch), "secure field")
    ax.subroles["\(CFHash(otherField))"] = .unreadable
    #expect(decideStart() == .refuse(.windowUnreadableFocusMismatch), "unreadable subrole")
    ax.subroles = [:]

    for role in ["AXGroup", "AXWebArea", "AXButton"] {
      replacement(role: role)
      ax.landingCalls = []
      #expect(decideStart() == .refuse(.windowUnreadableFocusMismatch), "\(role)")
      #expect(
        ax.landingCalls.map(\.call).contains("window") == false, "no window read for \(role)")
    }
  }

  @Test("Every unreadable answer about the candidate refuses with today's reason")
  func startWindowUnreadableCandidate() {
    replacement()
    ax.focusedByApplication[pid] = .queryFailed(.cannotComplete)
    #expect(decideStart() == .refuse(.windowUnreadableFocusMismatch), "focus query failed")
    ax.focusedByApplication[pid] = .noFocus
    #expect(decideStart() == .refuse(.windowUnreadableFocusMismatch), "nothing focused")

    replacement()
    ax.elementOwners[5003] = .some(nil)
    #expect(decideStart() == .refuse(.windowUnreadableFocusMismatch), "pid unreadable")

    replacement()
    ax.rolesByElement[5003] = .some(nil)
    #expect(decideStart() == .refuse(.windowUnreadableFocusMismatch), "role unreadable")

    let answers: [PastedRegionWindowRead] = [
      .absent, .notElement, .failed(.invalidUIElement), .failed(.cannotComplete),
    ]
    for answer in answers {
      replacement()
      ax.windows[5003] = answer
      #expect(decideStart() == .refuse(.windowUnreadableFocusMismatch), "\(answer)")
    }
  }

  @Test("The budget fails closed at every admission, and nothing is read after the refusal")
  func startWindowBudget() {
    // The helper admits six times: the app, then the candidate before its pid, subrole, role and
    // window reads, and once more after the window read. Refusing the Nth admission must stop
    // every later read, including the subrole and role reads `landingCalls` does not record.
    let expected: [(reads: [String], decision: PasteTargetWindowGate.Decision)] = [
      ([], .refuse(.budget)),
      (["focusedElement"], .refuse(.budget)),
      (["focusedElement", "pid"], .refuse(.budget)),
      (["focusedElement", "pid", "subrole"], .refuse(.budget)),
      (["focusedElement", "pid", "subrole", "role"], .refuse(.budget)),
      (["focusedElement", "pid", "subrole", "role", "window"], .refuse(.budget)),
      (["focusedElement", "pid", "subrole", "role", "window"], .pass(.replacementField)),
    ]
    for (admitted, row) in expected.enumerated() {
      replacement()
      var reads: [String] = []
      ax.onLandingCall = { reads.append($0) }
      ax.onSubroleRead = { reads.append("subrole") }
      let rolesBefore = ax.roleReads
      var admissions = 0
      let decision = PasteTargetWindowGate.decide(
        target: .startFieldWindow(windowA), element: field, pid: pid, ax: ax,
        admit: { _ in
          admissions += 1
          return admissions <= admitted
        })
      // The fake's role read has no hook; place it by its counter, after the subrole read.
      if ax.roleReads > rolesBefore, let at = reads.firstIndex(of: "subrole") {
        reads.insert("role", at: at + 1)
      }
      #expect(decision == row.decision, "refusing admission \(admitted + 1)")
      #expect(reads == row.reads, "refusing admission \(admitted + 1)")
    }
    ax.onLandingCall = nil
    ax.onSubroleRead = nil

    // A real budget spent by the window read is caught by the final admission.
    replacement()
    let last = budget(totalMs: 500)
    ax.onLandingCall = { call in if call == "window" { self.scheduler.advance(ms: 500) } }
    #expect(decideStart(last.admit) == .refuse(.budget), "spent by the last read")
    ax.onLandingCall = nil
  }

  @Test("A live field whose window turned unreadable: same field, same-window box, other window")
  func liveFieldWindowTurnedUnreadable() {
    // The window read worked at record start (it is the start window) and fails now, though the
    // field is still alive (a refused or timed-out read, not a rebuild).
    ax.windows[10_042] = .failed(.cannotComplete)
    let target = PasteTargetWindowGate.resolve(
      element: field, startFieldWindow: windowA, ax: ax, admit: budget().admit)
    ax.focusedByApplication[pid] = .element(field)
    #expect(
      PasteTargetWindowGate.decide(
        target: target, element: field, pid: pid, ax: ax, admit: budget().admit)
        == .pass(.fieldFocused))
    replacement()
    #expect(
      PasteTargetWindowGate.decide(
        target: target, element: field, pid: pid, ax: ax, admit: budget().admit)
        == .pass(.replacementField), "founder 2026-10-20: the box with the cursor in that window")
    replacement(in: windowB)
    #expect(
      PasteTargetWindowGate.decide(
        target: target, element: field, pid: pid, ax: ax, admit: budget().admit)
        == .refuse(.windowUnreadableFocusMismatch))
  }

  @Test("The start window is raised on activation and logged as field_window_recorded")
  func startWindowRaiseAndLogKind() {
    #expect(
      PasteCascadeExecutor.windowToRaise(.startFieldWindow(windowA)).map { CFEqual($0, windowA) }
        == true)
    #expect(
      PasteCascadeExecutor.windowToRaise(.window(windowB)).map { CFEqual($0, windowB) } == true)
    #expect(
      PasteCascadeExecutor.windowToRaise(.recordedWindow(windowB)).map { CFEqual($0, windowB) }
        == true)
    #expect(PasteCascadeExecutor.windowToRaise(.unreadable) == nil)
    #expect(PasteCascadeExecutor.windowToRaise(.none) == nil)
    #expect(PasteCascadeExecutor.gateLogKind(.startFieldWindow(windowA)) == "field_window_recorded")
    #expect(PasteCascadeExecutor.gateLogKind(.window(windowA)) == "field_window")
    #expect(PasteCascadeExecutor.gateLogKind(.unreadable) == "field_window_unreadable")
    #expect(PasteCascadeExecutor.gateLogKind(.recordedWindow(windowA)) == "recorded_window")
    #expect(PasteCascadeExecutor.gateLogKind(.none) == nil)
  }

  @Test("Decisions name why each captured-field case passed")
  func fieldPassReasons() {
    ax.focusedWindows[pid] = .window(windowA)
    #expect(
      PasteTargetWindowGate.decide(
        target: .window(windowA), element: field, pid: pid, ax: ax, admit: budget().admit)
        == .pass(.sameWindow))
    ax.focusedWindows[pid] = .window(windowB)
    ax.focusedByApplication[pid] = .element(field)
    #expect(
      PasteTargetWindowGate.decide(
        target: .window(windowA), element: field, pid: pid, ax: ax, admit: budget().admit)
        == .pass(.fieldFocused))
    #expect(
      PasteTargetWindowGate.decide(
        target: .none, element: nil, pid: pid, ax: ax, admit: budget().admit) == .pass(.noTarget))
  }

  @Test("Pass reasons are the strings logged by WINDOW_GATE dispatch lines")
  func passStrings() {
    #expect(PasteTargetWindowGate.Pass.noTarget.rawValue == "no_target")
    #expect(PasteTargetWindowGate.Pass.sameWindow.rawValue == "same_window")
    #expect(PasteTargetWindowGate.Pass.fieldFocused.rawValue == "field_focused")
    #expect(
      PasteTargetWindowGate.Pass.focusedWindowUnreadable.rawValue == "focused_window_unreadable")
    #expect(PasteTargetWindowGate.Pass.budget.rawValue == "budget")
    #expect(PasteTargetWindowGate.Pass.replacementField.rawValue == "replacement_field")
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
    #expect(Self.onElseOf("dispatchRefusal", node), "\(dispatch) dispatch-time gate")
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
      #expect(Self.onElseOf("dispatchRefusal", appends[0].node), "\(tier)")
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

  @Test("Tier 2 and 2b read the front app again after the omnibox re-check")
  func frontAppReadLast() throws {
    let (calls, _) = try Self.parse()
    let omnibox = calls.found.filter {
      $0.callee == "PasteService.freshFocusedElement"
        && $0.node.arguments.trimmedDescription.contains("remainingGateSeconds")
    }
    let frontReads = calls.found.filter { $0.callee == "Self.appFrontRefusal" }
    for dispatch in ["PasteService.pasteToActiveApp", "PasteService.pasteViaAppleScript"] {
      let node = try Self.only(dispatch, in: calls)
      let lastOmnibox = try #require(
        omnibox.filter { $0.node.position < node.position }.map(\.node.position).max())
      #expect(
        frontReads.contains { $0.node.position > lastOmnibox && $0.node.position < node.position },
        "\(dispatch)")
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
    #expect(writes.allSatisfy { Self.onElseOf("dispatchRefusal", $0.node) })
  }

  @Test(
    "Tier 2 and 2b: the owner path skips the omnibox read and ends on a full owner read (#3423)")
  func ownerPathEndsOnTheOwnerRead() throws {
    let (calls, _) = try Self.parse()
    let finals = calls.found.filter {
      $0.callee == "Self.appFrontRefusal"
        && $0.node.arguments.trimmedDescription.contains("ownerPathOnly: gate.ownerPath")
    }
    #expect(finals.count == 2)
    for final in finals {
      // The front path keeps a local front read after the omnibox re-check; only the owner path
      // reads the focus, and it is the last AX step (`PasteActivationAdmissionTests` runs it).
      #expect(final.node.arguments.trimmedDescription.contains("finalDestinationActivity("))
    }
    let omnibox = calls.found.filter {
      $0.callee == "PasteService.freshFocusedElement"
        && $0.node.arguments.trimmedDescription.contains("remainingGateSeconds")
    }
    #expect(omnibox.count == 2)
    #expect(omnibox.allSatisfy { Self.onElseOf("gate.ownerPath", $0.node) })
    // Control: the same helper reports the read as INSIDE the Chromium branch, not on its else.
    #expect(omnibox.allSatisfy { !Self.onElseOf("isChromiumOmnibox", $0.node) })
  }

  @Test("Control: the owner-path ordering check fails on a fixture whose omnibox read ignores it")
  func orderingCheckCatchesABrokenFixture() throws {
    let broken = """
      let ok: Bool =
        if gate.refusal != nil {
          true
        } else if isChromiumOmnibox {
          PasteService.freshFocusedElement(
            matching: element, messagingTimeout: remainingGateSeconds(gate.budget)) != nil
        } else if gate.ownerPath {
          true
        } else {
          true
        }
      """
    let calls = Calls()
    calls.walk(Parser.parse(source: broken))
    let omnibox = calls.found.filter { $0.callee == "PasteService.freshFocusedElement" }
    try #require(omnibox.count == 1)
    #expect(!Self.onElseOf("gate.ownerPath", omnibox[0].node))
  }

  @Test(
    "Activation asks the owner question once before raising, and its poll stays front-only (#3423)")
  func activationAdmission() throws {
    let (calls, _) = try Self.parse()
    let activity = calls.found.filter { $0.callee == "landingAX.destinationActivity" }
    let firstIssue = try #require(
      calls.found.filter { $0.callee == "issue" }.map(\.node.position).min())
    let admissions = activity.filter {
      $0.node.arguments.trimmedDescription.contains("budget: stepBudget()")
    }
    try #require(admissions.count == 1)
    #expect(admissions[0].node.arguments.trimmedDescription.contains("mode: .full"))
    #expect(admissions[0].node.position < firstIssue, "before any raise or activation")
    let polls = activity.filter {
      $0.node.arguments.trimmedDescription.contains("mode: .frontOnly,")
    }
    try #require(polls.count == 1)
    #expect(polls[0].node.position > firstIssue, "the poll runs after the first activation")
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
