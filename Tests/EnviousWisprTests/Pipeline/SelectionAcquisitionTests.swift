import AppKit
import Foundation
import Testing

@testable import EnviousWisprPipeline
@testable import EnviousWisprServices

/// #2465 — the decisions that bound a synthetic Copy.
///
/// **What is here and what is not.** Every guard that decides WHETHER to post is pure and lives
/// here. The posting itself talks to the window server and is proven by Live UAT, the same split
/// `SelectionReader` and `PasteService` already keep — a fabricated event source would test our idea
/// of the window server rather than the window server.
///
/// Product Outcome: when these fail, a keystroke is posted at the wrong process, into a password
/// field, into somebody else's remote session, or with the user's own modifiers still held.
@MainActor
@Suite("Quick Add selection acquisition — #2465", .tags(.productOutcome))
struct SelectionAcquisitionTests {

  private func context(
    pid: pid_t? = 501,
    bundleIdentifier: String? = "com.apple.TextEdit",
    focusedSubrole: String? = nil
  ) -> SelectionReader.AcquisitionContext {
    .init(pid: pid, bundleIdentifier: bundleIdentifier, focusedSubrole: focusedSubrole)
  }

  /// Every predicate satisfied. Without this row every assertion below passes against a guard that
  /// refuses unconditionally.
  @Test("With every condition met, the fallback goes ahead")
  func theOrdinaryCaseProceeds() {
    #expect(
      SelectionAcquisition.mayAttempt(
        secureInputActive: false, focusedElementIsSecure: false, postingAuthorised: true, targetStillPresent: true,
        fallbackEnabled: true, context: context()) == nil)
  }

  // MARK: The five refusals, one row each

  @Test("A context with no usable process refuses rather than posting", arguments: [nil, 0, -1])
  func noUsableProcessRefuses(pid: Int?) {
    #expect(
      SelectionAcquisition.mayAttempt(
        secureInputActive: false, focusedElementIsSecure: false, postingAuthorised: true, targetStillPresent: true,
        fallbackEnabled: true, context: context(pid: pid.map(pid_t.init)))
        == .noFrontmostApplication)
  }

  @Test("A target that has gone refuses, because a recycled pid belongs to a stranger")
  func aVanishedTargetRefuses() {
    #expect(
      SelectionAcquisition.mayAttempt(
        secureInputActive: false, focusedElementIsSecure: false, postingAuthorised: true, targetStillPresent: false,
        fallbackEnabled: true, context: context()) == .targetApplicationGone)
  }

  @Test("Secure input refuses, whichever of the two signals says so")
  func secureInputRefuses() {
    // Process-wide secure input mode: the real protection, and what an app enables when it means it.
    #expect(
      SelectionAcquisition.mayAttempt(
        secureInputActive: true, focusedElementIsSecure: false, postingAuthorised: true, targetStillPresent: true,
        fallbackEnabled: true, context: context()) == .secureInputActive)

    // A secure text field in an app that never enabled the mode. The second guard, and the reason
    // it is worth having is that the cost of being wrong is a password on the clipboard.
    #expect(
      SelectionAcquisition.mayAttempt(
        secureInputActive: false, focusedElementIsSecure: true, postingAuthorised: true,
        targetStillPresent: true, fallbackEnabled: true, context: context()) == .secureInputActive)
  }

  /// **The secure-field answer is a PARAMETER and no longer read off the context, and this row is
  /// the reason.** It used to be derived from `context.focusedSubrole`, which made the guard look
  /// live at both of its call sites while that field was sampled BEFORE a quarter-second wait for
  /// the user's modifiers. Focus moving into a password field during that wait left the one guard
  /// whose failure mode is a secret on the clipboard answering from memory.
  ///
  /// So the context can no longer influence this decision, and asserting that is what stops the
  /// derivation being quietly reintroduced: a secure-looking context with a `false` parameter must
  /// PROCEED, and an ordinary context with `true` must REFUSE.
  @Test("The context cannot override the secure-field answer in either direction")
  func theContextDoesNotDecideSecurity() {
    #expect(
      SelectionAcquisition.mayAttempt(
        secureInputActive: false, focusedElementIsSecure: false, postingAuthorised: true,
        targetStillPresent: true, fallbackEnabled: true,
        context: context(focusedSubrole: kAXSecureTextFieldSubrole as String)) == nil,
      "the stale context field decided this, which is the defect")

    #expect(
      SelectionAcquisition.mayAttempt(
        secureInputActive: false, focusedElementIsSecure: true, postingAuthorised: true,
        targetStillPresent: true, fallbackEnabled: true,
        context: context(focusedSubrole: "AXTextField")) == .secureInputActive,
      "the live probe decides, whatever the sample said")
  }

  /// **`unreadable` answers TRUE, which is the whole point of a three-valued probe.** A caller
  /// asking "may I synthesize a keystroke into this" gets "treat it as secure" when nobody can tell
  /// it otherwise. Without this the fail-closed read would be undone one function later.
  @Test("A subrole nobody could read counts as secure")
  func anUnreadableSubroleCountsAsSecure() {
    #expect(SelectionReader.isSecureField(.unreadable))
    #expect(SelectionReader.isSecureField(.subrole(kAXSecureTextFieldSubrole as String)))
    // The pair, or the predicate says yes to everything.
    #expect(!SelectionReader.isSecureField(.subrole("AXTextField")))
    #expect(!SelectionReader.isSecureField(.subrole(nil)))
  }

  @Test("Unauthorised event posting gets its OWN refusal, never the Accessibility one")
  func unauthorisedPostingRefusesDistinctly() {
    let refusal = SelectionAcquisition.mayAttempt(
      secureInputActive: false, focusedElementIsSecure: false, postingAuthorised: false, targetStillPresent: true,
      fallbackEnabled: true, context: context())

    #expect(refusal == .eventPostingNotTrusted)
    // The distinction is the point: we hold the Accessibility grant already, or this ladder would
    // never have run. Telling the user to turn on a permission that is already on sends them to
    // look at a switch that is not the problem.
    #expect(refusal != .accessibilityNotTrusted)
  }

  @Test("The setting and the keystroke-forwarding list share one refusal, because both mean off")
  func theOffStatesShareOneRefusal() {
    #expect(
      SelectionAcquisition.mayAttempt(
        secureInputActive: false, focusedElementIsSecure: false, postingAuthorised: true, targetStillPresent: true,
        fallbackEnabled: false, context: context()) == .copyFallbackDisabled)

    #expect(
      SelectionAcquisition.mayAttempt(
        secureInputActive: false, focusedElementIsSecure: false, postingAuthorised: true, targetStillPresent: true,
        fallbackEnabled: true, context: context(bundleIdentifier: "com.apple.ScreenSharing"))
        == .copyFallbackDisabled)
  }

  // MARK: Precedence, which is declared rather than emergent

  /// **More than one predicate can hold at once and the refusal carries ONE value**, so the order is
  /// part of the contract rather than an accident of how the guards were typed. Each row holds
  /// everything from its own rank downward and asserts that its own answer wins.
  @Test("Every earlier refusal outranks every later one")
  func precedenceIsDeclared() {
    // Everything wrong at once. The answer is the most fundamental: there is no subject at all.
    #expect(
      SelectionAcquisition.mayAttempt(
        secureInputActive: true, focusedElementIsSecure: false, postingAuthorised: false, targetStillPresent: false,
        fallbackEnabled: false,
        context: context(pid: nil, bundleIdentifier: "com.apple.ScreenSharing"))
        == .noFrontmostApplication)

    // A process that no longer exists has nothing to protect and nothing to ask.
    #expect(
      SelectionAcquisition.mayAttempt(
        secureInputActive: true, focusedElementIsSecure: false, postingAuthorised: false, targetStillPresent: false,
        fallbackEnabled: false, context: context(bundleIdentifier: "com.apple.ScreenSharing"))
        == .targetApplicationGone)

    // Secure input outranks both remaining ones: it is the state where posting anything is wrong.
    #expect(
      SelectionAcquisition.mayAttempt(
        secureInputActive: true, focusedElementIsSecure: false, postingAuthorised: false, targetStillPresent: true,
        fallbackEnabled: false, context: context(bundleIdentifier: "com.apple.ScreenSharing"))
        == .secureInputActive)

    // And the capability outranks the preference: "we cannot" before "we chose not to".
    #expect(
      SelectionAcquisition.mayAttempt(
        secureInputActive: false, focusedElementIsSecure: false, postingAuthorised: false, targetStillPresent: true,
        fallbackEnabled: false, context: context(bundleIdentifier: "com.apple.ScreenSharing"))
        == .eventPostingNotTrusted)
  }

  /// **The ladder asks these questions TWICE, and this row is why the second call has to exist.**
  ///
  /// Step 1 asks before waiting for the user's shortcut modifiers to come up, which is capped at a
  /// quarter of a second. Secure input is a mode the user enters by clicking into a password field,
  /// and the target can quit — both of them inside that wait. A guard whose answer is correct when
  /// it runs and stale when it matters is not a guard, so the same questions are re-asked with LIVE
  /// inputs immediately before the takeover.
  ///
  /// The pure function cannot see the second call site, so this row asserts the property that makes
  /// the second call meaningful: `mayAttempt` is a function of its ARGUMENTS ONLY, with no cached or
  /// memoised state, so calling it again with changed inputs genuinely changes the answer.
  @Test("The guard answers from its arguments, so asking again with new inputs answers differently")
  func theGuardIsPureSoReAskingIsMeaningful() {
    let sameContext = context()

    #expect(
      SelectionAcquisition.mayAttempt(
        secureInputActive: false, focusedElementIsSecure: false, postingAuthorised: true, targetStillPresent: true,
        fallbackEnabled: true, context: sameContext) == nil)

    // The user clicked into a password field while we waited for their fingers to come up.
    #expect(
      SelectionAcquisition.mayAttempt(
        secureInputActive: true, focusedElementIsSecure: false, postingAuthorised: true, targetStillPresent: true,
        fallbackEnabled: true, context: sameContext) == .secureInputActive)

    // The target quit while we waited.
    #expect(
      SelectionAcquisition.mayAttempt(
        secureInputActive: false, focusedElementIsSecure: false, postingAuthorised: true, targetStillPresent: false,
        fallbackEnabled: true, context: sameContext) == .targetApplicationGone)

    // And back, so the row is not passing on a guard that latches after its first refusal.
    #expect(
      SelectionAcquisition.mayAttempt(
        secureInputActive: false, focusedElementIsSecure: false, postingAuthorised: true, targetStillPresent: true,
        fallbackEnabled: true, context: sameContext) == nil)
  }

  // MARK: The keystroke-forwarding list

  @Test("Only an exact bundle identifier is treated as keystroke forwarding")
  func theForwardingListMatchesExactly() {
    #expect(SelectionAcquisition.isKeystrokeForwarding("com.apple.ScreenSharing"))
    // Paired rejections, or a predicate that says yes to everything looks identical to this one.
    #expect(!SelectionAcquisition.isKeystrokeForwarding(nil))
    #expect(!SelectionAcquisition.isKeystrokeForwarding(""))
    #expect(!SelectionAcquisition.isKeystrokeForwarding("com.apple.TextEdit"))
    // Near misses a prefix or contains check would swallow.
    #expect(!SelectionAcquisition.isKeystrokeForwarding("com.apple.ScreenSharing.agent"))
    #expect(!SelectionAcquisition.isKeystrokeForwarding("com.apple"))
  }

  /// **The list is OPEN-WORLD and this row says so out loud**, because a set nobody can enumerate is
  /// the shape that quietly becomes a claim. There is no authority listing every remote-desktop or
  /// virtual-machine client, so the next one to ship will not be here — which is exactly why the
  /// global setting exists and why no copy anywhere promises this list is complete.
  @Test("The list is a sample with a stated escape, not a claim to be exhaustive")
  func theForwardingListIsExplicitlyIncomplete() {
    #expect(SelectionAcquisition.keystrokeForwardingBundleIdentifiers.count > 5)
    #expect(
      !SelectionAcquisition.isKeystrokeForwarding("com.some.remote.client.shipping.next.year"),
      "and the escape for that one is the setting, which is why `fallbackEnabled` is a parameter")
  }

  // MARK: Which read outcomes the fallback may act on

  /// The three shapes an app takes when it HAS a selection on screen and publishes nothing usable:
  /// the measured WhatsApp case answers success with an empty string, and a terminal answers
  /// `noValue`.
  @Test(
    "Exactly three outcomes are fallback-eligible",
    arguments: [
      SelectionReader.Result.noSelection,
      .refused(.selectionUnsupported),
      .refused(.selectionUnavailable),
    ])
  func theThreeEligibleOutcomes(result: SelectionReader.Result) {
    #expect(SelectionReader.isFallbackEligible(result))
  }

  /// **Enumerated from the enum rather than listed by hand**, so a member added later joins this
  /// assertion by existing. A hand-written list of the terminal ones is a description of the set,
  /// and the next member added is the one it will not contain.
  @Test("Every other outcome is terminal, because asking twice cannot help")
  func everythingElseIsTerminal() {
    let eligible: Set<SelectionReader.Refusal> = [.selectionUnsupported, .selectionUnavailable]
    for refusal in SelectionReader.Refusal.allCases where !eligible.contains(refusal) {
      #expect(
        !SelectionReader.isFallbackEligible(.refused(refusal)),
        "\(refusal.rawValue) must not re-enter the ladder")
    }
    #expect(!SelectionReader.isFallbackEligible(.text("codecs")))
  }

  // MARK: Structural properties, which no run can observe

  /// **The one property with no runtime assertion available, so it is asserted structurally.**
  /// `SelectionReader.Frontmost` exists because taking the pid in one place and the identity one
  /// call later described two different applications, found by cloud review on PR #2428. A ladder
  /// that re-asks the workspace for a pid recreates that defect one layer up and posts a keystroke
  /// at whatever came forward in between.
  ///
  /// A behavioural test cannot see this: both the correct and the incorrect version answer
  /// identically whenever nothing switched during the run, which is every run on a test machine.
  /// So the check is on the SOURCE, and it fails the moment somebody adds the call.
  @Test("The acquisition ladder never samples the frontmost application")
  func theLadderNeverResamplesTheWorkspace() throws {
    let code = try Self.executableLines(of: "SelectionAcquisition.swift")

    // **Positive control first, or an empty match set is indistinguishable from a broken reader.**
    // If the comment stripping or the file path is wrong, `code` is empty and every absence check
    // below passes while looking at nothing.
    #expect(
      code.contains(where: { $0.contains("SelectionReader.readForAcquisition") }),
      "the source reader could not see a call it is known to contain")

    #expect(
      !code.contains(where: { $0.contains("NSWorkspace.shared.frontmostApplication") }),
      "a second sample: the pid must come from the read's own sample")
  }

  /// The subject's source, minus comment lines, so prose ABOUT a call is not read as the call.
  private static func executableLines(of file: String) throws -> [Substring] {
    let source = try String(
      contentsOf: sourceRoot.appendingPathComponent(file), encoding: .utf8)
    return source.split(separator: "\n").filter {
      let line = $0.trimmingCharacters(in: .whitespaces)
      return !line.hasPrefix("//")
    }
  }


  /// This file is `Tests/EnviousWisprTests/Pipeline/`; the subject is `Sources/EnviousWisprPipeline/`.
  ///
  /// Derived from `#filePath` rather than from the working directory, because a path relative to
  /// wherever the runner happened to be started is the cwd trap that yields a false FAILURE on
  /// correct code.
  private static var sourceRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // Pipeline
      .deletingLastPathComponent()  // EnviousWisprTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // repo root
      .appendingPathComponent("Sources/EnviousWisprPipeline")
  }

  /// The restore obligation, asserted the only way it can be: by counting the sites.
  ///
  /// **Once the takeover is granted, every exit must restore.** A behavioural test would need to
  /// inject a failure after the takeover, which means a seam in the guard itself — and a seam on a
  /// guard is an unlogged bypass anyone can reach. So the property is carried by structure: after
  /// the takeover there is exactly one function that restores, and every exit returns through it.
  @Test("Restoration has exactly one site in the ladder")
  func restorationHasOneSite() throws {
    let code = try Self.executableLines(of: "SelectionAcquisition.swift")
    let calls = code.filter { $0.contains("PasteService.restoreClipboard") }
    #expect(
      calls.count == 1,
      "a second restore site is a second chance to skip one; every exit goes through `concluding`")
  }
}
