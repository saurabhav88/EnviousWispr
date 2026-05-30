@preconcurrency import AVFoundation
import AppKit
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprASR
@testable import EnviousWisprAudio
@testable import EnviousWisprPipeline
@testable import EnviousWisprStorage

/// PR-B.3 of #763 — unit tests for `MenuBarController`.
///
/// The identity-preservation gate. `renderMenu(into:state:)` and
/// `iconState(_:)` are pure functions over a `MenuBarViewState`, so the menu
/// surface is golden-tested deterministically against fixtures without posing
/// the concrete `final` homes. Action dispatch is exercised through the real
/// `@objc` selector wired into each rendered menu item.
@MainActor
@Suite("MenuBarController")
struct MenuBarControllerTests {

  /// Populates the `NSApp` global before any SUT line touches it
  /// (swift-patterns.md — `NSApp`-touching coordinator test rule).
  init() { _ = NSApplication.shared }

  // MARK: - iconState (pure mapping)

  @Test("iconState: idle + no warning + onboarding complete → idle")
  func iconStateIdle() {
    #expect(MenuBarController.iconState(fixture(pipelineState: .idle)) == .idle)
  }

  @Test("iconState: recording → recording")
  func iconStateRecording() {
    #expect(MenuBarController.iconState(fixture(pipelineState: .recording)) == .recording)
  }

  @Test("iconState: transcribing / polishing / loadingModel → processing")
  func iconStateProcessing() {
    #expect(MenuBarController.iconState(fixture(pipelineState: .transcribing)) == .processing)
    #expect(MenuBarController.iconState(fixture(pipelineState: .polishing)) == .processing)
    #expect(MenuBarController.iconState(fixture(pipelineState: .loadingModel)) == .processing)
  }

  @Test("iconState: error → error")
  func iconStateError() {
    #expect(MenuBarController.iconState(fixture(pipelineState: .error("boom"))) == .error)
  }

  @Test("iconState: complete → idle (no special icon)")
  func iconStateComplete() {
    #expect(MenuBarController.iconState(fixture(pipelineState: .complete)) == .idle)
  }

  @Test("iconState: idle + accessibility warning → error")
  func iconStateAccessibilityWarning() {
    let s = fixture(pipelineState: .idle, showAccessibilityWarning: true)
    #expect(MenuBarController.iconState(s) == .error)
  }

  @Test("iconState: accessibility warning ignored while recording")
  func iconStateWarningIgnoredWhileRecording() {
    // needsAccessWarning requires `pipelineState == .idle`; recording wins.
    let s = fixture(pipelineState: .recording, showAccessibilityWarning: true)
    #expect(MenuBarController.iconState(s) == .recording)
  }

  @Test("iconState: idle + onboarding incomplete → error")
  func iconStateOnboardingIncomplete() {
    let s = fixture(pipelineState: .idle, onboardingComplete: false)
    #expect(MenuBarController.iconState(s) == .error)
  }

  // MARK: - renderMenu golden fixtures

  @Test("renderMenu (a): idle, onboarding complete, no warning, no updater")
  func renderMenuIdle() {
    let controller = makeController()
    let menu = NSMenu()
    controller.renderMenu(into: menu, state: fixture(pipelineState: .idle))

    let titles = menu.items.map(\.title)
    #expect(
      titles == [
        "Parakeet v3 — LLM Deactivated",  // status line
        "Version: \(AppConstants.appVersion)",
        "",  // separator
        "Start Recording",
        "",  // separator
        "Settings...",
        "",  // separator
        "Quit \(AppConstants.appName)",
      ],
      "Idle menu structure drifted. Got: \(titles)")

    // Status + version items are disabled labels.
    #expect(menu.items[0].isEnabled == false)
    #expect(menu.items[1].isEnabled == false)
    // Separators are separators.
    #expect(menu.items[2].isSeparatorItem)
    #expect(menu.items[4].isSeparatorItem)
    #expect(menu.items[6].isSeparatorItem)
    // Settings carries the comma key-equivalent; Quit carries "q".
    #expect(item(menu, "Settings...")?.keyEquivalent == ",")
    #expect(item(menu, "Quit \(AppConstants.appName)")?.keyEquivalent == "q")
    // Every actionable item targets the controller.
    for actionable in menu.items where actionable.action != nil {
      #expect(
        actionable.target as AnyObject? === controller,
        "\(actionable.title) should target the MenuBarController")
    }
  }

  @Test("renderMenu (b): recording → Stop Recording, record item enabled")
  func renderMenuRecording() {
    let controller = makeController()
    let menu = NSMenu()
    controller.renderMenu(into: menu, state: fixture(pipelineState: .recording))

    #expect(item(menu, "Stop Recording") != nil)
    #expect(item(menu, "Start Recording") == nil)
    // Record item is enabled while recording (so the user can stop).
    #expect(item(menu, "Stop Recording")?.isEnabled == true)
  }

  @Test("renderMenu: record item disabled mid-pipeline (transcribing)")
  func renderMenuRecordDisabledWhileTranscribing() {
    let controller = makeController()
    let menu = NSMenu()
    controller.renderMenu(into: menu, state: fixture(pipelineState: .transcribing))
    // isActive && !isRecording → record item disabled.
    #expect(item(menu, "Start Recording")?.isEnabled == false)
  }

  @Test("renderMenu (c): onboarding incomplete → Setup Required item on top")
  func renderMenuOnboardingIncomplete() {
    let controller = makeController()
    let menu = NSMenu()
    controller.renderMenu(
      into: menu, state: fixture(pipelineState: .idle, onboardingComplete: false))

    #expect(menu.items.first?.title == "Setup Required: Continue Setup…")
    #expect(menu.items.first?.target as AnyObject? === controller)
    #expect(menu.items[1].isSeparatorItem)
  }

  @Test("renderMenu (d): accessibility warning → Paste disabled item")
  func renderMenuAccessibilityWarning() {
    let controller = makeController()
    let menu = NSMenu()
    controller.renderMenu(
      into: menu, state: fixture(pipelineState: .idle, showAccessibilityWarning: true))

    let warning = item(menu, "Paste disabled — Accessibility required")
    #expect(warning != nil)
    #expect(warning?.target as AnyObject? === controller)
  }

  @Test("renderMenu (e): hasUpdater → Check for Updates targets SparkleUpdateController")
  func renderMenuCheckForUpdates() {
    let controller = makeController()
    let menu = NSMenu()
    controller.renderMenu(into: menu, state: fixture(pipelineState: .idle, hasUpdater: true))

    let updateItem = item(menu, "Check for Updates…")
    #expect(updateItem != nil, "hasUpdater=true must render the Check for Updates item")
    // PR-B.1 wiring preserved: the item targets the Sparkle controller, NOT
    // the MenuBarController.
    #expect(updateItem?.target is SparkleUpdateController)
    #expect(updateItem?.target as AnyObject? !== controller)
    #expect(
      updateItem?.action == #selector(SparkleUpdateController.openUpdateCheckFromMenu(_:)))
  }

  @Test("renderMenu: auto-stop indicator appears when vadAutoStop is on")
  func renderMenuAutoStop() {
    let controller = makeController()
    let menu = NSMenu()
    controller.renderMenu(into: menu, state: fixture(pipelineState: .idle, vadAutoStop: true))
    #expect(item(menu, "Auto-stop on silence: On") != nil)
  }

  // MARK: - Action dispatch

  @Test("menu actions dispatch into the injected MenuBarActions closures")
  func actionsDispatch() async {
    let spy = ActionSpy()
    let controller = makeController(spy: spy)
    let menu = NSMenu()
    controller.renderMenu(
      into: menu, state: fixture(pipelineState: .idle, onboardingComplete: false))

    perform(item(menu, "Setup Required: Continue Setup…"))
    #expect(spy.fired == ["continueOnboarding"])

    perform(item(menu, "Settings..."))
    #expect(spy.fired == ["continueOnboarding", "openSettings"])

    perform(item(menu, "Quit \(AppConstants.appName)"))
    #expect(spy.fired == ["continueOnboarding", "openSettings", "quit"])

    // toggleRecording dispatches through an async Task — yield so it runs.
    perform(item(menu, "Start Recording"))
    await Task.yield()
    await Task.yield()
    #expect(spy.fired.contains("toggleRecording"))
  }

  @Test("accessibility-warning item dispatches openPermissions")
  func warningItemDispatchesPermissions() {
    let spy = ActionSpy()
    let controller = makeController(spy: spy)
    let menu = NSMenu()
    controller.renderMenu(
      into: menu, state: fixture(pipelineState: .idle, showAccessibilityWarning: true))
    perform(item(menu, "Paste disabled — Accessibility required"))
    #expect(spy.fired == ["openPermissions"])
  }

  // MARK: - Fixtures

  private func fixture(
    pipelineState: PipelineState,
    onboardingComplete: Bool = true,
    vadAutoStop: Bool = false,
    showAccessibilityWarning: Bool = false,
    hasUpdater: Bool = false
  ) -> MenuBarViewState {
    MenuBarViewState(
      pipelineState: pipelineState,
      asrLabel: "Parakeet v3",
      llmLabel: "LLM Deactivated",
      onboardingComplete: onboardingComplete,
      vadAutoStop: vadAutoStop,
      vadSilenceTimeout: 2.0,
      showAccessibilityWarning: showAccessibilityWarning,
      hasUpdater: hasUpdater
    )
  }

  private func makeController(spy: ActionSpy = ActionSpy()) -> MenuBarController {
    let asrManager = ASRManager()
    // Shared lightweight audio fake from DictationRuntimeTestSupport (same
    // test target). MenuBarController never reads `audioLevel` in these tests
    // (the icon animator's level closure is only wired by `installStatusItem`,
    // which the unit tests do not call).
    let audioCapture: any AudioCaptureInterface = RouterTestAudioCapture()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("menu-bar-controller-tests-\(UUID().uuidString)")
    let store = TranscriptStore(directory: tempDir)
    let parakeet = DictationRuntimeFixtures.makeParakeetDriver(
      audioCapture: audioCapture, asrManager: asrManager, store: store)
    let whisperKit = DictationRuntimeFixtures.makeWhisperKitPipeline(
      audioCapture: audioCapture, store: store)
    let liveRecordingState = LiveRecordingState(
      kernelDriver: parakeet, whisperKitKernelDriver: whisperKit,
      audioCapture: audioCapture, asrManager: asrManager)
    let settings = SettingsManager()
    let backendMetadata = BackendMetadata(
      settings: settings, asrManager: asrManager,
      llmDiscovery: LLMModelDiscoveryCoordinator(keychainManager: KeychainManager()))
    // Nil-fake updater factory — no real Sparkle boot in the test process.
    let sparkle = SparkleUpdateController(
      holder: UpdateCoordinatorHolder(),
      bundleVersionProvider: { "v-test" },
      updaterFactory: SparkleUpdaterFactory { _, _ in nil })
    let controller = MenuBarController(
      liveRecordingState: liveRecordingState,
      backendMetadata: backendMetadata,
      sparkleUpdateController: sparkle,
      settings: settings,
      permissions: PermissionsService(),
      actions: MenuBarActions(
        continueOnboarding: { spy.fired.append("continueOnboarding") },
        openSettings: { spy.fired.append("openSettings") },
        openPermissions: { spy.fired.append("openPermissions") },
        toggleRecording: { spy.fired.append("toggleRecording") },
        quit: { spy.fired.append("quit") }
      )
    )
    return controller
  }

  private func item(_ menu: NSMenu, _ title: String) -> NSMenuItem? {
    menu.items.first { $0.title == title }
  }

  private func perform(_ menuItem: NSMenuItem?) {
    guard let menuItem, let action = menuItem.action,
      let target = menuItem.target as? NSObject
    else {
      Issue.record("Menu item missing target/action")
      return
    }
    target.perform(action, with: menuItem)
  }
}

/// Records which `MenuBarActions` closure fired, in order.
@MainActor
final class ActionSpy {
  var fired: [String] = []
}
