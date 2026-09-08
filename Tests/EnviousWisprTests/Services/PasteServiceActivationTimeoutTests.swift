import ApplicationServices
import Foundation
import Testing

@testable import EnviousWisprServices

/// #2705: `PasteService.forceActivateApp` used to call
/// `AXUIElementSetAttributeValue(axApp, "AXFrontmost", ...)` with no messaging
/// timeout at all. Against a target that stops responding — frozen, wedged,
/// not merely gone — that call could block the calling actor for as long as
/// the target stays unresponsive (#2633).
///
/// A dead PID does not reproduce this: a process that no longer exists fails
/// FAST, because there is nothing to wait on. The real hazard needs a target
/// that is genuinely alive but not servicing its run loop, which is what
/// `FrozenAppHelper.swift` is for — a real, minimal `NSApplication` the test
/// launches, confirms is a real AX target, then freezes at the OS level with
/// `SIGSTOP` (founder direction 2026-09-07: build the real fixture, not a
/// lighter proxy, since this only needs to run locally).
///
/// Measured manually against this exact fixture before writing this suite
/// (2026-09-07): an unbounded `AXUIElementSetAttributeValue` against a
/// SIGSTOP'd target returned after 1.509s (macOS's own undocumented default),
/// not instantly and not indefinitely. With `AXUIElementSetMessagingTimeout`
/// set to 0.5s first, the same call against the same frozen process returned
/// in 0.511s. Both returned `.cannotComplete` — the call genuinely failed
/// both times, at different speeds, not a silent success. This suite asserts
/// the fast side stays fast, so a regression that removes the timeout call
/// shows up as this test taking over a second instead of a changed assertion.
///
/// Not run in CI: no Accessibility session on a hosted runner, and freezing a
/// real process is exactly the kind of test that must never share a runner
/// with anything else. Gated on both `AXIsProcessTrusted()` and `CI` being
/// unset, matching the convention in `RenderedPillFreezeTests.swift`.
///
/// On a dev machine this still SKIPS until Accessibility trust is granted to
/// the unit-test host, not to Xcode or the app — confirmed by a one-time
/// diagnostic print of the actual running process, 2026-09-07: the binary is
/// `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/xctest`.
/// Grant it via System Settings > Privacy & Security > Accessibility > "+",
/// browsing to that exact path (Cmd+Shift+G in the file picker to paste it).
@Suite(
  "PasteService activation timeout against a genuinely frozen target (#2705)",
  .tags(.productOutcome, .realBoundary))
struct PasteServiceActivationTimeoutTests {

  /// `xcodebuild test` forwards `TEST_RUNNER_CI` and Xcode's test runner
  /// strips the prefix, so the value reaching this process is `CI` — same
  /// mechanism, same reasoning as `RenderedPillFreezeTests.isDeveloperMachine`.
  static var runsOnThisMachine: Bool {
    AXIsProcessTrusted() && (ProcessInfo.processInfo.environment["CI"] ?? "").isEmpty
  }

  private static var fixtureURL: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // Services
      .deletingLastPathComponent()  // EnviousWisprTests
      .deletingLastPathComponent()  // Tests
      .appendingPathComponent("Fixtures/frozen-app/FrozenAppHelper.swift")
  }

  /// Launch the real fixture app, wait for it to become a genuine AX target,
  /// then freeze it at the OS level. Returns once frozen; the caller owns
  /// killing `process` when done.
  private static func launchAndFreezeFixture() throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["swift", fixtureURL.path]
    try process.run()

    // The interpreter needs a moment to parse, launch NSApplication, and
    // register with the Accessibility subsystem before it is a real target.
    // The loop exits on the real signal (the AX call itself succeeding); the
    // sleep is only the poll interval, bounded by the attempt cap below.
    //
    // Codex review found the gap this closes: without tracking whether the
    // loop actually succeeded, an exhausted, never-registered fixture would
    // still get frozen and the test would still pass — a never-registered
    // target ALSO fails fast, with no help from the fix under test. That
    // makes the pass meaningless rather than wrong, and indistinguishable
    // from a real pass without this check.
    var registered = false
    var attempts = 0
    while attempts < 20 {
      Thread.sleep(forTimeInterval: 0.1)  // deadline-fallback: poll interval; loop exits on the AX success check above it
      attempts += 1
      let axApp = AXUIElementCreateApplication(process.processIdentifier)
      if AXUIElementSetAttributeValue(axApp, "AXFrontmost" as CFString, true as CFTypeRef)
        == .success
      {
        registered = true
        break
      }
    }
    guard registered else {
      process.terminate()
      throw TestFixtureError.neverRegistered
    }

    guard kill(process.processIdentifier, SIGSTOP) == 0 else {
      process.terminate()
      throw TestFixtureError.couldNotFreeze
    }
    return process
  }

  private static func killFixture(_ process: Process) {
    // CONT before KILL: a stopped process is not guaranteed to process a
    // signal cleanly, and this is cheap insurance against a leaked frozen
    // process outliving the test run.
    kill(process.processIdentifier, SIGCONT)
    kill(process.processIdentifier, SIGKILL)
    process.waitUntilExit()
  }

  private enum TestFixtureError: Error {
    case couldNotFreeze
    case neverRegistered
  }

  @Test(
    "forceActivateApp bounds against a real frozen target instead of taking the OS default",
    .enabled(if: runsOnThisMachine))
  func forceActivateAppBoundsAgainstAFrozenTarget() throws {
    let process = try Self.launchAndFreezeFixture()
    defer { Self.killFixture(process) }

    let started = Date()
    let activated = PasteService.forceActivateApp(pid: process.processIdentifier)
    let elapsed = Date().timeIntervalSince(started)

    // The call must fail — the target is frozen and cannot actually come to
    // the front — but it must fail FAST. 1.0s is the assertion line: well
    // above the configured 0.5s bound (so ordinary scheduling jitter cannot
    // flake this), well below the 1.509s measured default this fix replaces.
    #expect(!activated, "a frozen target cannot actually activate")
    #expect(
      elapsed < 1.0,
      "forceActivateApp took \(elapsed)s against a frozen target — expected under 1.0s; the pre-#2705 code measured 1.509s here"
    )
  }
}
