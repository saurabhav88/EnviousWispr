import AppKit
import ApplicationServices
import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprPipeline
@testable import EnviousWisprPostProcessing

/// The Escape Recovery Undo delivery (#3437): held text through dictation's own Smart Insertion
/// and cascade request.
///
/// When these fail, the user's Undo text lands differently from how the same dictation would have
/// landed (a missing space before it, a wrong capital, the wrong box), or Undo claims a paste that
/// left the text only on the clipboard.
@MainActor
@Suite("Held text delivery for Escape Recovery Undo (#3437)", .tags(.productOutcome))
struct HeldTextDeliveryTests {

  // MARK: Fixtures

  /// Records every seam and cascade call, so a case can prove what ran and what never did.
  @MainActor
  final class Calls {
    var caretReads: [TerminalResolutionBudget] = []
    var retryQueries: [pid_t] = []
    var requests: [PasteDeliveryRequest] = []
    var lines: [String] = []
  }

  nonisolated static let oracle = SeamCasingOracle(
    unavailableReason: nil, dictionaryVerdict: { _ in .notOrdinary },
    isLearnedWord: { _ in false }, isRecognizedName: { _, _ in false }, isNoun: { _ in false })

  private func seams(
    _ calls: Calls, caret: PasteService.CaretContext?, retryAnswer: AXUIElement? = nil,
    inRecordedWindow: Bool = true
  ) -> KernelFinalizationWiring.InsertionSeams {
    KernelFinalizationWiring.InsertionSeams(
      readCaretContext: { _, budget, _ in
        calls.caretReads.append(budget)
        return caret
      },
      focusedElementInTargetApp: { pid in
        calls.retryQueries.append(pid)
        return retryAnswer
      },
      isRetryTargetUsable: { _ in true },
      recoveredIsInRecordedWindow: { _, _ in inRecordedWindow },
      seamCasingOracle: { _ in Self.oracle },
      releaseOracleLease: {},
      resolveLanguage: KernelFinalizationWiring.InsertionSeams.live.resolveLanguage,
      currentTime: { 0 })
  }

  private static let noFacts = InsertionTakeFacts(
    snippetFired: false, lockedLanguageCode: nil, engineDetectsLanguage: false,
    engineReportedLanguage: nil, protectedSpellings: [])

  private static func settings(smart: Bool = true, autoPaste: Bool = true, restore: Bool = false)
    -> HeldDeliverySettings
  {
    HeldDeliverySettings(
      smartInsertion: smart, autoPasteToActiveApp: autoPaste, restoreClipboardAfterPaste: restore)
  }

  /// A field handle. Never messaged: every read goes through the injected seams.
  private static func field() -> AXUIElement {
    AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
  }

  /// A live, non-terminated app, as `KernelFinalizationWiringTests.stubTargetApp` explains.
  private static func liveApp() -> NSRunningApplication {
    // swift-format-ignore: NeverForceUnwrap — the running-app list is never empty on a test host.
    NSWorkspace.shared.runningApplications.first!
  }

  private static let afterSentence = PasteService.CaretContext(
    leftWindow: "Hello.", rightWindow: "", selectionLocation: 6, selectionLength: 0,
    leftReachesDocumentStart: true)

  private func run(
    _ text: String = "World.", calls: Calls, seams: KernelFinalizationWiring.InsertionSeams,
    app: NSRunningApplication? = nil, element: AXUIElement? = HeldTextDeliveryTests.field(),
    window: AXUIElement? = nil, takeID: String? = "take-1",
    facts: InsertionTakeFacts = HeldTextDeliveryTests.noFacts,
    settings: HeldDeliverySettings = HeldTextDeliveryTests.settings(),
    board: NSPasteboard? = nil,
    returning result: PasteDeliveryResult = PasteDeliveryResult(
      tier: .cgEvent, durationMs: 1, outcome: .delivered(tier: .cgEvent, durationMs: 1))
  ) async -> HeldTextDeliveryResult {
    let pasteboard = board ?? NSPasteboard.withUniqueName()
    defer { if board == nil { pasteboard.releaseGlobally() } }
    return await HeldTextDelivery.deliver(
      text: text, targetApp: app, targetElement: element, targetWindow: window, takeID: takeID,
      facts: facts, settings: settings, seams: seams, pasteboard: pasteboard,
      cascade: { request in
        calls.requests.append(request)
        return result
      },
      log: { line in await MainActor.run { calls.lines.append(line) } })
  }

  // MARK: Smart Insertion, exactly as dictation

  @Test("\"Hello.\" then Undo of \"World.\" offers the leading space dictation would add")
  func smartInsertionAddsTheLeadingSpace() async throws {
    let calls = Calls()
    _ = await run(calls: calls, seams: seams(calls, caret: Self.afterSentence))

    let request = try #require(calls.requests.first)
    #expect(request.legacyText == "World. ")
    #expect(request.repairedText == " World. ")
    #expect(request.caretContext == Self.afterSentence)
    #expect(request.origin == .escapeRecoveryUndo)
    #expect(request.takeID == "take-1")
  }

  @Test("Smart Insertion off reads no caret and offers no candidate, as dictation")
  func smartInsertionOffSkipsTheCaret() async throws {
    let calls = Calls()
    _ = await run(
      calls: calls, seams: seams(calls, caret: Self.afterSentence),
      settings: Self.settings(smart: false))

    let request = try #require(calls.requests.first)
    #expect(calls.caretReads.isEmpty)
    #expect(request.repairedText == nil)
    #expect(request.legacyText == "World. ")
  }

  @Test("A snippet take keeps its text exactly: the frozen fact reaches the repair")
  func snippetFactBypassesTheRepair() async throws {
    let calls = Calls()
    let facts = InsertionTakeFacts(
      snippetFired: true, lockedLanguageCode: nil, engineDetectsLanguage: false,
      engineReportedLanguage: nil, protectedSpellings: [])
    _ = await run(calls: calls, seams: seams(calls, caret: Self.afterSentence), facts: facts)

    let request = try #require(calls.requests.first)
    #expect(request.repairedText == nil, "a snippet takes the legacy payload, as in dictation")
  }

  @Test("The request carries the caret reader's own budget, the one the cascade revalidates with")
  func requestCarriesTheSameBudget() async throws {
    let calls = Calls()
    _ = await run(calls: calls, seams: seams(calls, caret: Self.afterSentence))

    let request = try #require(calls.requests.first)
    let readBudget = try #require(calls.caretReads.first)
    let sent = try #require(request.terminalBudget)
    #expect(sent === readBudget)
  }

  // MARK: Target resolution, exactly as dictation

  @Test("No captured field: the shared retry runs, its field is adopted and marked retried")
  func retryRecoversAField() async throws {
    let calls = Calls()
    let app = Self.liveApp()
    let recovered = AXUIElementCreateApplication(4242)
    let window = AXUIElementCreateApplication(5001)
    _ = await run(
      calls: calls, seams: seams(calls, caret: nil, retryAnswer: recovered), app: app,
      element: nil, window: window)

    let request = try #require(calls.requests.first)
    #expect(calls.retryQueries == [app.processIdentifier])
    #expect(request.targetElementIsRetried == true)
    #expect(request.targetElement.map { CFEqual($0, recovered) } == true)
    #expect(request.recordedWindow.map { CFEqual($0, window) } == true)
  }

  @Test("A retry field in another window is rejected; the recorded window still protects the paste")
  func retryRejectedKeepsTheWindow() async throws {
    let calls = Calls()
    let window = AXUIElementCreateApplication(5001)
    _ = await run(
      calls: calls,
      seams: seams(
        calls, caret: nil, retryAnswer: AXUIElementCreateApplication(4242),
        inRecordedWindow: false),
      app: Self.liveApp(), element: nil, window: window)

    let request = try #require(calls.requests.first)
    #expect(request.targetElementIsRetried == true, "attempted, even though rejected")
    #expect(request.targetElement == nil)
    #expect(request.recordedWindow.map { CFEqual($0, window) } == true)
  }

  @Test("A captured field is used as is and never retried")
  func capturedFieldIsNotRetried() async throws {
    let calls = Calls()
    let field = Self.field()
    _ = await run(
      calls: calls, seams: seams(calls, caret: Self.afterSentence), app: Self.liveApp(),
      element: field)

    let request = try #require(calls.requests.first)
    #expect(calls.retryQueries.isEmpty)
    #expect(request.targetElementIsRetried == false)
    #expect(request.targetElement.map { CFEqual($0, field) } == true)
  }

  @Test("Dictation's request builder and Undo's agree on every field but origin")
  func requestParityWithDictation() async throws {
    let calls = Calls()
    let app = Self.liveApp()
    let field = Self.field()
    let window = AXUIElementCreateApplication(5001)
    let theSeams = seams(calls, caret: Self.afterSentence)
    _ = await run(
      calls: calls, seams: theSeams, app: app, element: field, window: window,
      settings: Self.settings(restore: true))
    let held = try #require(calls.requests.first)

    let dictationComputation = await KernelFinalizationWiring.computeInsertion(
      text: "World.", smartInsertion: true, targetApp: app, targetElement: field,
      targetWindow: window, seams: theSeams, afterCaret: { _ in Self.noFacts })
    let dictation = KernelFinalizationWiring.deliveryRequest(
      computation: dictationComputation, targetApp: app, recordedWindow: window,
      takeID: "take-1", restoreClipboardAfterPaste: true, origin: .dictation)

    #expect(held.legacyText == dictation.legacyText)
    #expect(held.repairedText == dictation.repairedText)
    #expect(held.caretContext == dictation.caretContext)
    #expect(held.candidateDeletesDictatedText == dictation.candidateDeletesDictatedText)
    #expect(held.targetApp == dictation.targetApp)
    #expect(held.targetElement == dictation.targetElement)
    #expect(held.recordedWindow == dictation.recordedWindow)
    #expect(held.targetElementIsRetried == dictation.targetElementIsRetried)
    #expect(held.restoreClipboardAfterPaste == dictation.restoreClipboardAfterPaste)
    #expect(held.takeID == dictation.takeID)
    #expect(held.origin == .escapeRecoveryUndo && dictation.origin == .dictation)
  }

  // MARK: Outcome, receipt and diagnostics

  @Test("Each cascade outcome maps to what Undo tells the user")
  func outcomeMapping() {
    #expect(HeldTextDelivery.outcome(of: .delivered(tier: .cgEvent, durationMs: 1)) == .pasted)
    #expect(
      HeldTextDelivery.outcome(of: .clipboardOnlyAccessibilityDenied(targetBundleID: nil))
        == .accessibilityDenied)
    #expect(
      HeldTextDelivery.outcome(of: .cgEventCreationFailed(accessibilityTrusted: true))
        == .clipboardOnly)
    #expect(
      HeldTextDelivery.outcome(
        of: .clipboardOnly(
          tiersAttempted: [], focus: .missing, targetBundleID: nil,
          accessibilityTrusted: true, targetDiagnostics: .missing))
        == .clipboardOnly)
    #expect(
      HeldTextDelivery.outcome(
        of: .axWriteUnverifiable(targetBundleID: nil, targetDiagnostics: .unavailable))
        == .clipboardOnly)
  }

  /// The committed arrival session holds its own timers weakly, so something must own it until
  /// its one report. The test drops every reference it holds; only the delivery's own task can
  /// keep the session alive long enough to report.
  @Test("A committed arrival session outlives the delivery and reports once")
  func arrivalSessionIsKeptAliveUntilItReports() async throws {
    let ax = PastedRegionFakeAX()
    let scheduler = PastedRegionFakeScheduler()
    let pid: pid_t = 42
    ax.focusedByApplication[pid] = .element(PastedRegionFakeAX.field(pid))
    ax.focused[pid] = .element(PastedRegionFakeAX.field(pid))
    ax.reads = [.text("Hello")]
    ax.selectedRange = .range(location: 5, length: 0)
    let reports = Calls()
    var session: PasteArrivalCapture? = PasteArrivalCapture.prepare(
      .init(
        tier: .cgEvent, pid: pid, takeID: "take-1", bundleID: "com.apple.TextEdit",
        payload: "World. ", origin: "escape_recovery_undo"),
      capturedTarget: nil, restoringCapturedTimeoutTo: 0, ax: ax, scheduler: scheduler,
      report: { reports.lines.append($0.origin ?? "nil") })
    try #require(session != nil)
    session?.commit()
    var delivered = PasteDeliveryResult(
      tier: .cgEvent, durationMs: 1, outcome: .delivered(tier: .cgEvent, durationMs: 1))
    delivered.arrivalCapture = session
    session = nil

    let calls = Calls()
    _ = await run(calls: calls, seams: seams(calls, caret: nil), returning: delivered)
    delivered.arrivalCapture = nil
    // Let the delivery's task start awaiting the session, then run its clock to the report.
    await Task.yield()
    scheduler.advance(ms: 1_500)

    #expect(reports.lines == ["escape_recovery_undo"], "exactly one report, from a session nothing else held")
  }

  @Test("The Tier 3 receipt is forwarded unchanged; a delivered paste carries none")
  func receiptIsForwarded() async {
    let calls = Calls()
    var fallback = PasteDeliveryResult(
      tier: .clipboardOnly, durationMs: 1,
      outcome: .clipboardOnlyAccessibilityDenied(targetBundleID: nil))
    fallback.fallbackClipboardChangeCount = 42
    let kept = await run(
      calls: calls, seams: seams(calls, caret: nil), returning: fallback)
    #expect(
      kept
        == HeldTextDeliveryResult(outcome: .accessibilityDenied, fallbackClipboardChangeCount: 42))

    let pasted = await run(calls: calls, seams: seams(calls, caret: nil))
    #expect(pasted == HeldTextDeliveryResult(outcome: .pasted, fallbackClipboardChangeCount: nil))
  }

  @Test("The CURSOR_REPAIR line names the restore's origin")
  func diagnosticNamesTheOrigin() async throws {
    let calls = Calls()
    _ = await run(calls: calls, seams: seams(calls, caret: Self.afterSentence))
    let line = try #require(calls.lines.first)
    #expect(line.hasPrefix("CURSOR_REPAIR "))
    #expect(line.hasSuffix(" origin=escape_recovery_undo"))
  }

  // MARK: Auto-paste off

  @Test("Auto-paste off copies the held text, returns its receipt, and touches no field")
  func autoPasteOffOnlyCopies() async {
    let calls = Calls()
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }

    let result = await run(
      calls: calls, seams: seams(calls, caret: Self.afterSentence), app: Self.liveApp(),
      element: nil, settings: Self.settings(autoPaste: false), board: board)

    #expect(result.outcome == .clipboardOnly)
    #expect(board.string(forType: .string) == "World.")
    #expect(result.fallbackClipboardChangeCount == board.changeCount)
    #expect(calls.caretReads.isEmpty && calls.retryQueries.isEmpty)
    #expect(calls.requests.isEmpty, "no cascade, so nothing can restore over the copy")
    #expect(calls.lines.isEmpty)
  }

  // MARK: Real cascade, isolated board

  /// The cascade itself, not a stand-in: with no target the cascade's own Tier 3 is the only
  /// writer, so this proves the receipt is the real board's count after the real write.
  private func realDelivery(
    _ text: String, board: NSPasteboard, restore: Bool, calls: Calls
  ) async -> HeldTextDeliveryResult {
    await HeldTextDelivery.deliver(
      text: text, targetApp: nil, targetElement: nil, targetWindow: nil, takeID: "take-x",
      facts: Self.noFacts, settings: Self.settings(restore: restore),
      seams: seams(calls, caret: nil), pasteboard: board,
      cascade: { request in
        await PasteCascadeExecutor(pasteboard: board, policy: .baseline).deliver(request)
      },
      log: { _ in })
  }

  @Test(
    "Two restores ending on one board: each consumed its own text; only the latest receipt is fresh",
    arguments: [false, true])
  func interleavedRestoresKeepTheirOwnReceipts(restoreClipboard: Bool) async throws {
    let calls = Calls()
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }

    let first = await realDelivery("first held", board: board, restore: restoreClipboard, calls: calls)
    let firstReceipt = try #require(first.fallbackClipboardChangeCount)
    // Which fallback depends on whether the test runner holds Accessibility trust (the cascade
    // names a denial separately); both mean the text is on the board and nowhere else.
    #expect([.clipboardOnly, .accessibilityDenied].contains(first.outcome))
    #expect(board.string(forType: .string) == "first held ")

    let second = await realDelivery("second held", board: board, restore: restoreClipboard, calls: calls)
    let secondReceipt = try #require(second.fallbackClipboardChangeCount)
    #expect(board.string(forType: .string) == "second held ")

    #expect(board.changeCount == secondReceipt, "the latest write's notice may still show")
    #expect(board.changeCount != firstReceipt, "the earlier restore's notice would now be stale")
  }
}
