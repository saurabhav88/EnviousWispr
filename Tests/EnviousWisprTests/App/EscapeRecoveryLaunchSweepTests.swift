import Foundation
import SwiftParser
import SwiftSyntax
import Testing

/// #2186: the launch path must sweep expired Escape Recovery rows.
///
/// ## The promise this binds
///
/// Three shipped surfaces tell the user a cancelled dictation is DELETED on a
/// schedule, and a public deletion promise needs a test that fails when it stops
/// being true. There was none, which is how the copy and the code drifted apart
/// in silence:
///
/// - `website/src/content/help/escape-recovery.md` — "removes it while the app
///   is running, **or the next time you launch it** … a dictation whose window
///   ended while the app was closed is **removed at the next launch**"
/// - `website/src/content/help/what-data-is-collected.md` — "After that it is
///   removed while the app is running, or the next time you launch it."
/// - `EscapeRecoveryRowPresentation.countdown` — "Deleted in 23h", "Deleting"
///
/// Before this guard, `TranscriptCoordinator.sweepExpiredPending()` was
/// reachable only from `load()`, whose one production caller is the History
/// view's `.task`, and from a pulse that arms on `pendingPulseHasWork` — which
/// reads `transcripts`, which only `load()` populates. A user who never opened
/// History never swept, so "removed at the next launch" did not happen at the
/// next launch.
///
/// ## This is a Drift Guard, and saying so is not bookkeeping
///
/// It proves the CALL is wired, never that a file left disk. The sweep's own
/// behaviour is already covered by `EscapeRecoveryTelemetryTests`, which drives
/// `sweepExpiredPending()` directly; duplicating that here would multiply an
/// axis without reaching a new branch.
///
/// ## Why it reads source, and why it PARSES rather than matches text
///
/// `applicationDidFinishLaunching()` cannot be constructed in a unit test — it
/// needs the whole object graph and `NSApp`. This repo has no unit test
/// asserting ANY launch-time wiring: the neighbouring `scanAndRecover()` limb is
/// proven by Live UAT, and the app-layer ceilings suites read source for the
/// same reason. Reading the declaration is the only mechanism available, so this
/// is a tripwire on the launch method, paired with the Live UAT that proves the
/// behaviour end to end.
///
/// **The first version of this guard matched text, and review was right to
/// refuse it.** The shipped call sits under a comment block that names
/// `sweepExpiredPending()` in prose, so a raw match stayed green after the
/// statement was deleted — a guard that looks binding and is not, which is worse
/// than none. Stripping comments fixed one lexical form and left the class:
/// a string literal, or a call surviving only inside an inactive `#if` branch,
/// would both have satisfied it, and the positive control could not tell.
///
/// So this walks a `SwiftParser` tree and requires an actual call expression.
/// Comments and every string form are excluded STRUCTURALLY rather than one
/// spelling at a time. `#if` blocks are skipped outright, which is deliberately
/// stronger than review asked for: a launch sweep reachable only under a
/// compilation condition does not ship to the users the promise was made to.
@Suite(.tags(.driftGuard))
struct EscapeRecoveryLaunchSweepTests {

  private static let sourcePath = "Sources/EnviousWisprAppKit/App/WisprBootstrapper.swift"

  /// Every `<receiver>.<method>(` call made directly by `functionNamed`, with
  /// `#if` subtrees skipped.
  ///
  /// Scoped to the METHOD on purpose: `WisprBootstrapper` is ~1,200 lines and
  /// names the coordinator many times, so a file-wide search would be satisfied
  /// by construction and could never fail.
  final class LaunchCallCollector: SyntaxVisitor {
    private(set) var calls: Set<String> = []

    /// A call that exists only under a compilation condition is not wired for
    /// the shipping build, so it must not count as wired at all.
    override func visit(_ node: IfConfigDeclSyntax) -> SyntaxVisitorContinueKind {
      .skipChildren
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
      if let member = node.calledExpression.as(MemberAccessExprSyntax.self),
        let receiver = member.base?.as(DeclReferenceExprSyntax.self)
      {
        calls.insert("\(receiver.baseName.text).\(member.declName.baseName.text)")
      }
      return .visitChildren
    }
  }

  static func calls(inFunctionNamed name: String, source: String) -> Set<String>? {
    final class Finder: SyntaxVisitor {
      let wanted: String
      var body: CodeBlockSyntax?
      init(_ wanted: String) {
        self.wanted = wanted
        super.init(viewMode: .sourceAccurate)
      }
      override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.name.text == wanted { body = node.body }
        return .visitChildren
      }
    }
    let finder = Finder(name)
    finder.walk(Parser.parse(source: source))
    guard let body = finder.body else { return nil }
    let collector = LaunchCallCollector(viewMode: .sourceAccurate)
    collector.walk(body)
    return collector.calls
  }

  @Test("the launch deletes expired cancelled dictations without waiting for History")
  func launchSweepsExpiredPendingRows() throws {
    let source = try String(
      contentsOf: RepoRoot.url.appending(path: Self.sourcePath), encoding: .utf8)
    let calls = try #require(
      Self.calls(inFunctionNamed: "applicationDidFinishLaunching", source: source),
      "applicationDidFinishLaunching() not found — this guard's subject moved, it did not pass")

    // POSITIVE CONTROL, first for a reason: if the parse or the scoping broke,
    // BOTH assertions fail and the failure is about this instrument rather than
    // about the launch path. Without it, an empty set reads exactly like a
    // deleted call.
    #expect(
      calls.contains("recoveryCoordinator.scanAndRecover"),
      """
      #2186 control: the neighbouring crash-recovery limb is missing from the parsed launch \
      body, so this guard could not see the launch path at all. Fix the parse before reading \
      the assertion below. Calls found: \(calls.sorted())
      """)

    #expect(
      calls.contains("transcriptCoordinator.sweepExpiredPending"),
      """
      #2186: applicationDidFinishLaunching() no longer sweeps expired Escape Recovery rows. \
      help/escape-recovery.md and help/what-data-is-collected.md both promise a cancelled \
      dictation is removed "the next time you launch it", and the in-app countdown says \
      "Deleted in 23h". Without this call the only sweep is the History view's .task, so a \
      user who never opens History keeps the plaintext of a dictation they cancelled, \
      indefinitely. Calls found: \(calls.sorted())
      """)
  }

  @Test("no unexecuted spelling of the sweep can satisfy the launch guard")
  func unexecutedSpellingsDoNotCount() throws {
    // The rejected twin of the accepted case above, over every form that
    // defeated the earlier text version: a line comment, a block comment, a
    // string literal, and a call alive only inside an inactive `#if`. Without
    // this, a future simplification back to text matching would look equivalent.
    let decoys = """
      final class Fixture {
        func applicationDidFinishLaunching() {
          recoveryCoordinator.scanAndRecover()
          // transcriptCoordinator.sweepExpiredPending()
          /* transcriptCoordinator.sweepExpiredPending() */
          log("transcriptCoordinator.sweepExpiredPending()")
          #if DEBUG
            Task { await transcriptCoordinator.sweepExpiredPending() }
          #endif
        }
      }
      """
    let found = try #require(
      Self.calls(inFunctionNamed: "applicationDidFinishLaunching", source: decoys))

    #expect(
      !found.contains("transcriptCoordinator.sweepExpiredPending"),
      "a commented, quoted or #if-only sweep must not satisfy the launch guard: \(found.sorted())")
    // Paired accepted case in the same fixture, so a walker that simply finds
    // nothing cannot pass this suite.
    #expect(
      found.contains("recoveryCoordinator.scanAndRecover"),
      "the walker missed a live call in the same body: \(found.sorted())")
  }

  @Test("a real call is still found when it sits inside a Task closure")
  func aCallInsideATaskClosureCounts() throws {
    // The shipping shape. Asserted separately so that if the production call is
    // ever moved out of its `Task`, the failure names the shape rather than
    // looking like a deleted call.
    let shipped = """
      final class Fixture {
        func applicationDidFinishLaunching() {
          Task { await transcriptCoordinator.sweepExpiredPending() }
        }
      }
      """
    let found = try #require(
      Self.calls(inFunctionNamed: "applicationDidFinishLaunching", source: shipped))
    #expect(found.contains("transcriptCoordinator.sweepExpiredPending"))
  }
}
