import AppKit
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #2480: the Dock policy. When this fails, the user sees the app launch behind other windows with
/// no app menu or Cmd-Tab entry, a Dock icon that vanishes while "Show app in Dock" is on, or an
/// update dialog that opens behind everything.
///
/// Real window-server behaviour (a launch window actually in front, a close actually dropping the
/// Dock icon) is Live UAT; these tests hold the rule and who calls what.
@MainActor
@Suite(.tags(.productOutcome))
struct AppWindowCoordinatorDockPolicyTests {
  init() { _ = NSApplication.shared }  // the coordinator reads `NSApp.windows` at fall points

  private func coordinator(
    _ effects: RecordingDesktopPresentationEffects, showInDock: Bool
  ) -> AppWindowCoordinator {
    AppWindowCoordinator(
      application: effects, showInDock: { showInDock }, canOpenOnboarding: { false },
      isOnboardingComplete: { true })
  }

  /// All sixteen input combinations against an independent literal rule: accessory ONLY when the
  /// user turned the Dock icon off AND nothing of ours is on screen.
  @Test(
    "regular unless the switch is off and no window or update dialog is up",
    arguments: [false, true], [false, true])
  func decisionTable(showInDock: Bool, mainWindowPresented: Bool) {
    for onboarding in [false, true] {
      for dialog in [false, true] {
        let expected: ApplicationPolicy =
          (!showInDock && !mainWindowPresented && !onboarding && !dialog) ? .accessory : .regular
        #expect(
          AppWindowCoordinator.activationPolicy(
            showInDock: showInDock, mainWindowPresented: mainWindowPresented,
            onboardingPresented: onboarding, updateDialogActive: dialog) == expected)
      }
    }
  }

  /// The reported bug: launch forced accessory. Launch now rises to regular under either setting,
  /// then asks to come forward.
  @Test(
    "launch is regular and asks to come forward, whatever the switch says",
    arguments: [false, true])
  func launchRisesAndActivates(showInDock: Bool) {
    let effects = RecordingDesktopPresentationEffects()
    let sut = coordinator(effects, showInDock: showInDock)
    sut.beginLaunch()
    sut.finishLaunch()
    #expect(effects.calls == [.setPolicy(.regular), .activate(.ignoringOtherApps)])
  }

  @Test("an update dialog makes the app regular and brings it forward")
  func updateDialogRises() {
    let effects = RecordingDesktopPresentationEffects()
    let sut = coordinator(effects, showInDock: false)
    sut.updateDialogWillShow()
    #expect(effects.calls == [.setPolicy(.regular), .activate(.standard)])
  }

  /// #3156 battery survivor (row 7): a fall that ignored the open update dialog passed every
  /// other case. With the switch off and none of our windows open, only the dialog keeps the app
  /// regular, so dropping that input turns this fall into accessory and strands the dialog.
  @Test("with Show app in Dock off, a fall while an update dialog is up keeps the app regular")
  func fallDuringUpdateDialogKeepsRegular() {
    let effects = RecordingDesktopPresentationEffects()
    let sut = coordinator(effects, showInDock: false)
    sut.updateDialogWillShow()
    sut.refreshActivationPolicy(excluding: nil)
    #expect(effects.policies == [.regular, .regular])
  }

  /// #1392's regression, now also guarded by the switch: an update session ending must not take
  /// the Dock icon away from someone who asked to keep it.
  @Test("with Show app in Dock on, an update session ending keeps the app regular")
  func sessionEndKeepsDockWhenOn() {
    let effects = RecordingDesktopPresentationEffects()
    let sut = coordinator(effects, showInDock: true)
    sut.updateDialogWillShow()
    sut.updateSessionDidEnd()
    #expect(effects.policies == [.regular, .regular])
  }
}
