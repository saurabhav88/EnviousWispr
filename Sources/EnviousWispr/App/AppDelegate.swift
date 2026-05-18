import AppKit
import EnviousWisprASR
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
@preconcurrency import Sparkle
import SwiftUI

// Issue #574: `EnviousWisprAudio` and `EnviousWisprASR` were previously
// DEBUG-only here for `DebugFaultEndpoint`. They are now needed in release
// builds too because `AudioSystemEventReporter` (production telemetry)
// references `AudioCaptureInterface` and `ASRManagerInterface` types from
// those modules.

#if DEBUG
  import EnviousWisprPipeline
#endif

/// AppDelegate that manages the menu bar status item using NSStatusItem.
///
/// SwiftUI's MenuBarExtra has known click-routing issues when launched
/// outside Xcode or as a bare binary. NSStatusItem is the battle-tested
/// native approach that reliably handles clicks on all macOS versions.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var statusItem: NSStatusItem?
  private(set) var updaterController: SPUStandardUpdaterController?
  private(set) var updateCoordinator: UpdateCoordinator?
  /// Issue #739: stable env-carrier — non-optional `@Observable` holder
  /// whose `coordinator` property is set once the AppDelegate finishes init.
  /// SwiftUI captures THIS instance in env; the inner coordinator flip
  /// (nil → non-nil) triggers re-evaluation of dependent views.
  let updateCoordinatorHolder = UpdateCoordinatorHolder()
  private let iconAnimator = MenuBarIconAnimator()
  private weak var mainWindow: NSWindow?
  private var windowCloseObserver: (any NSObjectProtocol)?

  /// Shared app state — created here so it's available before any SwiftUI scene loads.
  let appState = AppState()

  /// Owns the "open this settings tab next" handoff for menu actions and in-app shortcuts.
  let navigationCoordinator = NavigationCoordinator()

  /// Callback set by SwiftUI to open the main window (since openWindow env is only available in views).
  var openMainWindowAction: (() -> Void)?

  /// Callback set by SwiftUI to open the onboarding window.
  var openOnboardingAction: (() -> Void)?

  /// Callback set by SwiftUI to dismiss the onboarding window (state-driven).
  var dismissOnboardingAction: (() -> Void)?

  /// Weak reference to the onboarding window so we can detect when user closes it early.
  private weak var onboardingWindow: NSWindow?
  private var onboardingCloseObserver: (any NSObjectProtocol)?

  #if DEBUG
    /// V2 fault-injection control surface (issue #291). Started only when
    /// `EW_FAULT_INJECTION=1` is set in the launching environment. Stopped in
    /// `applicationWillTerminate`. Compiled out of release entirely.
    private var debugFaultEndpoint: DebugFaultEndpoint?
  #endif

  /// Production telemetry observer for OS-level audio events (issue #574).
  /// Sentry breadcrumb on every fire; PostHog event on fire-during-recording.
  /// Constructed in `applicationDidFinishLaunching` after AppState is ready;
  /// torn down in `applicationWillTerminate` for clean observer removal.
  private var audioSystemEventReporter: AudioSystemEventReporter?
  private var audioEnvironmentSnapshotter: AudioEnvironmentSnapshotter?

  /// Issue #739: instantiate the updater + update-banner coordinator BEFORE
  /// SwiftUI mounts the App's scenes. SwiftUI snapshots the env value
  /// `\.updateCoordinator` (bound to `appDelegate.updateCoordinator` in
  /// `EnviousWisprApp.swift`) when the scene body is first evaluated, and
  /// that snapshot is final — the App struct's `@State` doesn't change, so
  /// SwiftUI never re-fetches. If we wait until `applicationDidFinishLaunching`,
  /// the env value is nil forever and the banner never renders.
  func applicationWillFinishLaunching(_ notification: Notification) {
    updaterController = SPUStandardUpdaterController(
      startingUpdater: true,
      updaterDelegate: self,
      userDriverDelegate: self
    )
    updateCoordinator = UpdateCoordinator(updaterController: updaterController)
    // Issue #739: publish the coordinator into the @Observable holder so any
    // SwiftUI view bound to the holder's env value sees the flip from nil to
    // non-nil and re-renders. The holder itself is created inline as a stable
    // stored property, so SwiftUI's first env capture is non-nil.
    updateCoordinatorHolder.coordinator = updateCoordinator
    // Cross-launch correlation runs here (was in didFinishLaunching) so the
    // attribution event fires before any UI is shown.
    evaluateUpdateInstallAttemptOnLaunch()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Hide dock icon on launch — we're a menu bar utility.
    // If onboarding is needed, stay .regular so SwiftUI creates the main window hierarchy
    // and ActionWirer can wire callbacks before opening the onboarding window.
    if appState.settings.onboardingState == .completed {
      NSApp.setActivationPolicy(.accessory)
    }

    // Issue #445: launch-time telemetry callback wiring. Single line, no
    // AppState collaborator growth. ASRManagerProxy/ASRManager fire this
    // closure from inside `loadModelSilently()` so the launch-warming path
    // (previously silent on success by design) becomes visible in PostHog.
    ASRManagerProxy.launchPreloadReporter = { backend, result, durationMs in
      Task { @MainActor in
        TelemetryService.shared.launchModelPreloadCompleted(
          backend: backend, result: result, durationMs: durationMs)
      }
    }
    ASRManager.launchPreloadReporter = { backend, result, durationMs in
      Task { @MainActor in
        TelemetryService.shared.launchModelPreloadCompleted(
          backend: backend, result: result, durationMs: durationMs)
      }
    }

    // When the unified window closes, revert to .accessory immediately.
    // There's only one window now, so no need for the 200ms re-check delay.
    // Store token so we can remove on termination (H11 observer leak fix).
    windowCloseObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let window = notification.object as? NSWindow else { return }
      MainActor.assumeIsolated {
        guard let self else { return }
        // Capture the main window reference on first titled window appearance.
        if self.mainWindow == nil, window.styleMask.contains(.titled),
          window.title == AppConstants.appName
        {
          self.mainWindow = window
        }
        // Match by identity so status-bar/panel windows never trigger the reset.
        guard window === self.mainWindow else { return }
        NSApp.setActivationPolicy(.accessory)
      }
    }

    // Issue #739: updaterController + updateCoordinator + cross-launch
    // correlation moved to applicationWillFinishLaunching so SwiftUI's env
    // value snapshot is non-nil when the App body first evaluates.

    setupStatusItem()

    // Update menu bar icon whenever pipeline state or accessibility changes.
    // Also forwards recording state to the update coordinator so the banner
    // hides during recording + 3s post-recording grace (issue #343).
    appState.onPipelineStateChange = { [weak self] state in
      guard let self else { return }
      self.updateIcon()
      // Issue #739: do NOT forward pipeline state to the update widget. The
      // widget is now bundle-version-driven only — visible whenever an update
      // is pending, period. Matches Claude Desktop / Slack / Cursor update-prompt
      // conventions (no auto-hide during active work).
      if state == .recording {
        self.audioEnvironmentSnapshotter?.recordingStarted()
      }
    }
    appState.permissions.onAccessibilityChange = { [weak self] in
      self?.updateIcon()
    }

    // Start hotkeys now that the event loop is running.
    // Carbon RegisterEventHotKey requires an active run loop for event delivery.
    appState.startHotkeyServiceIfEnabled()

    if appState.settings.onboardingState == .completed {
      let s = appState.settings
      let hasKeys =
        (try? appState.keychainManager.retrieve(key: KeychainManager.openAIKeyID)) != nil
        || (try? appState.keychainManager.retrieve(key: KeychainManager.geminiKeyID)) != nil
      TelemetryService.shared.settingsSnapshot(
        asrBackend: s.selectedBackend.rawValue,
        llmProvider: s.llmProvider.rawValue,
        recordingMode: s.recordingMode.rawValue,
        fillerRemoval: s.fillerRemovalEnabled,
        customWordsCount: appState.customWordsCoordinator.customWords.count,
        hasApiKeys: hasKeys,
        noiseSuppression: s.noiseSuppression
      )
    }

    // Run Apple Intelligence diagnostics via coordinator.
    // Handles: Sentry context, PostHog event, persistence, first-launch re-check.
    let isFreshInstall = appState.settings.onboardingState != .completed
    if isFreshInstall {
      appState.aiAvailability.firstLaunchCheck()
    } else {
      Task { await appState.aiAvailability.checkAvailability(trigger: "app_launch") }
    }

    // Fire structured app.launched event — uses cached report (loaded from UserDefaults in coordinator init).
    // No async wait needed — cached snapshot is available synchronously.
    let version =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    let osVer = ProcessInfo.processInfo.operatingSystemVersion
    let cachedReport = appState.aiAvailability.latestReport
    TelemetryService.shared.appLaunched(
      version: version,
      build: build,
      osVersion: "\(osVer.majorVersion).\(osVer.minorVersion).\(osVer.patchVersion)",
      hardware: cachedReport?.hardwareClass ?? "unknown",
      isFreshInstall: isFreshInstall,
      aiAvailable: cachedReport?.overallStatus == .available
    )

    // Check Accessibility permission on launch (query only — never auto-prompt).
    appState.permissions.refreshOnLaunch()
    updateIcon()  // Reflect accessibility warning state in menu bar icon

    // Begin smart polling if Accessibility is not yet granted.
    appState.permissions.startMonitoring()

    // Pre-warm LLM backend with a real inference request.
    LLMNetworkSession.shared.preWarmModel(
      provider: appState.settings.llmProvider,
      model: appState.settings.llmModel,
      keychainManager: appState.keychainManager
    )

    // Onboarding auto-open is handled by ActionWirer inside the main Window scene.
    // ActionWirer wires all callbacks first, then calls openOnboardingWindow() if needed.
    // No deferred dispatch required here.

    #if DEBUG
      // V2 fault-injection (issue #291). Only when explicitly opted in via env var.
      if DebugFaultEndpoint.isRequested {
        let endpoint = DebugFaultEndpoint(
          audioProxy: appState.audioCapture as? AudioCaptureProxy,
          asrProxy: appState.asrManager as? ASRManagerProxy,
          parakeetPipeline: appState.pipeline,
          whisperKitPipeline: appState.whisperKitPipeline,
          activeBackend: { [weak self] in
            self?.appState.settings.selectedBackend ?? .parakeet
          }
        )
        endpoint.start()
        debugFaultEndpoint = endpoint
      }
    #endif

    audioEnvironmentSnapshotter = AudioEnvironmentSnapshotter(
      routeProvider: { [weak appState = self.appState] in
        appState?.audioCapture.currentAudioRoute
      }
    )
    SentryBreadcrumb.audioEnvironmentProvider = { [weak self] in
      self?.audioEnvironmentSnapshotter?.latestForError()
    }

    // Production telemetry: OS-level audio events (issue #574). Always on in
    // release; ships to all users so we get cross-user data on what real
    // devices/routes/connections users actually hit.
    audioSystemEventReporter = AudioSystemEventReporter(
      audioCapture: appState.audioCapture,
      asrManager: appState.asrManager,
      pipelineStateProvider: { [weak appState = self.appState] in
        appState?.pipelineState ?? .idle
      },
      onAudioDeviceEvent: { [weak self] in
        self?.audioEnvironmentSnapshotter?.audioDeviceEventOccurred()
      }
    )
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    audioEnvironmentSnapshotter?.applicationBecameActive()

    // Re-warm LLM backend when app comes to foreground.
    LLMNetworkSession.shared.preWarmModel(
      provider: appState.settings.llmProvider,
      model: appState.settings.llmModel,
      keychainManager: appState.keychainManager
    )
  }

  // MARK: - Onboarding Window

  /// Open the onboarding window and begin monitoring for early close (abort flow).
  func openOnboardingWindow() {
    guard appState.settings.onboardingState != .completed else { return }
    openOnboardingAction?()
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    // Hide the main window so only the onboarding window is visible during setup.
    if let mainWin = self.mainWindow {
      mainWin.orderOut(nil)
    }

    // Capture the onboarding NSWindow by identity on first open.
    // We defer one run-loop cycle so SwiftUI has time to create/order the window
    // before we search NSApp.windows.
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      // SwiftUI Window(id: "onboarding") sets the title to the scene name ("Setup").
      // We capture by identity here so the close observer can match by reference,
      // not by title — title matching would fail if the scene name ever changes.
      if self.onboardingWindow == nil {
        self.onboardingWindow = NSApp.windows.first {
          $0.title == AppConstants.onboardingWindowTitle
        }
      }
      // Ensure the window is visible — openWindow(id:) is a silent no-op when
      // reopening a single-instance Window scene that was previously dismissed.
      self.onboardingWindow?.makeKeyAndOrderFront(nil)
    }

    // Monitor for user closing the onboarding window before completion.
    // Match by window identity (captured above), not by title string.
    if onboardingCloseObserver == nil {
      onboardingCloseObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification,
        object: nil,
        queue: .main
      ) { [weak self] notification in
        guard let window = notification.object as? NSWindow else { return }
        MainActor.assumeIsolated {
          guard let self else { return }
          // Match by captured identity; fall back to title if not yet captured.
          let isOnboardingWindow =
            (self.onboardingWindow != nil)
            ? window === self.onboardingWindow
            : window.title == AppConstants.onboardingWindowTitle
          guard isOnboardingWindow else { return }
          self.onboardingWindow = nil
          // Only treat as abort if onboarding not yet completed.
          if self.appState.settings.onboardingState != .completed {
            self.updateIcon()
          }
        }
      }
    }
  }

  /// Called by the onboarding Done button via the onComplete callback.
  /// State-driven: flips isOnboardingPresented to false, ActionWirer's onChange dismisses the window.
  func closeOnboardingWindow() {
    dismissOnboardingAction?()
    NSApp.setActivationPolicy(.accessory)
    updateIcon()
  }

  private func setupStatusItem() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    guard let button = statusItem?.button else { return }

    iconAnimator.configure(button: button)
    iconAnimator.audioLevelProvider = { [weak self] in self?.appState.audioCapture.audioLevel ?? 0 }

    let menu = NSMenu()
    menu.delegate = self
    statusItem?.menu = menu
    populateMenu(menu)
  }

  /// Load a menu bar icon from the app bundle's Resources directory.
  /// At runtime the bundle is a proper .app with Contents/Resources/;
  /// during development we fall back to the source Resources/ directory.
  ///
  /// Resolution order:
  ///   1. Bundle.main.resourceURL  (production .app bundle)
  ///   2. Derived from executable path (fallback when Bundle.main mis-resolves)
  ///   3. Source tree via #filePath (development / bare binary)
  ///   4. SF Symbol "mic" (last resort)
  /// Populate the given menu with items reflecting current AppState.
  private func populateMenu(_ menu: NSMenu) {
    menu.removeAllItems()

    let state = appState.pipelineState
    let onboardingIncomplete = appState.settings.onboardingState != .completed

    // Onboarding abort item — shown at the very top when setup is incomplete.
    if onboardingIncomplete {
      let setupItem = NSMenuItem(
        title: "Setup Required: Continue Setup…",
        action: #selector(continueOnboarding),
        keyEquivalent: ""
      )
      setupItem.image = NSImage(
        systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: "Setup required")
      setupItem.target = self
      menu.addItem(setupItem)
      menu.addItem(.separator())
    }

    // Status: ASR model — LLM model
    let asrModel = appState.activeModelName
    let llmInfo = appState.activeLLMDisplayName
    let statusTitle = "\(asrModel) — \(llmInfo)"
    let statusItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
    statusItem.isEnabled = false
    menu.addItem(statusItem)

    // Version
    let versionItem = NSMenuItem(
      title: "Version: \(AppConstants.appVersion)", action: nil, keyEquivalent: "")
    versionItem.isEnabled = false
    menu.addItem(versionItem)

    menu.addItem(.separator())

    // Record / Stop
    let recordTitle = state == .recording ? "Stop Recording" : "Start Recording"
    let recordSymbol = state == .recording ? "stop.circle" : "mic.fill"
    let recordDescription = state == .recording ? "Stop" : "Record"
    let recordItem = NSMenuItem(
      title: recordTitle, action: #selector(toggleRecording), keyEquivalent: "")
    recordItem.image = NSImage(
      systemSymbolName: recordSymbol, accessibilityDescription: recordDescription)
    recordItem.target = self
    recordItem.isEnabled = !(state.isActive && state != .recording)
    menu.addItem(recordItem)

    // Auto-stop on silence indicator
    if appState.settings.vadAutoStop {
      let autoStopTitle =
        state == .recording
        ? "Auto-stop: Active (\(String(format: "%.1fs", appState.settings.vadSilenceTimeout)) silence)"
        : "Auto-stop on silence: On"
      let autoStopItem = NSMenuItem(title: autoStopTitle, action: nil, keyEquivalent: "")
      autoStopItem.image = NSImage(
        systemSymbolName: "waveform.badge.minus", accessibilityDescription: "Auto-stop on silence")
      autoStopItem.isEnabled = false
      menu.addItem(autoStopItem)
    }

    // Accessibility warning — shown only when paste is unavailable and not dismissed.
    if appState.permissions.shouldShowAccessibilityWarning {
      let warningItem = NSMenuItem(
        title: "Paste disabled — Accessibility required",
        action: #selector(openPermissionsSettings),
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
      title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
    settingsItem.image = NSImage(
      systemSymbolName: "gearshape", accessibilityDescription: "Settings")
    settingsItem.target = self
    menu.addItem(settingsItem)

    // Check for Updates — retargeted to AppDelegate wrapper so we can tag
    // the install source as "menu" for telemetry attribution (issue #343).
    if updaterController != nil {
      let updateItem = NSMenuItem(
        title: "Check for Updates…",
        action: #selector(openUpdateCheckFromMenu(_:)), keyEquivalent: "")
      updateItem.image = NSImage(
        systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Update")
      updateItem.target = self
      menu.addItem(updateItem)
    }

    menu.addItem(.separator())

    // Quit
    let quitItem = NSMenuItem(
      title: "Quit \(AppConstants.appName)", action: #selector(quitApp), keyEquivalent: "q")
    quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: "Quit")
    quitItem.target = self
    menu.addItem(quitItem)
  }

  /// Update the status item icon based on pipeline state.
  func updateIcon() {
    let state = appState.pipelineState
    let needsAccessWarning = state == .idle && appState.permissions.shouldShowAccessibilityWarning
    let onboardingIncomplete = appState.settings.onboardingState != .completed

    if needsAccessWarning || (onboardingIncomplete && state == .idle) {
      iconAnimator.transition(to: .error)
    } else if case .error = state {
      iconAnimator.transition(to: .error)
    } else if state == .recording {
      iconAnimator.transition(to: .recording)
    } else if state == .transcribing || state == .polishing || state == .loadingModel {
      iconAnimator.transition(to: .processing)
    } else {
      iconAnimator.transition(to: .idle)
    }
  }

  @objc private func continueOnboarding() {
    openOnboardingWindow()
  }

  @objc private func toggleRecording() {
    Task {
      await appState.toggleRecording(source: .menuBar)
      updateIcon()
    }
  }

  /// Show the unified window: bring it to front, set .regular, activate.
  private func showWindow() {
    if let action = openMainWindowAction {
      action()
    } else {
      // Fallback: find and show an existing window
      for window in NSApp.windows where window.title == AppConstants.appName {
        window.makeKeyAndOrderFront(nil)
        break
      }
    }
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }

  @objc private func openSettings() {
    navigationCoordinator.request(.speechEngine)
    showWindow()
  }

  @objc private func openPermissionsSettings() {
    navigationCoordinator.request(.permissions)
    showWindow()
  }

  /// Issue #343: menu-bar "Check for Updates…" wrapper. Tags the install source
  /// as "menu" so cross-launch correlation can attribute install_completed /
  /// install_cancelled correctly, then forwards to Sparkle's standard handler.
  @objc private func openUpdateCheckFromMenu(_ sender: Any?) {
    updateCoordinator?.lastInstallSource = "menu"
    updaterController?.checkForUpdates(sender)
  }

  /// Issue #343: cross-launch correlation entry point. Called from
  /// applicationDidFinishLaunching after the coordinator is constructed.
  /// Compares the current bundle version to a persisted "we just attempted
  /// to install" marker and fires install_completed / install_cancelled
  /// telemetry. Independent of whether the click-time event made it through.
  private func evaluateUpdateInstallAttemptOnLaunch() {
    guard let coordinator = updateCoordinator else { return }
    let outcome = coordinator.evaluateLastInstallAttempt(
      currentBundleVersion: AppConstants.appVersion
    )
    switch outcome {
    case .completed(let version, let source):
      TelemetryService.shared.updateInstallCompleted(
        version: version, isCritical: false, source: source
      )
    case .cancelled(let version, let source):
      TelemetryService.shared.updateInstallCancelled(
        version: version, isCritical: false, source: source
      )
    case .none, .unattributable, .stale:
      break
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    if let observer = windowCloseObserver {
      NotificationCenter.default.removeObserver(observer)
      windowCloseObserver = nil
    }
    if let observer = onboardingCloseObserver {
      NotificationCenter.default.removeObserver(observer)
      onboardingCloseObserver = nil
    }
    appState.setup.ollamaSetup.cleanup()
    appState.hotkeyService.stop()
    LLMNetworkSession.shared.invalidate()

    #if DEBUG
      debugFaultEndpoint?.stop()
      debugFaultEndpoint = nil
    #endif

    // Issue #574: tear down audio-event observers cleanly.
    audioSystemEventReporter = nil
    SentryBreadcrumb.audioEnvironmentProvider = nil
    audioEnvironmentSnapshotter = nil
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // Menu bar app — keep running when windows close.
    // User quits via "Quit EnviousWispr" in the status bar menu.
    return false
  }

  @objc private func quitApp() {
    NSApp.terminate(nil)
  }
}

// MARK: - NSMenuDelegate

extension AppDelegate: NSMenuDelegate {
  /// Repopulate menu items each time the menu opens so state is fresh.
  /// NSMenu delegate methods are always called on the main thread.
  nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
    MainActor.assumeIsolated {
      if let currentMenu = self.statusItem?.menu {
        self.populateMenu(currentMenu)
      }
      self.updateIcon()
    }
  }
}

// MARK: - SPUStandardUserDriverDelegate

extension AppDelegate: @preconcurrency SPUStandardUserDriverDelegate {
  /// Issue #343: declares support for gentle scheduled update reminders.
  /// Sparkle logs an error if a background app does not declare this.
  /// (sparkle-project.org/documentation/gentle-reminders)
  var supportsGentleScheduledUpdateReminders: Bool { true }

  /// Bring app to front when Sparkle shows an update dialog (LSUIElement fix).
  func standardUserDriverWillShowModalAlert() {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate()
  }

  /// Return to accessory mode when the entire update session ends.
  func standardUserDriverWillFinishUpdateSession() {
    NSApp.setActivationPolicy(.accessory)
  }

  /// Issue #343: pure yes/no decision per Sparkle's documented gentle-reminder
  /// pattern. NO side effects — all state mutation happens in
  /// `standardUserDriverWillHandleShowingUpdate`.
  /// Sparkle's contract: YES = Sparkle handles, NO = delegate handles.
  func standardUserDriverShouldHandleShowingScheduledUpdate(
    _ update: SUAppcastItem,
    andInImmediateFocus immediateFocus: Bool
  ) -> Bool {
    let hasMainWindow = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
    if !hasMainWindow { return true }  // no banner mount → Sparkle handles
    if update.isCriticalUpdate { return true }  // critical → Sparkle's full UX
    if immediateFocus { return true }  // Sparkle wants front-and-center
    return false  // we own the gentle UX via the banner
  }

  /// Issue #343: side-effect callback that fires after the yes/no decision.
  /// Captures availability state into the service and (if Sparkle handles)
  /// tags the install source for telemetry attribution.
  /// Sparkle's contract: handleShowingUpdate == true → Sparkle handles,
  /// false → delegate (us) handles.
  func standardUserDriverWillHandleShowingUpdate(
    _ handleShowingUpdate: Bool,
    forUpdate update: SUAppcastItem,
    state: SPUUserUpdateState
  ) {
    let available = UpdateAvailabilityService.AvailableUpdate(
      versionString: update.versionString,
      displayVersion: update.displayVersionString,
      buildString: update.versionString,
      isCriticalUpdate: update.isCriticalUpdate
    )
    updateCoordinator?.service.noteAvailable(available)

    if handleShowingUpdate {
      // Sparkle owns UX. Tag source + fire diagnostic event.
      let reason: String = {
        if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
          return "no_main_window"
        }
        if update.isCriticalUpdate { return "critical" }
        return "immediate_focus"
      }()
      updateCoordinator?.lastInstallSource = "sparkle_default"
      TelemetryService.shared.updateSparkleDefaultShown(
        version: update.versionString,
        isCritical: update.isCriticalUpdate,
        reason: reason
      )
    }
    // Else: banner owns UX; source set by `triggerInstall` when user clicks.
  }

  /// Issue #739: Sparkle fires this on alert focus AND user choice; it is NOT
  /// a dismissal signal. Widget visibility is governed solely by bundle
  /// version on disk. User engagement with the Sparkle alert does not hide
  /// the widget. Method retained as no-op so Sparkle's delegate conformance
  /// continues to register interest in the callback (needsToObserveUserAttention
  /// gates other Sparkle internals; see SPUStandardUserDriver.m:370).
  func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
  }
}

// MARK: - SPUUpdaterDelegate

extension AppDelegate: SPUUpdaterDelegate {
  /// Issue #343: fires when the user has accepted an update and Sparkle is
  /// about to begin install. Persists the install attempt for cross-launch
  /// correlation, fires `update.install_started`, flushes telemetry so the
  /// event survives Sparkle's relaunch.
  func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
    let source = updateCoordinator?.lastInstallSource ?? "unknown"
    updateCoordinator?.recordInstallAttempt(version: item.versionString, source: source)
    TelemetryService.shared.updateInstallStarted(
      version: item.versionString,
      isCritical: item.isCriticalUpdate,
      source: source
    )
    TelemetryService.shared.flushTelemetry()
  }

  /// Issue #343: silent install-on-quit path. This is a separate Sparkle
  /// driver from `willInstallUpdate` — for automatically-downloaded updates
  /// that install when the user quits. Tag source explicitly so we can
  /// distinguish it from banner / menu / sparkle_default attribution.
  func updater(
    _ updater: SPUUpdater,
    willInstallUpdateOnQuit item: SUAppcastItem,
    immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
  ) -> Bool {
    updateCoordinator?.lastInstallSource = "install_on_quit"
    updateCoordinator?.recordInstallAttempt(version: item.versionString, source: "install_on_quit")
    TelemetryService.shared.updateInstallStarted(
      version: item.versionString,
      isCritical: item.isCriticalUpdate,
      source: "install_on_quit"
    )
    TelemetryService.shared.flushTelemetry()
    // Returning false lets Sparkle's automatic install-on-quit proceed normally.
    return false
  }

  /// Issue #343: terminal "the cycle ended" hook. Fires diagnostic event,
  /// resolves service state, clears install-source.
  func updater(
    _ updater: SPUUpdater,
    didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
    error: (any Error)?
  ) {
    let source = updateCoordinator?.lastInstallSource ?? "unknown"
    let pendingVersion: String? = {
      if case .available(let u) = updateCoordinator?.service.state ?? .none {
        return u.versionString
      }
      return nil
    }()
    let version = pendingVersion ?? "unknown"
    let isCritical: Bool = {
      if case .available(let u) = updateCoordinator?.service.state ?? .none {
        return u.isCriticalUpdate
      }
      return false
    }()
    let errorCode = (error as NSError?).map { "\($0.domain).\($0.code)" }
    TelemetryService.shared.updateSparkleCycleFinished(
      version: version,
      isCritical: isCritical,
      source: source,
      errorCode: errorCode
    )
    if error != nil {
      TelemetryService.shared.updateInstallFailed(
        version: version,
        isCritical: isCritical,
        source: source,
        errorCode: errorCode ?? "unknown"
      )
    }
    // Issue #739: do NOT call noteResolved here. Sparkle's "cycle finished"
    // fires on cancel/skip/error/install-on-quit-scheduled alike. Widget state
    // is cleared only when bundle version catches up (rehydratePendingIfNewer
    // on next launch). In-session, the existing 5s resolvingWatchdog in
    // triggerInstall restores .available if the user clicked the widget but
    // did not complete an install.
    updateCoordinator?.lastInstallSource = nil
  }
}
