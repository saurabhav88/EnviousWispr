import EnviousWisprServices
import Foundation
import Testing

/// #2455 C0 (#2457) — the tripwire that stops the unit suite registering real
/// hotkeys.
///
/// Scope is Carbon hotkey registration, the Carbon event handler, and the `NSEvent`
/// modifier monitors. Overlay windows and app activation share the root cause and
/// are NOT covered here; they are C3 (#2460) and C4 (#2461).
///
/// The suite runs inside Apple's `xctest` agent with no `TEST_HOST`, and
/// `AppWindowCoordinatorTests.swift:26` promotes that agent to a live GUI app, so
/// WITHOUT this tripwire a `RegisterEventHotKey` call from a unit test takes the key
/// SYSTEM-WIDE for as long as the run lasts. Escape is the shipped cancel binding,
/// so the developer loses Escape in every other application while the tests run.
///
/// These cases assert the refusal itself. They are also the first coverage in
/// this repo of whether a registration was ATTEMPTED at all: `registerCancelHotkey`
/// sets `isCancelArmed` before it asks Carbon, so every existing test proves the
/// intent to arm and none proves the chord was taken. That gap is what shipped
/// #2381.
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

  /// The negative control for the refusal cases below. If the test action ever
  /// loses this variable those cases FAIL rather than pass — an empty ledger fails
  /// a `contains` — but they fail three at a time with no shared cause on their
  /// face, while the suite is once again stealing the developer's Escape key. This
  /// case names that cause in one line, so the environment is asserted rather than
  /// diagnosed. Its twin below covers severity, which CAN fail open.
  @Test("this test run is itself denied — the scheme carries the variable")
  func thisRunIsDenied() {
    #expect(
      DesktopEffectPolicy.fromEnvironment() == .deny,
      """
      \(DesktopEffectPolicy.environmentKey) is not set to "deny" for this run. \
      The test action in Project.swift owns it; regenerate the project.
      """)
  }

  /// The second half of the negative control. Denial and SEVERITY are separate
  /// switches, so the suite can be denied and still fail open: without this
  /// variable an unmigrated construction site logs and its test passes having
  /// reached a prohibited effect. That is the Release-lane hole Codex found on
  /// 2026-08-26, and it is why severity is not selected with `#if DEBUG`.
  @Test("this test run traps on an unhandled refusal, in every configuration")
  func thisRunTrapsUnhandledRefusals() {
    #expect(
      ProcessInfo.processInfo.environment[DesktopEffectDenial.trapEnvironmentKey] == "1",
      """
      \(DesktopEffectDenial.trapEnvironmentKey) is not set for this run, so a test that \
      reaches one of C0's guarded installation calls would pass instead of failing. The \
      Project.swift owns it; regenerate the project.
      """)
  }

  // MARK: - What the service does under denial

  /// New coverage, not a restatement: this is the first assertion in the repo
  /// that `start()` actually ASKS for the record chord. Nothing observable today
  /// distinguishes "registered the chord" from "set a flag and skipped it".
  @Test("start() asks for the record chord and the Carbon handler, and is refused")
  func startAsksForItsEffectsAndIsRefused() {
    let service = HotkeyService(onDeniedDesktopEffect: DesktopEffectDenial.recordOnly)
    service.toggleKeyCode = chordKeyCode

    service.start()

    #expect(service.deniedDesktopEffects.contains { $0.hasPrefix("InstallEventHandler") })
    #expect(
      service.deniedDesktopEffects.contains {
        $0.hasPrefix("RegisterEventHotKey(id: 1")
      },
      "the record chord must be requested; refused is fine, unasked is the bug")

    service.stop()
  }

  /// A chord takes the Carbon path and installs no monitors, so the case above
  /// cannot reach the `NSEvent` refusal at all. A bare-modifier record key is the
  /// shape that does — `shouldInstallModifierMonitors` is true only when some
  /// role is bound to a bare modifier.
  @Test("a bare-modifier record key asks for the flags-changed monitors, and is refused")
  func bareModifierRecordKeyAsksForMonitorsAndIsRefused() {
    let service = HotkeyService(onDeniedDesktopEffect: DesktopEffectDenial.recordOnly)
    service.toggleKeyCode = ModifierKeyCodes.rightOption

    service.start()

    #expect(service.shouldInstallModifierMonitors, "precondition: this shape needs monitors")
    #expect(
      service.deniedDesktopEffects.contains { $0.hasPrefix("NSEvent.addGlobalMonitor") })
    // A bare modifier cannot be a Carbon registration, so the record role must
    // NOT have asked for one — the #1991 shape, asserted from the refusal ledger.
    #expect(
      service.deniedDesktopEffects.contains { $0.hasPrefix("RegisterEventHotKey(id: 1") } == false)

    service.stop()
  }

  /// The teardown half. A refused registration still occupies its slot, so
  /// `stop()` must clear it — and must not hand the framework a token no
  /// framework ever issued. A forged `EventHotKeyRef` here would be a wild-pointer
  /// call, which is why the refusal is a typed case rather than a synthetic
  /// pointer.
  @Test("stop() releases refused registrations without calling the framework")
  func stopReleasesRefusedRegistrations() {
    let service = HotkeyService(onDeniedDesktopEffect: DesktopEffectDenial.recordOnly)
    service.toggleKeyCode = chordKeyCode
    service.start()
    service.registerCancelHotkey()

    service.stop()

    #expect(service.isEnabled == false)
    // Reaching here at all is the assertion: releasing a refused slot must not
    // reach `UnregisterEventHotKey` or `RemoveEventHandler`.
    #expect(service.deniedDesktopEffects.isEmpty == false)
  }

  /// `suspend()`/`resume()` re-registers, so it must be refused each time rather
  /// than slipping through on the second pass.
  @Test("a resumed service is refused again rather than registering")
  func resumeIsRefusedAgain() {
    let service = HotkeyService(onDeniedDesktopEffect: DesktopEffectDenial.recordOnly)
    service.toggleKeyCode = chordKeyCode
    service.start()
    let afterStart = service.deniedDesktopEffects.count

    service.suspend()
    service.resume()

    #expect(service.deniedDesktopEffects.count > afterStart)
    service.stop()
  }

  /// A policy refusal is not a Carbon failure. Emitting `registrationFailed` for
  /// it would report a policy refusal as a Carbon registration failure, corrupting
  /// the one signal that tells us a real user's shortcut died.
  @Test("a refusal emits no registration-failure telemetry")
  func refusalEmitsNoRegistrationFailure() {
    final class Spy: @unchecked Sendable {
      var failures: [(String, String)] = []
    }
    let spy = Spy()
    let sink = HotkeyTelemetrySink(
      registrationFailed: { mechanism, kind, _, _ in
        spy.failures.append((mechanism, kind))
      },
      pressed: { _, _, _, _, _ in })

    let service = HotkeyService(
      telemetry: sink, onDeniedDesktopEffect: DesktopEffectDenial.recordOnly)
    service.toggleKeyCode = chordKeyCode
    service.start()

    #expect(spy.failures.isEmpty)
    service.stop()
  }

  /// `kVK_ANSI_D` — a plain chord, so the record key takes the Carbon path rather
  /// than the modifier-monitor path.
  private let chordKeyCode: UInt16 = 2
}
