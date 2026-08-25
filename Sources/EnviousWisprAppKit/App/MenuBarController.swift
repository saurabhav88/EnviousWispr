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
  static func quickAddItem(_ state: QuickAddMenuState) -> (title: String, enabled: Bool) {
    switch state {
    case .nothingSelected:
      return ("Add Selected Word", false)
    case .blocked:
      // **Enabled, and that is the point.** A refused read is not an empty selection: the user has
      // selected something and we could not read it, usually because Accessibility is off. A greyed
      // row tells them nothing, so this one opens the panel, which exists to state the reason. The
      // door that is meant to be the reliable one must not fail silently.
      return ("Add Selected Word", true)
    case .ready(let selection):
      // **A `.ready` carrying only whitespace is the empty case wearing the wrong label.** The
      // reader trims, so this is not a state it can produce — but the type permits it, and a row
      // reading `Add “”` that opens a panel on nothing is worse than an inert one.
      guard !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return ("Add Selected Word", false)
      }
      return (Self.readyTitle(selection), true)
    }
  }

  /// The title for a readable selection.
  private static func readyTitle(_ selection: String) -> String {
    let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
    // **Collapse INTERNAL whitespace, not just the ends.** A selection spanning two document lines
    // carries a newline, and a newline in an `NSMenuItem` title renders as a malformed, multi-line
    // row. Tabs and runs of spaces are the same problem, one character over.
    //
    // **Display only.** `representedObject` still carries the ORIGINAL selection, so what gets added
    // is what the user selected rather than what fitted in a menu — the same separation this cluster
    // has had to relearn three times, where a sentence was composed from a neighbouring value
    // instead of from what the write path was given.
    //
    // Collapsed BEFORE truncating, so the limit counts characters the user can actually see.
    let collapsed = trimmed.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
      .joined(separator: " ")
    // **Truncate on CHARACTERS, not scalars.** A family emoji, a flag, or a letter written as a
    // base plus a combining mark is several scalars and one character; cutting between them renders
    // a broken glyph. The scalar ceiling still bounds the worst case, because a character can carry
    // many scalars — both limits, and the tighter one wins.
    let shown: String = {
      guard collapsed.count > Self.quickAddTitleCharacters
        || collapsed.unicodeScalars.count > Self.quickAddTitleScalars
      else { return collapsed }
      var out = ""
      for character in collapsed {
        guard out.count < Self.quickAddTitleCharacters,
          out.unicodeScalars.count + character.unicodeScalars.count <= Self.quickAddTitleScalars
        else { break }
        out.append(character)
      }
      return out + "\u{2026}"
    }()
    return "Add \u{201C}\(shown)\u{201D}"
  }

  /// The Quick Add chord as READABLE TEXT, or nil when there is nothing sensible to show.
  ///
  /// **Text, never a key equivalent, and two review rounds went into learning why.** A global hotkey
  /// is a PHYSICAL key code registered with the system; a menu key equivalent is a CHARACTER matched
  /// against the active keyboard layout. They coincide on ANSI and diverge on AZERTY or Dvorak — so
  /// an item carrying a key equivalent can respond to a different physical key than the shortcut it
  /// claims to advertise. That is not cosmetic, and it is unique to key equivalents.
  ///
  /// Formatted by `KeySymbols.format`, which is what `HotkeyRecorderView`, `MainWindowView` and
  /// onboarding already use for this same binding, so the menu says exactly what Settings says. Any
  /// residual inaccuracy on an exotic layout is the app-wide one and belongs where that formatter
  /// lives — fixing it HERE alone would make the menu disagree with the Keybinds screen, which is
  /// worse than being consistently approximate.
  static func quickAddShortcutLabel(
    keyCode: UInt16, modifiers: NSEvent.ModifierFlags
  ) -> String? {
    let formatted = KeySymbols.format(keyCode: keyCode, modifiers: modifiers)
    // `nameForKeyCode` falls back to `Key <n>` for anything it does not know, which teaches nothing
    // and looks like a bug. Say nothing instead.
    guard !formatted.isEmpty, !formatted.contains("Key ") else { return nil }
    return formatted
  }

  /// The rendered title: what the item does, then the chord that does it faster.
  ///
  /// Two spaces rather than one, which is the convention AppKit itself uses when a menu title
  /// carries its own trailing hint — a single space reads as part of the sentence.
  static func quickAddTitle(base: String, shortcut: String?) -> String {
    guard let shortcut, !shortcut.isEmpty else { return base }
    return "\(base)  \(shortcut)"
  }

  /// How much of the selection the title shows. Not a limit on what can be ADDED — the reader's
  /// ceiling is that — only on what fits a menu without pushing the rest of it off screen.
  ///
  /// TWO limits, because they bound different things. Characters are what the user counts;
  /// scalars bound the pathological case where a handful of characters carry hundreds of scalars.
  /// How long the menu will wait for the frontmost application to answer.
  ///
  /// Longer than any healthy Accessibility read, shorter than a user tolerates a menu not opening.
  static let quickAddReadTimeout: Float = 0.5

  static let quickAddTitleCharacters = 24
  static let quickAddTitleScalars = 96

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
    let quickAdd = Self.quickAddItem(state.quickAdd)
    // **No key equivalent, deliberately** — see `quickAddShortcutLabel`. The chord rides in the
    // title as text, so the menu teaches the fast path without registering a second way to fire it.
    let quickAddItem = NSMenuItem(
      title: Self.quickAddTitle(base: quickAdd.title, shortcut: state.quickAddShortcut),
      action: #selector(addSelectedWordAction), keyEquivalent: "")
    // **Cleared explicitly, because AppKit does not default it to empty.** A fresh `NSMenuItem`
    // carries `.command` in its mask whatever its key equivalent is — measured, 1048576 — so leaving
    // it means the item is one future `keyEquivalent` assignment away from silently claiming a ⌘
    // chord nobody chose. Found by a test asserting the item carries no chord at all.
    quickAddItem.keyEquivalentModifierMask = []
    quickAddItem.image = NSImage(
      systemSymbolName: "text.badge.plus", accessibilityDescription: "Add selected word")
    quickAddItem.target = self
    quickAddItem.isEnabled = quickAdd.enabled
    // **The selection rides on the ITEM, which is AppKit's own place for it.** A field on the
    // controller would be one value shared by every render, and could drift from the title sitting
    // beside it; this cannot, because they are set together and thrown away together. It also keeps
    // this class off its stored-property ceiling, which refused the field and was right to.
    // Only a READY row carries text. A blocked row is enabled precisely so the panel can state the
    // refusal, and it must reach `begin` with no override so the panel reads the live reason rather
    // than being handed a stale one.
    if case .ready(let selection) = state.quickAdd { quickAddItem.representedObject = selection }
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
  /// **`quickAdd` is a PARAMETER, not a read taken here, and that is deliberate.** This
  /// builder feeds three paths — the initial menu build, every icon refresh, and the menu-open path —
  /// and only the last is licensed to read the world: opening a status menu leaves the user's own
  /// application frontmost (measured twice, #2412), which is exactly what makes the answer theirs.
  /// An Accessibility round trip on an icon refresh would be work nobody asked for, against a
  /// frontmost app that may well be us.
  private func currentViewState(quickAdd: QuickAddMenuState = .nothingSelected) -> MenuBarViewState {
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
      quickAddShortcut: Self.quickAddShortcutLabel(
        keyCode: settings.quickAddKeyCode, modifiers: settings.quickAddModifiers),
      quickAdd: quickAdd,
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
    // A blocked row carries nothing, and passing nil is what lets the panel read the refusal LIVE
    // and say why — rather than repeating a reason captured when the menu was drawn.
    actions.addSelectedWord(sender.representedObject as? String)
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
        //
        // **Bounded, because `menuNeedsUpdate` must be synchronous.** A frontmost application whose
        // Accessibility provider stalls would otherwise hold the main actor and the menu would not
        // open at all. Half a second is longer than any healthy read and shorter than a user waits.
        //
        // All three outcomes are carried. A refusal is NOT an empty selection — collapsing them is
        // what made a missing Accessibility permission look identical to having selected nothing.
        let quickAdd: QuickAddMenuState = {
          switch SelectionReader.read(timeout: Self.quickAddReadTimeout) {
          case .text(let text): return .ready(text)
          case .noSelection: return .nothingSelected
          case .refused: return .blocked
          }
        }()
        renderMenu(into: currentMenu, state: currentViewState(quickAdd: quickAdd))
      }
      updateIcon()
    }
  }
}

/// The menu-action callbacks, packaged into one `Sendable` struct so the
/// architecture ceiling parser scores them as a single collaborator slot.
struct MenuBarActions: Sendable {
  /// Open Quick Add on the text the menu read while the user's own app was still frontmost (#2412).
  let addSelectedWord: @MainActor (String?) -> Void
  let continueOnboarding: @MainActor () -> Void
  let openSettings: @MainActor () -> Void
  let openPermissions: @MainActor () -> Void
  let toggleRecording: @MainActor () async -> Void
  let quit: @MainActor () -> Void
}

/// What the Quick Add row has to say, in the three states a selection read can produce.
///
/// **Three, because a `String?` can only hold two** — and the two it collapsed were "you selected
/// nothing" and "we could not read what you selected", which need opposite treatment. The first is
/// nothing to report; the second is the user's Accessibility permission being off, which is exactly
/// the thing this door exists to be reliable about.
enum QuickAddMenuState: Equatable {
  /// A readable selection. The row names it and can be chosen.
  case ready(String)
  /// The read succeeded and there was nothing selected. Inert.
  case nothingSelected
  /// The read was refused. Enabled, so the panel can state the reason.
  case blocked
}

/// Immutable snapshot the menu and icon render from. Extracting it makes
/// `renderMenu` / `iconState` pure functions over a value, which is what makes
/// the menu surface deterministically golden-testable.
struct MenuBarViewState: Equatable {
  /// The Quick Add chord as readable text, or nil when there is nothing sensible to show (#2412).
  ///
  /// On the state for the same reason as the selection: `renderMenu` is pure over this value, and
  /// reading `settings` inside it would end that.
  let quickAddShortcut: String?

  /// What the Quick Add row has to say (#2412).
  ///
  /// On the state rather than read inside `renderMenu`, which is pure over this value — that purity
  /// is what makes the whole menu surface golden-testable.
  let quickAdd: QuickAddMenuState
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
