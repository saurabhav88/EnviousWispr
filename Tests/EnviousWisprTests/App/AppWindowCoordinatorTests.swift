import AppKit
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// PR-B.2 of #763 — unit tests for `AppWindowCoordinator`.
///
/// These tests exercise the coordinator's internal logic with spy closures:
/// the pending-open queue/replay path, the eligibility guard ordering, and
/// the onboarding-dismiss icon-refresh seam. They do NOT instantiate a real
/// `NSWindow` scene graph — the SwiftUI `.environment()` injection and the
/// real activation-policy / window-server behavior are proven at Live UAT
/// (plan §3a layer 4), not here.
@MainActor
@Suite("AppWindowCoordinator")
struct AppWindowCoordinatorTests {

  /// `showWindow()` / `openOnboardingWindow()` / `closeOnboardingWindow()`
  /// touch the `NSApp` global (`setActivationPolicy`, `activate`). `NSApp` is
  /// an implicitly-unwrapped optional that is nil until `NSApplication.shared`
  /// is first accessed — which never happens in a bare test process. Accessing
  /// it here populates the global so the coordinator's verbatim-from-AppDelegate
  /// `NSApp` calls do not crash. Production code is unaffected: the real app
  /// always has a live `NSApp`.
  init() {
    _ = NSApplication.shared
  }

  /// An out-of-order `openOnboardingWindow()` call (before `openOnboardingAction`
  /// is wired) queues the request; `consumePendingOpenOnboarding()` replays it
  /// exactly once and clears the flag.
  @Test("pending open queues then replays once")
  func pendingOpenOnboardingQueuesAndReplays() {
    var openCount = 0
    let coordinator = AppWindowCoordinator(
      canOpenOnboarding: { true },
      isOnboardingComplete: { false }
    )

    // No openOnboardingAction wired yet → the call must queue, not open.
    coordinator.openOnboardingWindow()
    #expect(openCount == 0, "no action wired → open is queued, not fired")

    // Wire the spy, then drain.
    coordinator.openOnboardingAction = { openCount += 1 }
    let replayed = coordinator.consumePendingOpenOnboarding()
    #expect(replayed, "consume must replay the queued open")
    #expect(openCount == 1, "replay fires the open exactly once")

    // Flag cleared after the first drain → a second consume is a no-op.
    let secondReplay = coordinator.consumePendingOpenOnboarding()
    #expect(!secondReplay, "flag cleared after first drain")
    #expect(openCount == 1, "no double-fire on a second consume")
  }

  /// `consumePendingOpenOnboarding()` with the flag clear returns `false` and
  /// does not fire an open.
  @Test("consume no-ops when nothing queued")
  func consumePendingOpenOnboardingNoOpsWhenFlagClear() {
    var openCount = 0
    let coordinator = AppWindowCoordinator(
      canOpenOnboarding: { true },
      isOnboardingComplete: { false }
    )
    coordinator.openOnboardingAction = { openCount += 1 }

    let replayed = coordinator.consumePendingOpenOnboarding()
    #expect(!replayed, "nothing queued → returns false")
    #expect(openCount == 0, "no open fired")
  }

  /// Council Risk 1 guard: a call made while onboarding is already complete
  /// must NOT queue a stale open — the eligibility guard runs before the queue
  /// guard.
  @Test("completed onboarding never queues a stale open")
  func completedOnboardingDoesNotQueue() {
    var openCount = 0
    let coordinator = AppWindowCoordinator(
      canOpenOnboarding: { false },  // onboarding complete → ineligible
      isOnboardingComplete: { true }
    )

    // No action wired. If the queue guard ran first this would queue.
    coordinator.openOnboardingWindow()

    // Wire a spy and drain — a wrongly-queued request would replay here.
    coordinator.openOnboardingAction = { openCount += 1 }
    let replayed = coordinator.consumePendingOpenOnboarding()
    #expect(!replayed, "completed-onboarding call must not queue a stale open")
    #expect(openCount == 0, "no open fired")
  }

  /// The eligibility guard short-circuits `openOnboardingWindow()` even when
  /// the SwiftUI bridge is wired.
  @Test("eligibility guard blocks open when ineligible")
  func openOnboardingWindowRespectsEligibilityGuard() {
    var openCount = 0
    let coordinator = AppWindowCoordinator(
      canOpenOnboarding: { false },
      isOnboardingComplete: { true }
    )
    coordinator.openOnboardingAction = { openCount += 1 }

    coordinator.openOnboardingWindow()
    #expect(openCount == 0, "ineligible → open must not fire")
  }

  /// `closeOnboardingWindow()` fires the `onOnboardingDismissed` icon-refresh
  /// seam without reaching back into AppDelegate's menu logic.
  @Test("close fires the onboarding-dismissed seam")
  func closeOnboardingWindowFiresOnboardingDismissedSeam() {
    var dismissedCount = 0
    let coordinator = AppWindowCoordinator(
      canOpenOnboarding: { true },
      isOnboardingComplete: { false }
    )
    coordinator.onOnboardingDismissed = { dismissedCount += 1 }

    coordinator.closeOnboardingWindow()
    #expect(dismissedCount == 1, "close fires the icon-refresh seam exactly once")
  }

  // MARK: - #1392: isMainWindowPresented(windowStates:)

  /// Input-driven pure decision — no real `NSWindow`/`NSApp` state, matching
  /// this suite's existing convention (real window-server behavior is Live
  /// UAT-only, per the file header above). r2 (code-diff review): dropped
  /// the app-hidden broadening a stale/closed-but-retained window could
  /// exploit — presence is `isVisible || isMiniaturized` only now.

  @Test("matching visible window is presented")
  func isMainWindowPresentedTrueForVisible() {
    let present = AppWindowCoordinator.isMainWindowPresented(
      windowStates: [(matchesIdentity: true, isVisible: true, isMiniaturized: false)]
    )
    #expect(present)
  }

  @Test("matching minimized window is still presented — #1392 r1 finding")
  func isMainWindowPresentedTrueForMinimized() {
    let present = AppWindowCoordinator.isMainWindowPresented(
      windowStates: [(matchesIdentity: true, isVisible: false, isMiniaturized: true)]
    )
    #expect(present, "a minimized window still exists — isVisible alone is the wrong proxy")
  }

  @Test("a matching but neither-visible-nor-minimized window is not presented — #1392 r2 finding")
  func isMainWindowPresentedFalseForHiddenNotMinimized() {
    // Covers a stale/closed-but-retained `NSWindow` still enumerable in
    // `NSApp.windows`: it must never count as presented on its own, even
    // though a real app-hide would ALSO put a genuinely-open window in this
    // exact (isVisible: false, isMiniaturized: false) shape — that's the
    // accepted tradeoff (Live UAT preface above), not a regression.
    let present = AppWindowCoordinator.isMainWindowPresented(
      windowStates: [(matchesIdentity: true, isVisible: false, isMiniaturized: false)]
    )
    #expect(!present)
  }

  @Test("no matching window in the list is not presented")
  func isMainWindowPresentedFalseWhenAbsent() {
    let present = AppWindowCoordinator.isMainWindowPresented(windowStates: [])
    #expect(!present)
  }

  @Test("only a non-matching window (Sparkle's dialog) present is not presented")
  func isMainWindowPresentedFalseForNonMatchingOnly() {
    let present = AppWindowCoordinator.isMainWindowPresented(
      windowStates: [(matchesIdentity: false, isVisible: true, isMiniaturized: false)]
    )
    #expect(!present, "a titled-but-differently-named window (Sparkle's dialog) must not count")
  }
}
