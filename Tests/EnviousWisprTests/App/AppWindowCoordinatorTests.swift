import AppKit
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore

@MainActor
@Suite("AppWindowCoordinator", .tags(.productOutcome))
struct AppWindowCoordinatorTests {
  init() { _ = NSApplication.shared }

  @Test("an interrupted Setup completion requests the main window when its bridge attaches")
  func completionBeforeMainBridge() {
    // An existing native main window can satisfy the handoff without the bridge.
    let windows = NSApp.windows.filter { $0.title == AppConstants.appName }
    #expect(windows.isEmpty)
    guard windows.isEmpty else { return }
    let coordinator = AppWindowCoordinator(
      application: RecordingDesktopPresentationEffects(), showInDock: { false },
      isOnboardingComplete: { true })
    var mainOpens = 0
    coordinator.finishSetup()
    #expect(mainOpens == 0)
    coordinator.attachMainWindow(open: { mainOpens += 1 })
    coordinator.attachMainWindow(open: { mainOpens += 1 })
    #expect(mainOpens == 1)
  }

  @Test("ordinary completed startup does not create a Setup session or a second main open")
  func completedStartup() {
    let coordinator = AppWindowCoordinator(
      application: RecordingDesktopPresentationEffects(), showInDock: { true },
      isOnboardingComplete: { true })
    let session = SetupSession { _ in fatalError("completed startup should not build Setup") }
    coordinator.setupSession = session
    var mainOpens = 0
    coordinator.attachMainWindow(open: { mainOpens += 1 })
    #expect(!coordinator.openOnboardingWindow())
    #expect(session.components == nil && mainOpens == 0)
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

  @Test("the Setup window is found by its scene id, whatever its title says (#3142)")
  @MainActor
  func onboardingWindowMatchesByIdentifierNotTitle() {
    let translated = NSWindow(
      contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
    translated.identifier = NSUserInterfaceItemIdentifier(AppConstants.onboardingWindowID)
    translated.title = "Einrichtung"
    #expect(OnboardingWindowIdentity.matches(translated))

    // SwiftUI's numbered form for the same scene matches too.
    let numbered = NSWindow(
      contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
    numbered.identifier = NSUserInterfaceItemIdentifier("onboarding-AppWindow-1")
    #expect(OnboardingWindowIdentity.matches(numbered))

    // A different scene whose id merely starts with the same letters never matches.
    let prefixed = NSWindow(
      contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
    prefixed.identifier = NSUserInterfaceItemIdentifier("onboardingTips")
    #expect(!OnboardingWindowIdentity.matches(prefixed))

    // Only a number may follow the scene's AppWindow prefix.
    for raw in ["onboarding-AppWindow-help", "onboarding-AppWindow-"] {
      let other = NSWindow(
        contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
      other.identifier = NSUserInterfaceItemIdentifier(raw)
      #expect(!OnboardingWindowIdentity.matches(other), "\(raw)")
    }

    // Another scene's window never matches, even titled like Setup.
    let lookalike = NSWindow(
      contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
    lookalike.identifier = NSUserInterfaceItemIdentifier("main")
    lookalike.title = AppConstants.onboardingWindowTitle
    #expect(!OnboardingWindowIdentity.matches(lookalike))

    // A window with no identifier never matches, whatever its title says.
    let untagged = NSWindow(
      contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
    untagged.title = AppConstants.onboardingWindowTitle
    #expect(!OnboardingWindowIdentity.matches(untagged))
  }
}
