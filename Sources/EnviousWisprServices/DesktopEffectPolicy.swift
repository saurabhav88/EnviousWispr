import Foundation

/// Whether this process may reach the desktop effects C0 guards: Carbon hotkey
/// registration, the Carbon event handler, and the `NSEvent` modifier monitors.
///
/// **Scope is exactly those three.** Overlay windows, app activation and Quick Add
/// presentation are the same root cause and are NOT covered here — they are C3
/// (#2460) and C4 (#2461). A reader who takes this for a general desktop-effect
/// switch will conclude the suite is contained when it is not.
///
/// #2455 C0 (#2457). `EnviousWisprTests` has no `TEST_HOST`, so the suite runs
/// inside Apple's `xctest` agent; `AppWindowCoordinatorTests.swift:26` then runs
/// `_ = NSApplication.shared`, which promotes that agent to a live GUI app. Without
/// this policy a hotkey effect triggered by a unit test lands on the developer's
/// real machine: a registered Escape hotkey swallows Escape system-wide for as long
/// as the suite runs.
///
/// **Disclosed temporary debt.** This is a tripwire, not the wall. The wall is the
/// module boundary C1-C4 build, after which no unit-test target can link a live
/// effect at all. C5 (#2462) removes or demotes this policy once that boundary
/// exists, because a denial branch selected by an environment variable is present
/// in a shipped binary and can therefore be reached by a shipped run.
///
/// **Project-owned on purpose.** Not `XCTestConfigurationFilePath` or any other
/// undocumented Apple variable: those are an implementation detail Apple may
/// change, and sniffing them makes the contract invisible at the call site.
/// `EW_`-prefixed run switches are already this project's convention
/// (`EW_FAULT_INJECTION`, `EW_FORCE_READINESS_LOST`).
package enum DesktopEffectPolicy: Sendable {
  /// The guarded effects are performed. The value for any process, a shipped app
  /// included, that does not set the variable.
  case allow
  /// Explicit refusal. The test actions set it, and a shipped process can also
  /// enter it if someone sets the variable by hand — which is why a refusal is
  /// never described as proof that a test caused it.
  case deny

  package static let environmentKey = "EW_DESKTOP_EFFECTS_POLICY"

  /// Deny requires the exact opt-in string. Anything else — absent, empty,
  /// misspelt — is `allow`, so a malformed variable can never quietly disable
  /// hotkeys for a user.
  package static func fromEnvironment(
    _ environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> DesktopEffectPolicy {
    environment[environmentKey] == "deny" ? .deny : .allow
  }
}

/// Called with a human-readable name for each denied effect.
///
/// A denial is data, not a decision: the handler decides how loud it is. The test
/// target injects a recorder so a suite that legitimately drives registration can
/// ASSERT what was refused — which is coverage that does not exist today, because
/// `registerCancelHotkey()` sets `isCancelArmed` before it asks Carbon, so no
/// current test can prove the chord was actually taken.
package typealias DesktopEffectDenialHandler = @MainActor (String) -> Void

package enum DesktopEffectDenial {
  /// Whether a denial that reaches the DEFAULT handler aborts the run.
  ///
  /// Separate from the policy key because the two answer different questions —
  /// `EW_DESKTOP_EFFECTS_POLICY` decides WHETHER an effect happens, this decides
  /// how loud an unhandled refusal is — and because they must be able to
  /// disagree. A user who somehow launches the shipped app with the policy
  /// variable set must lose their hotkeys, never their app. THIS PROJECT sets the
  /// trap variable only on test actions, which is what makes normal test runs the
  /// trapping case — but the value is what decides, so a process that sets both by
  /// hand traps too. Test-action ownership identifies the normal path, not the
  /// mechanism.
  ///
  /// Codex chunk review, 2026-08-26: an earlier revision selected severity with
  /// `#if DEBUG` instead. That made an unmigrated site ABORT in the Debug lane
  /// and PASS in the Release lane, so the Release suite could go green having
  /// reached a prohibited effect — the precise outcome this chunk exists to
  /// prevent, and a Debug/Release test-outcome divergence of the class
  /// `Project.swift` already records as costing a red main (#2070/#2083).
  /// Severity is now a runtime fact in every configuration.
  package static let trapEnvironmentKey = "EW_DESKTOP_EFFECTS_TRAP_DENIALS"

  /// The default when nothing was injected.
  ///
  /// Under a test action, an unhandled denial must fail rather than pass having
  /// verified nothing — both council models (2026-08-26) rejected a silent skip for
  /// that reason. Without the trap variable, the shipped-process fallback logs and
  /// continues, so an unhandled denial is not by itself proof of a test defect.
  @MainActor
  package static func defaultHandler(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> DesktopEffectDenialHandler {
    environment[trapEnvironmentKey] == "1" ? trap : logOnly
  }

  /// Aborts, naming the refused operation so the failure points at the call.
  @MainActor
  package static let trap: DesktopEffectDenialHandler = { reason in
    fatalError(message(reason))
  }

  /// Denies and leaves a trail, without taking the process down. What the default
  /// handler does whenever the policy variable is set and the trap variable is not
  /// `1` — in a shipped app, and in any other process in that state.
  @MainActor
  package static let logOnly: DesktopEffectDenialHandler = { reason in
    NSLog("%@", message(reason))
  }

  private static func message(_ reason: String) -> String {
    """
    \(DesktopEffectPolicy.environmentKey)=deny refused a guarded desktop effect: \(reason). \
    If this is a test run, it reached a live hotkey effect: inject \
    DesktopEffectDenial.recordOnly at the HotkeyService construction site and assert \
    on what it recorded (#2455 C0).
    """
  }
}

extension DesktopEffectDenial {
  /// Records the denial on the service and does nothing else.
  ///
  /// For a suite that DELIBERATELY drives registration and then asserts on
  /// `HotkeyService.deniedDesktopEffects`. It is not a way to quiet an
  /// unexamined test: the denial is still recorded, the call site still names
  /// the policy, and a test that installs this without asserting on the ledger
  /// is visible in review as a test that asked for a refusal and ignored it.
  @MainActor
  package static let recordOnly: DesktopEffectDenialHandler = { _ in }
}
