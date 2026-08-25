import Foundation
import Testing

@testable import EnviousWisprAppKit

/// The pill-appearance home is injected wherever Settings is (#2376 Phase 4, C7).
///
/// **A type-based `@Environment` read has NO DEFAULT, so a window root that hosts
/// the Appearance page without injecting this home TRAPS AT RUNTIME with every
/// test green.** That is a measured failure mode in this repo, not a theory: a
/// missing injection has previously shipped with 6,635 tests passing and a crash
/// on a screen every new user reaches.
///
/// So the guard is a MECHANISM rather than a reminder. It reads the composition
/// root as SOURCE and requires that every builder block injecting `settings` also
/// injects `pillAppearance` — because the two are needed by the same page, and a
/// root that has one and not the other is exactly the half-an-edit this catches.
///
/// **A Drift Guard.** It fails when we change our own composition, which is the
/// point; it is not evidence about anything a user sees.
@Suite(.tags(.driftGuard))
struct EnvironmentInjectionFreezeTests {

  private static let bootstrapperPath = "Sources/EnviousWisprAppKit/App/WisprBootstrapper.swift"

  @Test("the window root that hosts Settings injects the pill-appearance home")
  func pillAppearanceIsInjectedWhereSettingsIsHosted() throws {
    let url = RepoRoot.url.appending(path: Self.bootstrapperPath)
    let source = try String(contentsOf: url, encoding: .utf8)

    // Fails CLOSED on an unreadable or empty read: a zero-length source would
    // otherwise satisfy every search below and read as a clean pass.
    try #require(
      source.count > 1000,
      "\(Self.bootstrapperPath) read \(source.count) bytes — this guard is pointed at nothing")

    // **Scoped to the root that HOSTS the page, not to every root that injects
    // `settings`.** The broader rule was written first and is wrong: the
    // onboarding root injects `settings` and hosts `OnboardingV2View`, which has
    // no Appearance page, so requiring the pill home there would demand an
    // injection nothing reads. A guard that fires on correct code is the
    // false-positive shape this repo's own precision tally argues against, and it
    // trains the next person to widen the guard rather than fix the wiring.
    let host = "UnifiedWindowView()"
    let start = try #require(
      source.range(of: host), "positive control failed — \(host) is not in the composition root")

    // The builder block ends at the next type declaration.
    let rest = source[start.upperBound...]
    let blockEnd = rest.range(of: "\nprivate struct ") ?? rest.range(of: "\nstruct ")
    let block = blockEnd.map { String(rest[..<$0.lowerBound]) } ?? String(rest)

    try #require(
      block.contains(".environment(b.settings)"),
      "positive control failed — the Settings host block does not inject settings")

    #expect(
      block.contains(".environment(b.pillAppearance)"),
      """
      the window root hosting Settings injects `settings` but not `pillAppearance`. \
      The Appearance page reads the pill home through a type-based @Environment, \
      which has NO DEFAULT — so this traps at runtime on a screen a user reaches \
      from the menu bar, with every unit test still green. That exact failure has \
      shipped from this file before (#2196, caught as a P1 in cloud review).
      """)
  }

  /// The home must actually be constructed from the live-preview bridge rather
  /// than from a second derivation of capability. Checked as source because the
  /// wiring itself is what is being claimed, and the closure it captures is not
  /// observable from outside.
  @Test("the pill-appearance home reads the same capability the director does")
  func pillAppearanceReadsTheBridge() throws {
    let url = RepoRoot.url.appending(path: Self.bootstrapperPath)
    let source = try String(contentsOf: url, encoding: .utf8)
    #expect(
      source.contains("PillAppearanceModel(") && source.contains("bridge.wordsCapability"),
      """
      the pill-appearance home is not built from the live-preview bridge's own \
      capability. Re-deriving it — from the engine resolver, say — puts two answers \
      to one question in front of the same user on two settings pages.
      """)
  }
}
