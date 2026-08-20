import Foundation
import Testing

/// #2186: the launch path must sweep expired Escape Recovery rows.
///
/// ## The promise this binds
///
/// Three shipped surfaces tell the user a cancelled dictation is DELETED on a
/// schedule, and `testing-philosophy.md`
/// RULE: a-public-product-promise-needs-a-binding-test says a claim like that
/// gets one test that fails when it stops being true. There was none, which is
/// how the copy and the code drifted apart in silence:
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
/// ## Why it reads source
///
/// `applicationDidFinishLaunching()` cannot be constructed in a unit test — it
/// needs the whole object graph and `NSApp`. This repo has no unit test
/// asserting ANY launch-time wiring: the neighbouring `scanAndRecover()` limb
/// is proven by Live UAT (`Tests/RuntimeUAT/SCENARIOS.md`), and the app-layer
/// ceilings suites parse source for the same reason. Reading the declaration is
/// the only mechanism available, so this is a tripwire on the launch method,
/// paired with the Live UAT that proves the behaviour end to end.
///
/// **Comments are stripped before matching, and that is load-bearing rather
/// than tidy.** The production call ships under a comment block that names
/// `sweepExpiredPending()` in prose. A guard matching raw text would be
/// satisfied by that comment alone, so deleting the actual statement would
/// leave this test GREEN — the mutant would survive and the guard would be a
/// decoration. `theGuardIsNotSatisfiedByAComment` is the paired rejected case
/// that holds the stripper honest.
@Suite(.tags(.driftGuard))
struct EscapeRecoveryLaunchSweepTests {

  private static let sourcePath = "Sources/EnviousWisprAppKit/App/WisprBootstrapper.swift"

  private static func bootstrapperSource() throws -> String {
    try String(contentsOf: RepoRoot.url.appending(path: sourcePath), encoding: .utf8)
  }

  /// The body of `applicationDidFinishLaunching()`, by brace matching.
  ///
  /// Scoped to the METHOD rather than the file on purpose: `WisprBootstrapper`
  /// is ~1,200 lines and mentions the coordinator many times, so a file-wide
  /// match would be satisfied by construction and could never fail. The
  /// question is whether the LAUNCH reaches the sweep.
  static func launchBody(in source: String) -> String? {
    guard let signature = source.range(of: "func applicationDidFinishLaunching()") else {
      return nil
    }
    guard let open = source[signature.upperBound...].firstIndex(of: "{") else { return nil }
    var depth = 0
    var index = open
    while index < source.endIndex {
      if source[index] == "{" { depth += 1 }
      if source[index] == "}" {
        depth -= 1
        if depth == 0 {
          return String(source[source.index(after: open)..<index])
        }
      }
      index = source.index(after: index)
    }
    return nil
  }

  /// Remove `//` line comments and `/* */` block comments.
  ///
  /// Deliberately does NOT try to respect string literals: the launch body
  /// contains none, and a stripper that models Swift's full lexical grammar is
  /// a bigger surface than the thing it guards. If a literal ever appears here
  /// the positive control below fails first, loudly.
  static func strippingComments(_ body: String) -> String {
    var out = ""
    var iterator = body.startIndex
    var inLine = false
    var inBlock = false
    while iterator < body.endIndex {
      let rest = body[iterator...]
      if !inLine, !inBlock, rest.hasPrefix("//") {
        inLine = true
        iterator = body.index(iterator, offsetBy: 2)
        continue
      }
      if !inLine, !inBlock, rest.hasPrefix("/*") {
        inBlock = true
        iterator = body.index(iterator, offsetBy: 2)
        continue
      }
      if inBlock, rest.hasPrefix("*/") {
        inBlock = false
        iterator = body.index(iterator, offsetBy: 2)
        continue
      }
      if inLine, body[iterator] == "\n" { inLine = false }
      if !inLine, !inBlock { out.append(body[iterator]) }
      iterator = body.index(after: iterator)
    }
    return out
  }

  @Test("the launch deletes expired cancelled dictations without waiting for History")
  func launchSweepsExpiredPendingRows() throws {
    let source = try Self.bootstrapperSource()
    let body = try #require(
      Self.launchBody(in: source),
      "applicationDidFinishLaunching() not found — this guard's subject moved, it did not pass")
    let code = Self.strippingComments(body)

    // POSITIVE CONTROL, and it runs first for a reason: if the extraction or
    // the stripper broke, BOTH assertions fail and the failure is about this
    // instrument rather than about the launch path. Without it, an empty `code`
    // reads exactly like a deleted call.
    #expect(
      code.contains("scanAndRecover("),
      """
      #2186 control: the neighbouring crash-recovery limb is missing from the extracted \
      launch body, so this guard could not see the launch path at all. Fix the extraction \
      before reading the assertion below.
      """)

    #expect(
      code.contains("transcriptCoordinator.sweepExpiredPending("),
      """
      #2186: applicationDidFinishLaunching() no longer sweeps expired Escape Recovery rows. \
      help/escape-recovery.md and help/what-data-is-collected.md both promise a cancelled \
      dictation is removed "the next time you launch it", and the in-app countdown says \
      "Deleted in 23h". Without this call the only sweep is the History view's .task, so a \
      user who never opens History keeps the plaintext of a dictation they cancelled, \
      indefinitely.
      """)
  }

  @Test("the guard is not satisfied by a comment that merely names the sweep")
  func theGuardIsNotSatisfiedByAComment() {
    // The rejected twin of the accepted case above. The real launch body ships
    // a comment naming `sweepExpiredPending()`, so without stripping, deleting
    // the statement would leave the guard green — a guard that looks binding
    // and is not, which is worse than none.
    let commentOnly = """
        appLifecycleCoordinator.runDidFinishLaunching()
        Task { await recoveryCoordinator.scanAndRecover() }
        // #2186: Task { await transcriptCoordinator.sweepExpiredPending() }
        /* transcriptCoordinator.sweepExpiredPending() */
      """
    let stripped = Self.strippingComments(commentOnly)

    #expect(
      !stripped.contains("transcriptCoordinator.sweepExpiredPending("),
      "a commented-out sweep must not satisfy the launch guard")
    // Paired accepted case, so a stripper that simply deletes everything cannot
    // pass this suite.
    #expect(
      stripped.contains("scanAndRecover("),
      "the stripper removed live code, not just comments")
  }
}
