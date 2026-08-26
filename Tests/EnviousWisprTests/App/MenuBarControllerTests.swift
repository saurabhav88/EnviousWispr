@preconcurrency import AVFoundation
import AppKit
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprAppKit
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
    #expect(MenuBarController.iconState(fixture(pipelineState: .error(.modelWedged))) == .error)
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

  // MARK: - iconState update cue (#1019)

  @Test("iconState: idle + update available → updatePending")
  func iconStateUpdatePending() {
    let s = fixture(pipelineState: .idle, updateAvailable: true)
    #expect(MenuBarController.iconState(s) == .updatePending)
  }

  @Test("iconState: update cue never overrides recording")
  func iconStateUpdateIgnoredWhileRecording() {
    let s = fixture(pipelineState: .recording, updateAvailable: true)
    #expect(MenuBarController.iconState(s) == .recording)
  }

  @Test("iconState: update cue never overrides processing")
  func iconStateUpdateIgnoredWhileProcessing() {
    let s = fixture(pipelineState: .transcribing, updateAvailable: true)
    #expect(MenuBarController.iconState(s) == .processing)
  }

  @Test("iconState: update cue never overrides accessibility warning")
  func iconStateUpdateIgnoredWithWarning() {
    let s = fixture(pipelineState: .idle, showAccessibilityWarning: true, updateAvailable: true)
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
        "Add Selected Word  \u{2303}\u{2325} W",  // #2412, disabled; the chord rides in the title
        "",  // separator
        "Settings...",
        "Appearance",  // #1047 submenu parent
        "",  // separator
        "Quit \(AppConstants.appName)",
      ],
      "Idle menu structure drifted. Got: \(titles)")

    // Status + version items are disabled labels.
    #expect(menu.items[0].isEnabled == false)
    #expect(menu.items[1].isEnabled == false)
    // Separators are separators.
    #expect(menu.items[2].isSeparatorItem)
    #expect(menu.items[5].isSeparatorItem)
    #expect(menu.items[8].isSeparatorItem)
    // Settings carries the comma key-equivalent; Quit carries "q".
    #expect(item(menu, "Settings...")?.keyEquivalent == ",")
    #expect(item(menu, "Quit \(AppConstants.appName)")?.keyEquivalent == "q")
    // Every actionable item targets the controller. Submenu parents (e.g.
    // Appearance) are excluded: AppKit assigns them a system `submenuAction:`
    // whose target is the submenu itself; their children's targeting is covered
    // by `renderMenuAppearanceSubmenu`.
    for actionable in menu.items where actionable.action != nil && actionable.submenu == nil {
      #expect(
        actionable.target as AnyObject? === controller,
        "\(actionable.title) should target the MenuBarController")
    }
  }

  @Test(
    "renderMenu: Appearance submenu checkmarks the current preference, clears the others",
    arguments: [AppearancePreference.system, .light, .dark])
  func renderMenuAppearanceSubmenu(current: AppearancePreference) {
    let controller = makeController()
    let menu = NSMenu()
    controller.renderMenu(
      into: menu, state: fixture(pipelineState: .idle, appearancePreference: current))

    let appearance = item(menu, "Appearance")
    #expect(appearance != nil, "Appearance item missing")
    let submenu = appearance?.submenu
    #expect(submenu?.items.map(\.title) == ["System", "Light", "Dark"])

    // Exactly the current preference is checked; the other two are off.
    let expectedOn: String = {
      switch current {
      case .system: return "System"
      case .light: return "Light"
      case .dark: return "Dark"
      }
    }()
    for sub in submenu?.items ?? [] {
      #expect(
        sub.state == (sub.title == expectedOn ? .on : .off),
        "\(sub.title) checkmark wrong for current=\(current)")
      #expect(sub.representedObject as? String != nil, "\(sub.title) must carry its rawValue")
      #expect(sub.target as AnyObject? === controller, "\(sub.title) should target the controller")
    }
  }

  /// **The property has to MEAN something, and for the life of this menu it did not.** `NSMenu`
  /// auto-enables by default, so an item with a target and an action is enabled whatever
  /// `isEnabled` says. Live UAT caught the Quick Add item rendering enabled with no selection while
  /// this file's own assertions read false — they inspect the property on a menu AppKit never
  /// validated, which is a claim about the decision and not about the menu the user sees.
  ///
  /// Asserted on the FACTORY the status item is built from, which is where the property is set —
  /// a detached `NSMenu()` would assert AppKit's default and prove nothing about our menu.
  @Test("The status-item menu does not auto-enable, so a disabled item is really disabled")
  func theMenuDoesNotAutoEnable() {
    let controller = makeController()
    let menu = MenuBarController.makeStatusMenu(delegate: controller)

    #expect(
      menu.autoenablesItems == false,
      "with auto-enabling on, every isEnabled=false in renderMenu is silently ignored")
    #expect(menu.delegate as AnyObject? === controller, "and it still repopulates on open")
  }

  /// **The item is inert with nothing selected, and live with something.** Both halves matter: an
  /// enabled item over no selection spends a click to report a refusal the menu already knew about,
  /// and a disabled item over a real selection is the door not opening at all.
  @Test("The Quick Add item follows the selection, and carries it to the action")
  func theQuickAddItemFollowsTheSelection() {
    let spy = ActionSpy()
    let controller = makeController(spy: spy)

    let empty = NSMenu()
    controller.renderMenu(into: empty, state: fixture(pipelineState: .idle))
    let inert = itemPrefixed(empty, "Add Selected Word")
    #expect(inert?.isEnabled == false)

    let ready = NSMenu()
    controller.renderMenu(
      into: ready, state: fixture(pipelineState: .idle, quickAdd: .ready("clawwed")))
    let live = itemPrefixed(ready, "Add \u{201C}clawwed\u{201D}")
    #expect(live?.isEnabled == true)
    #expect(live?.target as AnyObject? === controller)
    // **No key equivalent at all.** A global hotkey is a physical key code; a key equivalent is a
    // character matched against the active layout. On AZERTY they are different keys, so an item
    // carrying one can respond to a chord that is not the user's.
    #expect(live?.keyEquivalent == "")
    #expect(live?.keyEquivalentModifierMask == [])

    perform(live)
    #expect(
      spy.fired == ["addSelectedWord:clawwed"],
      "the action must carry the text the TITLE quoted, not a fresh read taken after the menu closed")
  }

  // Re-homed from `QuickAddMenuItemTests`, which owns the PURE title decisions and has no
  // controller, no fixture and no way to click anything. `the-rig-decides-where-a-test-lives`: this
  // case needs a rendered menu and an action spy, and those live here.
  /// The pairing: what the menu SHOWS is normalised, what the action CARRIES is not.
  @Test("The action receives the original selection, newline and all")
  func theActionCarriesTheUnmodifiedSelection() {
    let spy = ActionSpy()
    let controller = makeController(spy: spy)
    let menu = NSMenu()
    controller.renderMenu(
      into: menu, state: fixture(pipelineState: .idle, quickAdd: .ready("clawwed\nmachine")))

    let row = itemPrefixed(menu, "Add \u{201C}clawwed machine\u{201D}")
    #expect(row != nil, "the TITLE is collapsed")
    perform(row)
    #expect(
      spy.fired == ["addSelectedWord:clawwed\nmachine"],
      "the ACTION carries the original, because that is what the user selected")
  }

  /// **The shortcut is user-editable, so advertising a hard-coded one teaches a lie after a
  /// rebind.** Shown as text rather than as a key equivalent — see `quickAddShortcutLabel`.
  @Test("A rebound shortcut is what the menu advertises")
  func theMenuFollowsTheConfiguredBinding() {
    let controller = makeController()
    let menu = NSMenu()
    controller.renderMenu(
      into: menu,
      state: fixture(
        pipelineState: .idle, quickAdd: .ready("clawwed"), quickAddShortcut: "\u{2318}\u{21E7} J"))

    let row = itemPrefixed(menu, "Add \u{201C}clawwed\u{201D}")
    #expect(row?.title == "Add \u{201C}clawwed\u{201D}  \u{2318}\u{21E7} J")
    #expect(row?.keyEquivalent == "", "never a key equivalent, whatever the binding")
  }

  /// **Nothing rather than an approximation.** A menu that teaches no shortcut is recoverable; one
  /// that teaches a chord the user reassigned is not, because they have no reason to doubt it.
  @Test("An unrepresentable chord advertises nothing at all")
  func anUnrepresentableChordShowsNothing() {
    let controller = makeController()
    let menu = NSMenu()
    controller.renderMenu(
      into: menu,
      state: fixture(pipelineState: .idle, quickAdd: .ready("clawwed"), quickAddShortcut: nil))

    #expect(item(menu, "Add \u{201C}clawwed\u{201D}") != nil, "the title carries no trailing hint")
  }

  /// Every case is paired with its opposite, or a function that returned nil for everything would
  /// look exactly like this one passing.
  private static func label(
    _ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags,
    record: (UInt16, NSEvent.ModifierFlags) = (49, []),
    cancel: (UInt16, NSEvent.ModifierFlags) = (53, [])
  ) -> String? {
    MenuBarController.quickAddShortcutLabel(
      keyCode: keyCode, modifiers: modifiers,
      recordKeyCode: record.0, recordModifiers: record.1,
      cancelKeyCode: cancel.0, cancelModifiers: cancel.1)
  }

  /// The mapping itself: what is worth showing, and what is not.
  @Test("An unknown key code advertises nothing rather than `Key 999`")
  func onlyKnownChordsAreAdvertised() {
    #expect(Self.label(13, [.control, .option]) == "\u{2303}\u{2325} W")
    #expect(Self.label(999, [.command]) == nil)
  }

  /// **A chord another role owns must not be advertised here, and this is worse than a dead hint.**
  /// `ShortcutMatcher.role` gives Record priority on a shared binding and
  /// `HotkeyService.quickAddMayHoldItsChord` unregisters Quick Add while a same-binding Cancel is
  /// armed — so the advertised chord can START OR CANCEL A RECORDING. This menu exists because the
  /// shortcut can fail; sending the user to the heart path instead is the one lie it must not tell.
  /// Cloud review, PR #2427.
  @Test("A chord Record or Cancel owns is not advertised as Quick Add's")
  func acontestedChordIsNotAdvertised() {
    // The shipped default is uncontested and still shows, so the guard cannot be a blanket nil.
    #expect(Self.label(13, [.control, .option]) != nil, "the default is nobody else's")

    #expect(Self.label(49, [], record: (49, [])) == nil, "Record owns this chord")
    #expect(Self.label(53, [], cancel: (53, [])) == nil, "Cancel owns this chord")

    // MODIFIERS are half the identity: the same key code under a different chord is a different
    // shortcut, and refusing it too would silence a hint that is perfectly honest.
    #expect(
      Self.label(49, [.control, .option], record: (49, [])) != nil,
      "same key, different chord — not a collision")
    #expect(
      Self.label(49, [], record: (49, [.command])) != nil,
      "and the other way round, or the check is comparing key codes alone")
  }

  /// The title composer, paired so a missing hint cannot leave trailing whitespace.
  @Test("The chord is appended, and its absence leaves the title untouched")
  func theTitleCarriesTheChord() {
    #expect(
      MenuBarController.quickAddTitle(base: "Add Selected Word", shortcut: "\u{2303}\u{2325} W")
        == "Add Selected Word  \u{2303}\u{2325} W")
    #expect(
      MenuBarController.quickAddTitle(base: "Add Selected Word", shortcut: nil)
        == "Add Selected Word")
    #expect(
      MenuBarController.quickAddTitle(base: "Add Selected Word", shortcut: "")
        == "Add Selected Word", "an empty hint must not leave trailing spaces")
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

  @Test(
    "renderMenu: update available + install enabled → versioned Install item targets controller")
  func renderMenuUpdateInstallEnabled() {
    let controller = makeController()
    let menu = NSMenu()
    controller.renderMenu(
      into: menu,
      state: fixture(
        pipelineState: .idle, updateAvailable: true, updateDisplayVersion: "2.1.4",
        installEnabled: true))

    let installItem = item(menu, "Update ready: Install v2.1.4")
    #expect(installItem != nil, "Enabled update item must show the version")
    #expect(installItem?.isEnabled == true)
    #expect(installItem?.target as AnyObject? === controller)
  }

  @Test("renderMenu: update available but dictation active → disabled finish-dictating item")
  func renderMenuUpdateInstallDisabledWhileDictating() {
    let controller = makeController()
    let menu = NSMenu()
    controller.renderMenu(
      into: menu,
      state: fixture(
        pipelineState: .recording, updateAvailable: true, updateDisplayVersion: "2.1.4",
        installEnabled: false))

    #expect(item(menu, "Update ready: Install v2.1.4") == nil)
    let blocked = item(menu, "Update ready: finish dictating to install")
    #expect(blocked != nil, "Disabled item must explain why install is blocked")
    #expect(blocked?.isEnabled == false)
  }

  @Test("renderMenu: no update → no install item")
  func renderMenuNoUpdateNoItem() {
    let controller = makeController()
    let menu = NSMenu()
    controller.renderMenu(into: menu, state: fixture(pipelineState: .idle))
    #expect(item(menu, "Update ready: Install") == nil)
    #expect(menu.items.allSatisfy { !$0.title.hasPrefix("Update ready") })
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
    hasUpdater: Bool = false,
    updateAvailable: Bool = false,
    updateDisplayVersion: String? = nil,
    installEnabled: Bool = false,
    appearancePreference: AppearancePreference = .system,
    quickAdd: QuickAddMenuState = .nothingSelected,
    quickAddShortcut: String? = "\u{2303}\u{2325} W"
  ) -> MenuBarViewState {
    MenuBarViewState(
      quickAddShortcut: quickAddShortcut,
      quickAdd: quickAdd,
      pipelineState: pipelineState,
      asrLabel: "Parakeet v3",
      llmLabel: "LLM Deactivated",
      onboardingComplete: onboardingComplete,
      vadAutoStop: vadAutoStop,
      vadSilenceTimeout: 2.0,
      showAccessibilityWarning: showAccessibilityWarning,
      hasUpdater: hasUpdater,
      updateAvailable: updateAvailable,
      updateDisplayVersion: updateDisplayVersion,
      installEnabled: installEnabled,
      appearancePreference: appearancePreference
    )
  }

  private func makeController(spy: ActionSpy = ActionSpy()) -> MenuBarController {
    let asrManager = ASRManager(engineMutationScope: .alwaysAllowedForTesting)
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
      settings: settings,
      llmDiscovery: LLMModelDiscoveryCoordinator(keychainManager: KeychainManager()),
      activeModelLoaded: { [weak asrManager] in asrManager?.isModelLoaded ?? false })
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
        // Rendered per CASE rather than through a description, so a refusal reaching the panel is
        // visible in the assertion instead of collapsing into the same string as an empty read.
        addSelectedWord: {
          switch $0 {
          case .text(let t): spy.fired.append("addSelectedWord:\(t)")
          case .noSelection: spy.fired.append("addSelectedWord:<none>")
          case .refused(let why): spy.fired.append("addSelectedWord:refused:\(why.rawValue)")
          }
        },
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

  /// Find by what the item SAYS IT DOES, ignoring the shortcut hint appended to its title.
  ///
  /// The Quick Add row carries its chord as trailing text rather than as a key equivalent (#2412),
  /// so an exact-title lookup finds nothing the moment a binding changes — which is a property of
  /// the test, not of the menu.
  private func itemPrefixed(_ menu: NSMenu, _ prefix: String) -> NSMenuItem? {
    menu.items.first { $0.title.hasPrefix(prefix) }
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

@Suite("Quick Add's menu-bar door (#2412)", .tags(.productOutcome))
@MainActor
struct QuickAddMenuItemTests {
  /// **The title quotes the word, so the user sees WHICH one before spending a click.** The panel
  /// can still correct it; the menu should not be a guess.
  @Test("A readable selection is named in the title, and the item can be chosen")
  func aSelectionIsNamedAndEnabled() {
    let item = MenuBarController.quickAddItem(.ready("clawwed"))
    #expect(item.title == "Add \u{201C}clawwed\u{201D}")
    #expect(item.enabled)
  }

  /// **Disabled rather than enabled-onto-a-refusal.** An item that opens a panel only to report
  /// "nothing selected" spends a click to deliver news the menu already had.
  @Test("Nothing to add leaves the item disabled and generically titled")
  func nothingSelectedIsDisabled() {
    #expect(MenuBarController.quickAddItem(.nothingSelected).title == "Add Selected Word")
    #expect(!MenuBarController.quickAddItem(.nothingSelected).enabled)
    // A `.ready` carrying only whitespace is the same non-event: the reader trims, so this is the
    // belt to that brace rather than a state the reader can actually produce.
    for blank in ["", "   ", "\n\t "] {
      let item = MenuBarController.quickAddItem(.ready(blank))
      #expect(item.title == "Add Selected Word", "for \(blank.debugDescription)")
      #expect(!item.enabled, "for \(blank.debugDescription)")
    }
  }

  /// Whitespace around a real word is trimmed rather than quoted — a selection dragged past a word
  /// boundary is the ordinary case, not an edge one.
  @Test("Surrounding whitespace does not reach the title")
  func whitespaceIsTrimmed() {
    #expect(MenuBarController.quickAddItem(.ready("  clawwed \n")).title == "Add \u{201C}clawwed\u{201D}")
  }

  /// **A selection spanning two lines carries a newline, and a newline in a native menu title
  /// renders as a malformed multi-line row.** Collapsed for DISPLAY only — the original still
  /// reaches the panel, so what gets added is what was selected rather than what fitted in a menu.
  @Test("Internal line breaks and tabs are collapsed for display")
  func internalWhitespaceIsCollapsed() {
    #expect(
      MenuBarController.quickAddItem(.ready("clawwed\nmachine")).title
        == "Add \u{201C}clawwed machine\u{201D}")
    #expect(
      MenuBarController.quickAddItem(.ready("one\ttwo   three")).title
        == "Add \u{201C}one two three\u{201D}")
  }

  /// **A refused read is NOT an empty selection, and collapsing them hid a missing permission.**
  /// With Accessibility off the user HAS selected something and we could not read it; a greyed row
  /// tells them nothing. Enabled, so the panel opens and states the reason.
  @Test("A refused read stays clickable so the panel can say why")
  func aRefusedReadIsNotAnEmptySelection() {
    let blocked = MenuBarController.quickAddItem(.blocked(.accessibilityNotTrusted))
    #expect(blocked.enabled, "the door that must be reliable cannot fail silently")
    #expect(blocked.title == "Add Selected Word")

    // **Every refusal renders the SAME row, and the state still carries which one it was.** The
    // display is deliberately uniform — the panel states the reason, not the menu — but dropping the
    // reason here is what forced the click path to re-read without the menu's cap (PR #2427).
    for why in SelectionReader.Refusal.allCases where why != .accessibilityNotTrusted {
      #expect(MenuBarController.quickAddItem(.blocked(why)) == blocked, "one row for every refusal")
      #expect(
        QuickAddMenuState.blocked(why).selectionResult == .refused(why),
        "and the panel is handed the refusal we measured, not a fresh guess")
    }
    #expect(QuickAddMenuState.nothingSelected.selectionResult == .noSelection)
    #expect(QuickAddMenuState.ready("clawwed").selectionResult == .text("clawwed"))

    let empty = MenuBarController.quickAddItem(.nothingSelected)
    #expect(!empty.enabled, "and genuinely nothing selected is still inert")
    #expect(
      blocked.title == empty.title,
      "the titles match; it is the ENABLED state that separates them, which is the whole finding")
  }

  /// **Cutting on scalars can land inside a character.** A family emoji is several scalars and one
  /// glyph; splitting it renders as rubble.
  @Test("Truncation never splits a character")
  func truncationRespectsGraphemes() {
    let families = String(repeating: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", count: 40)
    let title = MenuBarController.quickAddItem(.ready(families)).title

    #expect(title.hasSuffix("\u{2026}\u{201D}"))
    // Every character between the quotes is a whole family, never a fragment of one.
    let inner = title.dropFirst(5).dropLast(2)
    #expect(
      inner.allSatisfy { $0 == "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}" },
      "a split grapheme would appear here as a lone person or a stray joiner: \(inner)")
    #expect(
      title.unicodeScalars.count <= MenuBarController.quickAddTitleScalars + 7,
      "and the scalar ceiling still bounds the pathological case")
  }

  /// **The reader admits 512 scalars and a menu is not where 512 characters belong.** This bounds
  /// the TITLE only; the panel still receives and can add the whole selection.
  @Test("A long selection is truncated for display, with an ellipsis")
  func aLongSelectionIsTruncated() {
    let long = String(repeating: "a", count: 200)
    let item = MenuBarController.quickAddItem(.ready(long))

    #expect(item.enabled)
    #expect(item.title.hasSuffix("\u{2026}\u{201D}"), "the user is told it was cut")
    #expect(
      item.title.count == MenuBarController.quickAddTitleCharacters + 7,
      "`Add ` is four characters, plus two quotes and the ellipsis")
  }

  /// A selection exactly at the boundary is NOT truncated — the paired case, without which the row
  /// above passes for a truncation that fires one scalar early.
  @Test("A selection exactly at the display limit keeps all of it")
  func theBoundaryIsNotTruncated() {
    let exact = String(repeating: "a", count: MenuBarController.quickAddTitleCharacters)
    let item = MenuBarController.quickAddItem(.ready(exact))

    #expect(!item.title.contains("\u{2026}"))
    #expect(item.title == "Add \u{201C}\(exact)\u{201D}")
  }
}

/// Records which `MenuBarActions` closure fired, in order.
@MainActor
final class ActionSpy {
  var fired: [String] = []
}
