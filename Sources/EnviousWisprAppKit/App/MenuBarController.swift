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

    let menu = Self.makeStatusMenu(delegate: self)
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

  /// Build the status-item menu with auto-enabling OFF.
  ///
  /// **Without that, every `isEnabled = false` in `renderMenu` is silently ignored.** `NSMenu`
  /// auto-enables by default: an item with a valid target and action is enabled whatever the
  /// property says, unless the target implements `validateMenuItem`. Nothing here did.
  ///
  /// Found by Live UAT on #2412 — the Quick Add item rendered ENABLED with no selection, which is
  /// the one thing it must never be, while its unit test correctly reported the DECISION as false.
  /// Decision tested, wiring not.
  ///
  /// **It was never only the new item.** `recordItem.isEnabled = !(state.pipelineState.isActive &&
  /// !isRecording)` has been inert for as long as it has existed, so Start Recording stayed
  /// clickable mid-transcription. Turning auto-enabling off makes every one of those assignments
  /// mean what it says.
  ///
  /// A factory rather than two lines inside `installStatusItem`, so the property is assertable
  /// without a test seam, a stored property, or a way to tear the status item back down.
  static func makeStatusMenu(delegate: NSMenuDelegate) -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.delegate = delegate
    return menu
  }

  // MARK: - Menu rendering

  /// What the Quick Add item says, and whether it can be chosen.
  ///
  /// **Disabled with a generic title when there is nothing to add, rather than enabled onto a
  /// refusal.** An item that opens a panel only to say "nothing selected" spends a click to deliver
  /// news the menu already had — and this cluster has produced three separate defects where a
  /// sentence was composed from a neighbouring value rather than from what actually happened.
  ///
  /// Truncated for display. `SelectionReader` admits up to 512 scalars, and a menu item is not where
  /// 512 characters belong; the panel shows the whole thing.
  static func quickAddItem(selection: String?) -> (title: String, enabled: Bool) {
    guard let selection, !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return ("Add Selected Word", false)
    }
    let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
    let shown =
      trimmed.unicodeScalars.count > Self.quickAddTitleScalars
      ? String(String.UnicodeScalarView(trimmed.unicodeScalars.prefix(Self.quickAddTitleScalars)))
        + "\u{2026}"
      : trimmed
    return ("Add \u{201C}\(shown)\u{201D}", true)
  }

  /// The Quick Add chord as a menu key equivalent, or nil when it cannot be shown exactly.
  ///
  /// **The shortcut is user-editable** (`settings.quickAddKeyCode` / `quickAddModifiers`), so a
  /// hard-coded `⌃⌥W` teaches the wrong chord the moment anyone rebinds it — and keeps answering the
  /// old one, because a key equivalent is live rather than decorative.
  ///
  /// **Nil rather than an approximation.** A key equivalent is a CHARACTER plus a mask, which is
  /// narrower than a hotkey: a bare modifier has no character, and neither does an arrow or a
  /// function key. A menu that teaches NOTHING is recoverable; one that teaches a chord the user has
  /// reassigned is not, because they have no reason to doubt it.
  ///
  /// Letters and digits are the representable set, and the shipped default (W) is in it.
  /// `KeySymbols.nameForKeyCode` is the shipped table rather than a second copy of it.
  static func quickAddKeyEquivalent(
    keyCode: UInt16, modifiers: NSEvent.ModifierFlags
  ) -> MenuChord? {
    guard !modifiers.isEmpty, !ModifierKeyCodes.isModifierOnly(keyCode) else { return nil }
    let name = KeySymbols.nameForKeyCode(keyCode)
    guard name.count == 1, let scalar = name.unicodeScalars.first,
      CharacterSet.alphanumerics.contains(scalar), scalar.isASCII
    else { return nil }
    return MenuChord(key: name.lowercased(), modifiers: modifiers)
  }

  /// How much of the selection the title shows. Not a limit on what can be ADDED — the reader's
  /// ceiling is that — only on what fits a menu without pushing the rest of it off screen.
  static let quickAddTitleScalars = 24

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

    // Quick Add (#2412). Beside Start Recording because both act on what the user is doing RIGHT
    // NOW, and above the Settings separator because neither is configuration.
    let quickAdd = Self.quickAddItem(selection: state.quickAddSelection)
    let chord = state.quickAddChord
    let quickAddItem = NSMenuItem(
      title: quickAdd.title, action: #selector(addSelectedWordAction),
      keyEquivalent: chord?.key ?? "")
    // Derived from the user's own binding, and absent when it cannot be represented exactly — see
    // `quickAddKeyEquivalent`. The menu teaches the fast path, which is the discoverability half of
    // this issue, and teaches nothing rather than something false.
    quickAddItem.keyEquivalentModifierMask = chord?.modifiers ?? []
    quickAddItem.image = NSImage(
      systemSymbolName: "text.badge.plus", accessibilityDescription: "Add selected word")
    quickAddItem.target = self
    quickAddItem.isEnabled = quickAdd.enabled
    // **The selection rides on the ITEM, which is AppKit's own place for it.** A field on the
    // controller would be one value shared by every render, and could drift from the title sitting
    // beside it; this cannot, because they are set together and thrown away together. It also keeps
    // this class off its stored-property ceiling, which refused the field and was right to.
    quickAddItem.representedObject = state.quickAddSelection
    menu.addItem(quickAddItem)

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
  /// **`quickAddSelection` is a PARAMETER, not a read taken here, and that is deliberate.** This
  /// builder feeds three paths — the initial menu build, every icon refresh, and the menu-open path —
  /// and only the last is licensed to read the world: opening a status menu leaves the user's own
  /// application frontmost (measured twice, #2412), which is exactly what makes the answer theirs.
  /// An Accessibility round trip on an icon refresh would be work nobody asked for, against a
  /// frontmost app that may well be us.
  private func currentViewState(quickAddSelection: String? = nil) -> MenuBarViewState {
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
    // #2197: ask the coordinator whether an install is refused rather than
    // re-deriving the condition here. Recomputing it locally is what produced an
    // ENABLED Install item the guard then silently swallowed, and reading it from
    // the owner also keeps this file free of a Pipeline import it has no business
    // holding — the architecture guard that refused that import was right.
    let installRefused =
      sparkleUpdateController.updateCoordinator?.installRefusedNow ?? false

    return MenuBarViewState(
      quickAddChord: Self.quickAddKeyEquivalent(
        keyCode: settings.quickAddKeyCode, modifiers: settings.quickAddModifiers),
      quickAddSelection: quickAddSelection,
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
      installEnabled: pending != nil && !installRefused,
      appearancePreference: settings.appearancePreference
    )
  }

  // MARK: - Menu actions

  /// **Reads nothing. The selection was captured when the menu was RENDERED**, while the user's own
  /// application was still frontmost; by the time this fires the menu has closed and a read would be
  /// about us. That ordering is the whole reason this door works.
  @objc private func addSelectedWordAction(_ sender: NSMenuItem) {
    guard let selection = sender.representedObject as? String else { return }
    actions.addSelectedWord(selection)
  }

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
        // The one read, at the one moment it is about the user's document rather than about us.
        let selection: String? = {
          if case .text(let text) = SelectionReader.read() { return text }
          return nil
        }()
        renderMenu(into: currentMenu, state: currentViewState(quickAddSelection: selection))
      }
      updateIcon()
    }
  }
}

/// The menu-action callbacks, packaged into one `Sendable` struct so the
/// architecture ceiling parser scores them as a single collaborator slot.
struct MenuBarActions: Sendable {
  /// Open Quick Add on the text the menu read while the user's own app was still frontmost (#2412).
  let addSelectedWord: @MainActor (String) -> Void
  let continueOnboarding: @MainActor () -> Void
  let openSettings: @MainActor () -> Void
  let openPermissions: @MainActor () -> Void
  let toggleRecording: @MainActor () async -> Void
  let quit: @MainActor () -> Void
}

/// A chord a menu item can actually display: a character plus a modifier mask.
///
/// A named type rather than a tuple because `MenuBarViewState` is `Equatable` and Swift does not
/// synthesise that through a tuple field.
struct MenuChord: Equatable {
  let key: String
  let modifiers: NSEvent.ModifierFlags
}

/// Immutable snapshot the menu and icon render from. Extracting it makes
/// `renderMenu` / `iconState` pure functions over a value, which is what makes
/// the menu surface deterministically golden-testable.
struct MenuBarViewState: Equatable {
  /// The Quick Add chord as a menu key equivalent, or nil when it cannot be shown exactly (#2412).
  ///
  /// On the state for the same reason as the selection: `renderMenu` is pure over this value, and
  /// reading `settings` inside it would end that.
  let quickAddChord: MenuChord?

  /// The selection Quick Add would act on, or nil when there is nothing readable (#2412).
  ///
  /// **Carried on the state rather than read inside `renderMenu`, deliberately.** That function is
  /// pure over this value, which is what makes the entire menu surface golden-testable; a world read
  /// inside it would end that on the surface where a wrong item is most visible.
  let quickAddSelection: String?
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
