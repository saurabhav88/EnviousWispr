import AppKit
import Foundation
import SwiftParser
import SwiftSyntax
import Testing

@testable import EnviousWisprPipeline
@testable import EnviousWisprServices

/// Product Outcome: the landing check a committed key paste hands its clipboard cleanup (#3106 PR B).
///
/// When this fails, a missed paste's words are restored away instead of kept, a route that must keep
/// today's timing waits for a decision, or AppKit is told about the wrong take (or twice).
///
/// The system-paste tiers are inert on the isolated boards tests use, so the cascade's routes are
/// covered twice: the check itself is built and exercised here, and the drift guard below proves
/// every route passes it to the one cleanup.
@Suite(
  "Paste cascade hands a committed paste's landing check to its cleanup (#3106 PR B)",
  .tags(.productOutcome))
@MainActor
struct PasteCascadeLandingHandoffTests {
  let ax = PastedRegionFakeAX()
  let scheduler = PastedRegionFakeScheduler()
  let pid: pid_t = 42

  init() {
    ax.focusedByApplication[pid] = .element(PastedRegionFakeAX.field(pid))
    ax.focused[pid] = .element(PastedRegionFakeAX.field(pid))
    ax.reads = [.text("Hi ")]
    ax.selectedRange = .range(location: 3, length: 0)
  }

  struct NotPrepared: Error {}

  private func capture(tier: PasteTier = .cgEvent, bundle: String? = "com.apple.TextEdit") throws
    -> PasteArrivalCapture
  {
    guard
      let session = PasteArrivalCapture.prepare(
        .init(tier: tier, pid: pid, takeID: "take-1", bundleID: bundle, payload: "Sarah "),
        capturedTarget: nil, restoringCapturedTimeoutTo: 0, ax: ax, scheduler: scheduler,
        report: { _ in })
    else { throw NotPrepared() }
    return session
  }

  private func request(takeID: String? = "take-1") -> PasteDeliveryRequest {
    PasteDeliveryRequest(
      legacyText: "Sarah ", repairedText: nil, caretContext: nil,
      candidateDeletesDictatedText: false, targetApp: nil, targetElement: nil,
      targetElementIsRetried: false, restoreClipboardAfterPaste: true, terminalBudget: nil,
      takeID: takeID)
  }

  @MainActor
  final class Calls {
    var retained: [(String, Int)] = []
    var reports: [@MainActor (Bool) -> Void] = []
  }

  private func executor(_ calls: Calls) -> PasteCascadeExecutor {
    let board = NSPasteboard.withUniqueName()
    return PasteCascadeExecutor(
      pasteboard: board, policy: .baseline,
      onRetained: { takeID, count, report in
        calls.retained.append((takeID, count))
        calls.reports.append(report)
      })
  }

  @Test("No committed session, Tier 1 or an unnamed app: no check, so today's cleanup runs")
  func noCheckWithoutAKeyPasteSession() throws {
    let exec = executor(Calls())
    #expect(exec.landingCheck(for: nil, request: request()) == nil)
    let tier1 = PasteArrivalCapture.editOnly(
      pid: pid, bundleID: "com.apple.TextEdit", payload: "Sarah ", ax: ax, scheduler: scheduler)
    #expect(exec.landingCheck(for: tier1, request: request()) == nil)
    #expect(exec.landingCheck(for: try capture(bundle: nil), request: request()) == nil)
  }

  @Test(
    "Each key route gets a check carrying the legacy text and this app's permission",
    arguments: [PasteTier.cgEvent, .appleScript, .menuPaste])
  func keyRouteGetsACheck(tier: PasteTier) throws {
    let session = try capture(tier: tier)
    let check = try #require(executor(Calls()).landingCheck(for: session, request: request()))
    #expect(check.legacyText == "Sarah ")
    #expect(
      check.mayRetain(.absent)
        == PasteLandingPolicy.mayRetain(
          .absent, bundleID: "com.apple.TextEdit", appClass: session.appClass, tier: tier))
    #expect(check.mayRetain(.found(.sameField)) == false)
  }

  @Test("Only a retained outcome reaches AppKit, once, with this take and the board receipt")
  func onlyRetainedIsForwarded() throws {
    let calls = Calls()
    let check = try #require(executor(calls).landingCheck(for: try capture(), request: request()))
    check.onOutcome(.yielded)
    #expect(calls.retained.isEmpty)
    check.onOutcome(.retained(changeCount: 7))
    #expect(calls.retained.count == 1)
    #expect(calls.retained.first?.0 == "take-1")
    #expect(calls.retained.first?.1 == 7)
  }

  @Test("A delivery with no take id reports nothing: there is no take to show a pill for")
  func noTakeIDReportsNothing() throws {
    let calls = Calls()
    let check = try #require(
      executor(calls).landingCheck(for: try capture(), request: request(takeID: nil)))
    check.onOutcome(.retained(changeCount: 7))
    #expect(calls.retained.isEmpty)
  }

  #if DEBUG
    // MARK: paste.landing_retained, read through the DEBUG raw hook around synchronous calls

    @MainActor private final class RawBox { var rows: [[String: Any]] = [] }

    /// The raw `paste.landing_retained` dictionaries emitted during one synchronous call; the hook
    /// in place before is kept for every other event and put back after.
    private func retainedRows(_ emit: () -> Void) -> [[String: Any]] {
      let box = RawBox()
      let prior = TelemetryService.shared.testRawPropertiesHook
      TelemetryService.shared.testRawPropertiesHook = { @Sendable name, props in
        guard name == "paste.landing_retained" else {
          prior?(name, props)
          return
        }
        nonisolated(unsafe) let props = props
        MainActor.assumeIsolated { box.rows.append(props) }
      }
      defer { TelemetryService.shared.testRawPropertiesHook = prior }
      emit()
      return box.rows
    }

    @Test("A retained row waits for the overlay's verdict, then is emitted once with exactly five keys")
    func retainedRowCarriesThePillVerdictOnce() throws {
      let calls = Calls()
      let session = try capture()
      let check = try #require(executor(calls).landingCheck(for: session, request: request()))
      let early = retainedRows { check.onOutcome(.retained(changeCount: 7)) }
      #expect(early.isEmpty, "no row before the overlay answers")
      let report = try #require(calls.reports.first)
      let rows = retainedRows {
        report(true)
        report(false)  // a second answer is ignored
      }
      #expect(rows.count == 1)
      let row = try #require(rows.first)
      #expect(Set(row.keys) == ["take_id", "tier", "app_class", "outcome", "pill_shown"])
      #expect(row["take_id"] as? String == "take-1")
      #expect(row["tier"] as? String == "cgevent")
      #expect(row["app_class"] as? String == session.appClass.rawValue)
      #expect(row["outcome"] as? String == "retained")
      #expect(row["pill_shown"] as? Bool == true)
    }

    @Test("A yielded miss is one row at once, pill_shown false, and never reaches AppKit")
    func yieldedRowIsImmediate() throws {
      let calls = Calls()
      let check = try #require(executor(calls).landingCheck(for: try capture(), request: request()))
      let rows = retainedRows { check.onOutcome(.yielded) }
      #expect(calls.retained.isEmpty)
      #expect(rows.count == 1)
      #expect(rows.first?["outcome"] as? String == "yielded")
      #expect(rows.first?["pill_shown"] as? Bool == false)
    }

    @Test("A retained miss with no take id has no pill to show: one row, pill_shown false, no take id")
    func retainedWithoutTakeIDIsReportedNotShown() throws {
      let calls = Calls()
      let check = try #require(
        executor(calls).landingCheck(for: try capture(), request: request(takeID: nil)))
      let rows = retainedRows { check.onOutcome(.retained(changeCount: 7)) }
      #expect(calls.retained.isEmpty)
      #expect(rows.count == 1)
      #expect(rows.first?["take_id"] == nil)
      #expect(rows.first?["pill_shown"] as? Bool == false)
    }
  #endif

  @Test("A manual-accessibility answer learned during observation is the class the permission uses")
  func appClassIsReadAtDecisionTime() async throws {
    let slack = "com.tinyspeck.slackmacgap"
    ax.manualReadFails = [pid]
    let session = try capture(bundle: slack)
    #expect(session.appClass == .other, "unknown at prepare")
    // The host answers later, during the session's own reads, and turns out to be a manual host.
    ax.manualReadFails = []
    ax.manualHosts = [pid]
    let check = try #require(executor(Calls()).landingCheck(for: session, request: request()))
    session.commit()
    scheduler.advance(ms: PastedRegionTiming.landingDeadlineMs)
    let landing = try #require(await check.decision())
    #expect(landing == .absent)
    #expect(session.appClass == .manualAccessibility)
    #expect(check.mayRetain(landing))
    session.cancel()
  }

  @Test("An uncommitted session's decision is nil, which the cleanup treats as not a miss")
  func uncommittedSessionDecidesNothing() async throws {
    let session = try capture()
    let check = try #require(executor(Calls()).landingCheck(for: session, request: request()))
    #expect(await check.decision() == nil)
    session.cancelUnlessCommitted()
  }
}

/// Drift Guard: every clipboard cleanup a committed key paste schedules carries its landing check,
/// and both driver factories pass the two AppKit callbacks through (#3106 PR B).
///
/// Parsed with `SwiftParser`, so comments and strings can never satisfy it. Shape only.
@Suite("Paste cascade and factory landing wiring (#3106 PR B)", .tags(.driftGuard))
struct PasteCascadeLandingWiringTests {

  /// Every call named `name` in `source`, with its argument labels.
  private static func calls(named name: String, in source: String) -> [[String]] {
    final class Finder: SyntaxVisitor {
      let name: String
      var found: [[String]] = []
      init(name: String) {
        self.name = name
        super.init(viewMode: .sourceAccurate)
      }
      override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let callee = node.calledExpression.trimmedDescription
        if callee == name || callee.hasSuffix(".\(name)") {
          found.append(node.arguments.map { $0.label?.text ?? "_" })
        }
        return .visitChildren
      }
    }
    let finder = Finder(name: name)
    finder.walk(Parser.parse(source: source))
    return finder.found
  }

  private static func source(_ path: String) throws -> String {
    try String(contentsOf: RepoRoot.sourceURL(path), encoding: .utf8)
  }

  @Test("All three restore-ON key-paste cleanups and the restore-OFF one carry a landing check")
  func cascadeCleanupsCarryTheCheck() throws {
    let text = try Self.source("Sources/EnviousWisprPipeline/PasteCascadeExecutor.swift")
    let restores = Self.calls(named: "ClipboardCleanup.scheduleRestore", in: text)
    #expect(restores.count == 3)
    #expect(restores.allSatisfy { $0.contains("landing") }, "\(restores)")
    let rewrites = Self.calls(named: "ClipboardCleanup.scheduleLegacyRewrite", in: text)
    // One checked (restore off, committed key paste), one unchanged (every other case).
    #expect(rewrites.filter { $0.contains("landing") }.count == 1, "\(rewrites)")
    #expect(rewrites.count == 2)
  }

  @Test("The factory hands onRetained to the cascade and tells AppKit of each accepted take")
  func factoryWiresBothCallbacks() throws {
    let text = try Self.source("Sources/EnviousWisprPipeline/KernelDictationDriverFactory.swift")
    let executors = Self.calls(named: "PasteCascadeExecutor", in: text)
    #expect(executors.count == 1)
    #expect(executors.first?.contains("onRetained") == true, "\(executors)")
    let assembled = Self.calls(named: "assembleDriver", in: text)
    #expect(assembled.count == 2)
    #expect(
      assembled.allSatisfy { $0.contains("onTakeAccepted") && $0.contains("onRetained") },
      "\(assembled)")
    // Order inside the acceptance relay: the sink first, then AppKit.
    let accept = try #require(text.range(of: "lifecycleSink.acceptSession(takeID: takeID)"))
    let told = try #require(text.range(of: "onTakeAccepted(takeID)"))
    #expect(accept.upperBound <= told.lowerBound)
  }
}
