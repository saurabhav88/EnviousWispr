import AppKit
import EnviousWisprCore
import EnviousWisprServices
import Foundation

/// PR-B.3 of #763 — App-owned home for the menu bar surface: the
/// `NSStatusItem`, the dropdown menu, the animated icon, the `NSMenuDelegate`
/// conformance, and the five menu actions. Extracted from `AppDelegate` so the
/// AppKit adapter shrinks toward its ≤120-line target.
///
/// Strong owner is `EnviousWisprApp` as `@State`; `AppDelegate` holds a weak
/// ref pushed via `attach(...)`. Not environment-injected — no SwiftUI view
/// consumes the menu surface.
///
/// Menu rendering and icon mapping are PURE functions over a `MenuBarViewState`
/// value (`renderMenu(into:state:)`, `iconState(_:)`). The impure
/// `currentViewState()` reads the live homes; the split makes the menu surface
/// deterministically golden-testable (`LiveRecordingState` / `PermissionsService`
/// are `final` with `private(set)` state and cannot be posed in a unit test).
@MainActor
final class MenuBarController: NSObject {
  /// Private collaborator — moved from `AppDelegate` unchanged.
  private let iconAnimator = MenuBarIconAnimator()

  /// Narrow read dependencies — all PR11-survivors, injected at construction.
  /// This home reads display facts only through these refs — never through the
  /// frozen god-object the epic is deleting.
  private let liveRecordingState: LiveRecordingState
  private let backendMetadata: BackendMetadata
  private let sparkleUpdateController: SparkleUpdateController
  private let settings: SettingsManager
  private let permissions: PermissionsService

  /// Menu action callbacks, packaged into one `Sendable` struct.
  private let actions: MenuBarActions

  /// The status item. `var` Optional — created in `installStatusItem()`.
  private var statusItem: NSStatusItem?

  init(
    liveRecordingState: LiveRecordingState,
    backendMetadata: BackendMetadata,
    sparkleUpdateController: SparkleUpdateController,
    settings: SettingsManager,
    permissions: PermissionsService,
    actions: MenuBarActions
  ) {
    self.liveRecordingState = liveRecordingState
    self.backendMetadata = backendMetadata
    self.sparkleUpdateController = sparkleUpdateController
    self.settings = settings
    self.permissions = permissions
    self.actions = actions
  }

  // MARK: - Status item lifecycle

  /// Create the status item, configure the icon animator, build the menu, and
  /// install the accessibility-change icon-refresh seam. Called once from
  /// `AppDelegate.applicationDidFinishLaunching` (was `setupStatusItem()`).
  func installStatusItem() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    guard let button = statusItem?.button else { return }

    iconAnimator.configure(button: button)

    let menu = NSMenu()
    menu.delegate = self
    statusItem?.menu = menu
    renderMenu(into: menu, state: currentViewState())

    // PR-B.3 of #763: the accessibility-change icon-refresh trigger moves here
    // from `AppDelegate.applicationDidFinishLaunching`. `AppDelegate.swift:228`
    // was the sole assigner of this single-slot closure — a verified 1:1
    // transfer. The owner of the icon owns the trigger.
    permissions.onAccessibilityChange = { [weak self] in self?.updateIcon() }

    // #1019: flip the icon to / from the "update waiting" gold-wave cue the
    // moment availability changes, even with no window or menu open. The
    // coordinator exists by now (startUpdater() ran in
    // applicationWillFinishLaunching, before this didFinishLaunching call).
    sparkleUpdateController.updateCoordinator?.onAvailabilityChange = { [weak self] in
      self?.updateIcon()
    }
    updateIcon()
  }

  // MARK: - Icon

  /// Update the status item icon for the current pipeline / permission state.
  func updateIcon() {
    let state = currentViewState()
    iconAnimator.transition(to: Self.iconState(state))
    // #1019: non-color accessibility affordance for the gold-wave cue.
    statusItem?.button?.setAccessibilityValue(state.updateAvailable ? "Update available" : nil)
  }

  /// Pure icon-state mapping. Logic byte-identical to the pre-PR-B.3
  /// `AppDelegate.updateIcon()`.
  static func iconState(_ state: MenuBarViewState) -> MenuBarIconAnimator.IconState {
    let needsAccessWarning = state.pipelineState == .idle && state.showAccessibilityWarning
    let onboardingIncomplete = !state.onboardingComplete

    if needsAccessWarning || (onboardingIncomplete && state.pipelineState == .idle) {
      return .error
    } else if case .error = state.pipelineState {
      return .error
    } else if state.pipelineState == .recording {
      return .recording
    } else if state.pipelineState == .transcribing || state.pipelineState == .polishing
      || state.pipelineState == .loadingModel
    {
      return .processing
    } else {
      // #1019: idle-with-update variant. Chosen ONLY here, after onboarding /
      // warning / error / recording / processing — so the update cue never
      // overrides a higher-priority state.
      return state.updateAvailable ? .updatePending : .idle
    }
  }

  // MARK: - Menu rendering

  /// Pure menu builder. Fills `menu` from `state`. Logic byte-identical to the
  /// pre-PR-B.3 `AppDelegate.populateMenu(_:)`. Internal (not private) so
  /// `MenuBarControllerTests` can drive it with `MenuBarViewState` fixtures.
  func renderMenu(into menu: NSMenu, state: MenuBarViewState) {
    menu.removeAllItems()

    // Onboarding abort item — shown at the very top when setup is incomplete.
    if !state.onboardingComplete {
      let setupItem = NSMenuItem(
        title: "Setup Required: Continue Setup…",
        action: #selector(continueOnboardingAction),
        keyEquivalent: ""
      )
      setupItem.image = NSImage(
        systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: "Setup required")
      setupItem.target = self
      menu.addItem(setupItem)
      menu.addItem(.separator())
    }

    // #1019: prominent "update waiting" item near the top. Disabled (with a
    // "finish dictating" hint) while dictation is active; the coordinator's
    // install path is guarded too, so this is defense-in-depth, not the sole
    // gate.
    if state.updateAvailable {
      let installTitle: String = {
        guard state.installEnabled else { return "Update ready: finish dictating to install" }
        if let v = state.updateDisplayVersion, !v.isEmpty { return "Update ready: Install v\(v)" }
        return "Update ready: Install"
      }()
      let updateItem = NSMenuItem(
        title: installTitle, action: #selector(installUpdateAction), keyEquivalent: "")
      updateItem.image = NSImage(
        systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: "Install update")
      updateItem.target = self
      updateItem.isEnabled = state.installEnabled
      menu.addItem(updateItem)
      menu.addItem(.separator())
    }

    // Status: ASR model — LLM model
    let statusTitle = "\(state.asrLabel) — \(state.llmLabel)"
    let statusLineItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
    statusLineItem.isEnabled = false
    menu.addItem(statusLineItem)

    // Version
    let versionItem = NSMenuItem(
      title: "Version: \(AppConstants.appVersion)", action: nil, keyEquivalent: "")
    versionItem.isEnabled = false
    menu.addItem(versionItem)

    menu.addItem(.separator())

    // Record / Stop
    let isRecording = state.pipelineState == .recording
    let recordTitle = isRecording ? "Stop Recording" : "Start Recording"
    let recordSymbol = isRecording ? "stop.circle" : "mic.fill"
    let recordDescription = isRecording ? "Stop" : "Record"
    let recordItem = NSMenuItem(
      title: recordTitle, action: #selector(toggleRecordingAction), keyEquivalent: "")
    recordItem.image = NSImage(
      systemSymbolName: recordSymbol, accessibilityDescription: recordDescription)
    recordItem.target = self
    recordItem.isEnabled = !(state.pipelineState.isActive && !isRecording)
    menu.addItem(recordItem)

    // Auto-stop on silence indicator
    if state.vadAutoStop {
      let autoStopTitle =
        isRecording
        ? "Auto-stop: Active (\(String(format: "%.1fs", state.vadSilenceTimeout)) silence)"
        : "Auto-stop on silence: On"
      let autoStopItem = NSMenuItem(title: autoStopTitle, action: nil, keyEquivalent: "")
      autoStopItem.image = NSImage(
        systemSymbolName: "waveform.badge.minus", accessibilityDescription: "Auto-stop on silence")
      autoStopItem.isEnabled = false
      menu.addItem(autoStopItem)
    }

    // Accessibility warning — shown only when paste is unavailable and not dismissed.
    if state.showAccessibilityWarning {
      let warningItem = NSMenuItem(
        title: "Paste disabled — Accessibility required",
        action: #selector(openPermissionsAction),
        keyEquivalent: ""
      )
      warningItem.image = NSImage(
        systemSymbolName: "exclamationmark.shield.fill",
        accessibilityDescription: "Accessibility required")
      warningItem.target = self
      menu.addItem(warningItem)
    }

    menu.addItem(.separator())

    // Settings (opens unified window to Speech Engine tab)
    let settingsItem = NSMenuItem(
      title: "Settings...", action: #selector(openSettingsAction), keyEquivalent: ",")
    settingsItem.image = NSImage(
      systemSymbolName: "gearshape", accessibilityDescription: "Settings")
    settingsItem.target = self
    menu.addItem(settingsItem)

    // Appearance submenu (System / Light / Dark) — checkmark on the current
    // preference. Mirrors the Settings → Appearance picker (#1047).
    let appearanceItem = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
    appearanceItem.image = NSImage(
      systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: "Appearance")
    let appearanceSubmenu = NSMenu()
    for option in AppearancePreference.allCases {
      let title =
        switch option {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
      let item = NSMenuItem(
        title: title, action: #selector(setAppearanceAction(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = option.rawValue
      item.state = option == state.appearancePreference ? .on : .off
      appearanceSubmenu.addItem(item)
    }
    appearanceItem.submenu = appearanceSubmenu
    menu.addItem(appearanceItem)

    // Check for Updates — targets SparkleUpdateController so it can tag the
    // install source as "menu" for telemetry attribution (issue #343).
    // PR-B.1 of #763 retargeted target/action to the controller; PR-B.3
    // preserves that wiring verbatim.
    if state.hasUpdater {
      let updateItem = NSMenuItem(
        title: "Check for Updates…",
        action: #selector(SparkleUpdateController.openUpdateCheckFromMenu(_:)),
        keyEquivalent: "")
      updateItem.image = NSImage(
        systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Update")
      updateItem.target = sparkleUpdateController
      menu.addItem(updateItem)
    }

    menu.addItem(.separator())

    // Quit
    let quitItem = NSMenuItem(
      title: "Quit \(AppConstants.appName)", action: #selector(quitAction), keyEquivalent: "q")
    quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: "Quit")
    quitItem.target = self
    menu.addItem(quitItem)
  }

  /// Snapshot the live homes into a value the pure renderer/mapper consume.
  /// Reads are byte-identical to the pre-PR-B.3 `AppDelegate.populateMenu` /
  /// `updateIcon` reads.
  private func currentViewState() -> MenuBarViewState {
    // #1019: read the pending-update state (non-critical only — critical routes
    // to Sparkle's own UX) and the active-dictation guard.
    let pending: UpdateAvailabilityService.AvailableUpdate? = {
      if case .available(let u) = sparkleUpdateController.updateCoordinator?.service.state ?? .none,
        !u.isCriticalUpdate
      {
        return u
      }
      return nil
    }()
    let dictationActive = liveRecordingState.isDictationActive

    return MenuBarViewState(
      pipelineState: liveRecordingState.pipelineState,
      asrLabel: backendMetadata.modelLabel,
      llmLabel: backendMetadata.llmLabel,
      onboardingComplete: settings.onboardingState == .completed,
      vadAutoStop: settings.vadAutoStop,
      vadSilenceTimeout: settings.vadSilenceTimeout,
      showAccessibilityWarning: permissions.shouldShowAccessibilityWarning,
      hasUpdater: sparkleUpdateController.hasUpdater,
      updateAvailable: pending != nil,
      updateDisplayVersion: pending?.displayVersion,
      installEnabled: pending != nil && !dictationActive,
      appearancePreference: settings.appearancePreference
    )
  }

  // MARK: - Menu actions

  @objc private func continueOnboardingAction() {
    actions.continueOnboarding()
  }

  @objc private func toggleRecordingAction() {
    Task {
      await actions.toggleRecording()
      updateIcon()
    }
  }

  @objc private func openSettingsAction() {
    actions.openSettings()
  }

  /// #1047: set the window-appearance preference from the Appearance submenu.
  /// The `didSet` persists it and the bootstrapper applies it to `NSApp`.
  @objc private func setAppearanceAction(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String,
      let preference = AppearancePreference(rawValue: raw)
    else { return }
    settings.appearancePreference = preference
  }

  @objc private func openPermissionsAction() {
    actions.openPermissions()
  }

  @objc private func quitAction() {
    actions.quit()
  }

  /// #1019: install the waiting update from the menu item. The coordinator
  /// re-checks active dictation before relaunching, so a stale-enabled item
  /// still cannot kill in-flight work.
  @objc private func installUpdateAction() {
    sparkleUpdateController.updateCoordinator?.installFromMenu()
  }
}

// MARK: - NSMenuDelegate

extension MenuBarController: NSMenuDelegate {
  /// Repopulate menu items each time the menu opens so state is fresh.
  /// `NSMenu` delegate methods are always called on the main thread.
  ///
  /// The `menu` parameter is not captured into the `MainActor` closure (that
  /// would be a Swift 6 `sending` data-race: `menu` is task-isolated). Instead
  /// `statusItem?.menu` — the same object, MainActor-isolated — is re-fetched
  /// inside, exactly as the pre-PR-B.3 `AppDelegate.menuNeedsUpdate` did.
  nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
    MainActor.assumeIsolated {
      if let currentMenu = statusItem?.menu {
        renderMenu(into: currentMenu, state: currentViewState())
      }
      updateIcon()
    }
  }
}

/// The five menu-action callbacks, packaged into one `Sendable` struct so the
/// architecture ceiling parser scores them as a single collaborator slot.
struct MenuBarActions: Sendable {
  let continueOnboarding: @MainActor () -> Void
  let openSettings: @MainActor () -> Void
  let openPermissions: @MainActor () -> Void
  let toggleRecording: @MainActor () async -> Void
  let quit: @MainActor () -> Void
}

/// Immutable snapshot the menu and icon render from. Extracting it makes
/// `renderMenu` / `iconState` pure functions over a value, which is what makes
/// the menu surface deterministically golden-testable.
struct MenuBarViewState: Equatable {
  let pipelineState: PipelineState
  let asrLabel: String
  let llmLabel: String
  let onboardingComplete: Bool
  let vadAutoStop: Bool
  let vadSilenceTimeout: Double
  let showAccessibilityWarning: Bool
  let hasUpdater: Bool
  /// #1019: a non-critical update is waiting to install.
  var updateAvailable: Bool = false
  /// #1019: the pending update's display version (e.g. "2.1.4"), for the
  /// dropdown item copy.
  var updateDisplayVersion: String? = nil
  /// #1019: whether install is permitted right now — false whenever dictation
  /// is active (record / load / transcribe / polish), so a relaunch never kills
  /// in-flight work.
  var installEnabled: Bool = false
  /// #1047: current window-appearance preference, for the Appearance submenu checkmark.
  var appearancePreference: AppearancePreference = .system
}
