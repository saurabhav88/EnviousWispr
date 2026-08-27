import EnviousWisprServices
import Foundation
import Testing

/// #2455 C0 (#2457) — the environment tripwire, now reduced to its own contract.
///
/// **What is left here after C2, and what it does NOT cover.** C2 (#2459) moved
/// every Carbon and `NSEvent` call into `EnviousWisprDesktopEffects` and deleted
/// C0's denial machinery from `HotkeyService`. So these variables now guard
/// nothing: no production path reads either one.
///
/// They never guarded overlay or activation either — C0's tripwire only ever
/// existed in `HotkeyService`. Those families are C3 (#2460) and C4 (#2461), and
/// they are still live in this target with nothing in front of them.
///
/// Two cases here assert the switch's own PARSING contract; two assert that the
/// residual scheme WIRING is still in place. No production path consumes either
/// variable after C2 — the second pair exists so the wiring stays visible until
/// C5 (#2462) removes the variables and these cases together. The enforcement that
/// replaced them is `scripts/check-dependency-direction.sh`.
///
/// Registration-attempt coverage moved to the fake: `RecordingDesktopHotkeyEffects`
/// captures every request, so "cancel took the chord and Quick Add yielded" is
/// assertable there rather than inferred from a refusal here.
@MainActor
@Suite(.tags(.harnessContract)) struct DesktopEffectPolicyTests {

  // MARK: - The switch itself

  /// Only the exact opt-in string denies. A malformed variable must leave a real
  /// user's hotkeys working rather than silently killing them.
  @Test(
    "only the exact string denies",
    arguments: [
      ("deny", DesktopEffectPolicy.deny),
      ("DENY", .allow),
      ("deny ", .allow),
      ("1", .allow),
      ("allow", .allow),
      ("", .allow),
    ])
  func onlyExactStringDenies(value: String, expected: DesktopEffectPolicy) {
    let policy = DesktopEffectPolicy.fromEnvironment([
      DesktopEffectPolicy.environmentKey: value
    ])
    #expect(policy == expected)
  }

  @Test("an absent variable allows, so production is unchanged by construction")
  func absentVariableAllows() {
    #expect(DesktopEffectPolicy.fromEnvironment([:]) == .allow)
  }

  /// No production path consumes this variable after C2. This assertion keeps the
  /// disclosed C0 wiring VISIBLE until C5 (#2462) removes it — so the removal is
  /// one deliberate change that also deletes this case, rather than a variable
  /// quietly outliving its purpose in three schemes.
  @Test("the residual C0 policy variable remains wired until C5")
  func thisRunIsDenied() {
    #expect(
      DesktopEffectPolicy.fromEnvironment() == .deny,
      """
      \(DesktopEffectPolicy.environmentKey) is no longer set for this run. Nothing \
      consumes it after C2, so this is not a safety failure — it means the C0 debt \
      was removed without removing this case. Delete both together (C5, #2462).
      """)
  }

  /// Same, for the severity half. No production path consumes this variable after
  /// C2 either; the assertion keeps the disclosed C0 wiring visible until C5
  /// (#2462) removes both together.
  @Test("the residual C0 trap variable remains wired until C5")
  func thisRunTrapsUnhandledRefusals() {
    #expect(
      ProcessInfo.processInfo.environment[DesktopEffectDenial.trapEnvironmentKey] == "1",
      """
      \(DesktopEffectDenial.trapEnvironmentKey) is no longer set for this run. Nothing \
      consumes it after C2, so this is not a safety failure — it means the C0 debt \
      was removed without removing this case. Delete both together (C5, #2462).
      """)
  }
}
