import AppKit
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore

@MainActor
@Suite("AppWindowCoordinator", .tags(.productOutcome))
struct AppWindowCoordinatorTests {
  init() { _ = NSApplication.shared }

  /// Takes down any main window a test showed (tests run in one process).
  private func tearDown(_ coordinator: AppWindowCoordinator) {
    coordinator.mainWindowPresenter.window?.orderOut(nil)
  }

  @Test("a completed install's launch shows the main window once and brings the app forward")
  func completedLaunchShowsMainOnce() {
    let effects = RecordingDesktopPresentationEffects()
    let coordinator = AppWindowCoordinator(
      application: effects, showInDock: { false }, isOnboardingComplete: { true })
    coordinator.mainWindowPresenter.frameName = ""
    defer { tearDown(coordinator) }
    let session = SetupSession { _ in fatalError("completed startup should not build Setup") }
    coordinator.setupSession = session
    coordinator.openFirstSurfaceAtLaunch(automaticallyOpenSetup: true)
    let window = coordinator.mainWindowPresenter.window
    #expect(window?.isVisible == true)
    #expect(window?.title == AppConstants.appName)
    // A relocation replay or a second call opens nothing more.
    coordinator.openFirstSurfaceAtLaunch(automaticallyOpenSetup: true)
    #expect(coordinator.mainWindowPresenter.window === window)
    #expect(effects.calls == [.setPolicy(.regular), .activate(.ignoringOtherApps)])
    #expect(session.components == nil)
  }

  @Test("finishing Setup shows the main window, marks the handoff, and works with no prior open")
  func finishSetupShowsMain() {
    let effects = RecordingDesktopPresentationEffects()
    let coordinator = AppWindowCoordinator(
      application: effects, showInDock: { false }, isOnboardingComplete: { true })
    coordinator.mainWindowPresenter.frameName = ""
    defer { tearDown(coordinator) }
    coordinator.finishSetup()
    #expect(coordinator.mainWindowPresenter.window?.isVisible == true)
    #expect(coordinator.mainWindowVisitIsSetupHandoff)
    // The launch path that follows an interrupted visit's completion shows nothing more.
    let window = coordinator.mainWindowPresenter.window
    coordinator.openFirstSurfaceAtLaunch(automaticallyOpenSetup: true)
    #expect(coordinator.mainWindowPresenter.window === window)
    #expect(effects.activations == [.ignoringOtherApps])
  }

  @Test("closing the main window keeps the Dock icon only while the switch or another window asks")
  func mainCloseRefreshesDockPolicy() throws {
    let effects = RecordingDesktopPresentationEffects()
    let coordinator = AppWindowCoordinator(
      application: effects, showInDock: { false }, isOnboardingComplete: { true })
    coordinator.mainWindowPresenter.frameName = ""
    defer { tearDown(coordinator) }
    coordinator.showWindow()
    let window = try #require(coordinator.mainWindowPresenter.window)
    coordinator.mainWindowPresenter.windowWillClose(
      Notification(name: NSWindow.willCloseNotification, object: window))
    #expect(coordinator.mainWindowPresenter.window == nil)
    #expect(effects.policies.last == .accessory)
    window.orderOut(nil)
  }

  // MARK: - #1392: isMainWindowPresented

  /// Input-driven pure decision: no real `NSWindow`/`NSApp` state. Presence is
  /// `isVisible || isMiniaturized` only (#1392 r2: an app-wide hide is not presence).

  @Test("a visible main window is presented")
  func isMainWindowPresentedTrueForVisible() {
    #expect(AppWindowCoordinator.isMainWindowPresented((isVisible: true, isMiniaturized: false)))
  }

  @Test("a minimized main window is still presented — #1392 r1 finding")
  func isMainWindowPresentedTrueForMinimized() {
    #expect(
      AppWindowCoordinator.isMainWindowPresented((isVisible: false, isMiniaturized: true)),
      "a minimized window still exists — isVisible alone is the wrong proxy")
  }

  @Test("a main window neither visible nor minimized is not presented — #1392 r2 finding")
  func isMainWindowPresentedFalseForHiddenNotMinimized() {
    #expect(
      AppWindowCoordinator.isMainWindowPresented((isVisible: false, isMiniaturized: false)) == false)
  }

  @Test("no main window is not presented")
  func isMainWindowPresentedFalseWhenAbsent() {
    #expect(AppWindowCoordinator.isMainWindowPresented(nil) == false)
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
