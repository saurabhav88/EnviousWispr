import AppKit
import EnviousWisprASR
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
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
  private let iconAnimator = MenuBarIconAnimator()
  private weak var mainWindow: NSWindow?
  private var windowCloseObserver: (any NSObjectProtocol)?

  // PR-A of #763: App-owned homes. `EnviousWisprApp` owns these as `@State`
  // and pushes them into AppDelegate via `attach(...)` synchronously during
  // `EnviousWisprApp.init()`, before any `NSApplicationDelegate` callback
  // fires. Weak refs so AppDelegate is not a retention root.
  private weak var appState: AppState?
  private weak var navigationCoordinator: NavigationCoordinator?
  /// PR-B.1 of #763: App-owned home for the Sparkle integration. Strong
  /// owner is `EnviousWisprApp`'s `@State`. AppDelegate's relationship
  /// is reduced to invoking `startUpdater()` from
  /// `applicationWillFinishLaunching` and gating the menu's
  /// "Check for Updates" item.
  private weak var sparkleUpdateController: SparkleUpdateController?
  // PR7 of #763: weak refs to the two App-owned homes AppDelegate's
  // menu-bar reads now route through. `liveRecordingState` replaces
  // the old `appState.pipelineState` getter; `backendMetadata` replaces
  // `appState.activeModelName` / `appState.activeLLMDisplayName`. Both
  // sunset on the timeline noted at AppState's `attach…` methods.
  private weak var liveRecordingState: LiveRecordingState?
  private weak var backendMetadata: BackendMetadata?
  /// PR9 of #763: the pipeline state-change callback (icon updates,
  /// audio-environment snapshot triggers) lives on the new lifecycle home now.
  /// AppDelegate sets `dictationLifecycleCoordinator.onPipelineStateChange`
  /// in `applicationDidFinishLaunching`. Weak ref — strong owner is
  /// `DictationRuntime` via `EnviousWisprApp`'s `@State`.
  private weak var dictationLifecycleCoordinator: DictationLifecycleCoordinator?
  /// PR10 of #763: the recording-control façade (start hotkey service,
  /// menu-bar toggle). Weak ref — strong owner is `EnviousWisprApp`'s
  /// `@State`. Used by `applicationDidFinishLaunching` (hotkey start) and
  /// the `@objc toggleRecording` menu-bar action.
  private weak var dictationRuntime: DictationRuntime?
  /// PR10 of #763: shared `HotkeyService` owned by `EnviousWisprApp` as
  /// `@State`. AppDelegate calls `.stop()` on termination so the Carbon
  /// hotkey registration is cleaned up before the run loop tears down.
  /// Replaces the pre-PR10 `appState.hotkeyService.stop()` call.
  private weak var hotkeyService: HotkeyService?

  /// PR-A of #763: receive App-owned home refs from `EnviousWisprApp.init()`
  /// before delegate callbacks fire.
  ///
  /// PR7 of #763: additionally receive `liveRecordingState` and
  /// `backendMetadata` for the menu-bar reads.
  ///
  /// PR9 of #763: additionally receive `dictationLifecycleCoordinator` so the
  /// icon-update callback can be installed on the new home (was on AppState
  /// pre-PR9).
  ///
  /// PR-B.1 of #763: replace the `updateCoordinatorHolder` parameter with
  /// `sparkleUpdateController`. AppDelegate no longer owns the holder ref —
  /// the controller does, and the controller publishes into it from
  /// `startUpdater()`.
  func attach(
    appState: AppState,
    navigationCoordinator: NavigationCoordinator,
    sparkleUpdateController: SparkleUpdateController,
    liveRecordingState: LiveRecordingState,
    backendMetadata: BackendMetadata,
    dictationLifecycleCoordinator: DictationLifecycleCoordinator,
    dictationRuntime: DictationRuntime,
    hotkeyService: HotkeyService
  ) {
    self.appState = appState
    self.navigationCoordinator = navigationCoordinator
    self.sparkleUpdateController = sparkleUpdateController
    self.liveRecordingState = liveRecordingState
    self.backendMetadata = backendMetadata
    self.dictationLifecycleCoordinator = dictationLifecycleCoordinator
    self.dictationRuntime = dictationRuntime
    self.hotkeyService = hotkeyService
  }

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

  /// Issue #739: instantiate the Sparkle updater + update-banner coordinator
  /// BEFORE SwiftUI mounts the App's scenes. PR-B.1 of #763 moves the body
  /// into `SparkleUpdateController.startUpdater()`; this method now only
  /// forwards. Loud nil-guard (not silent optional chain): if the weak ref
  /// is nil at this point, debug crashes with `assertionFailure` and
  /// release logs the skip — the update mechanism must never silently
  /// dormant.
  func applicationWillFinishLaunching(_ notification: Notification) {
    guard let controller = sparkleUpdateController else {
      assertionFailure(
        "SparkleUpdateController must be attached before applicationWillFinishLaunching fires."
      )
      Task {
        await AppLogger.shared.log(
          "Sparkle startup skipped: controller ref is nil. Update banner will not render this session.",
          level: .info,
          category: "AppDelegate"
        )
      }
      return
    }
    controller.startUpdater()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    // PR-A: appState is App-owned; we hold a weak ref attached during
    // EnviousWisprApp.init() (before any delegate callback fires).
    guard let appState = self.appState else { return }
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

    // Issue #739 / PR-B.1 of #763: Sparkle updater, update coordinator, and
    // cross-launch correlation all live on `SparkleUpdateController` now and
    // are invoked from `applicationWillFinishLaunching` so SwiftUI's env
    // value snapshot is non-nil when the App body first evaluates.

    setupStatusItem()

    // Update menu bar icon whenever pipeline state or accessibility changes.
    // Also forwards recording state to the update coordinator so the banner
    // hides during recording + 3s post-recording grace (issue #343).
    // PR9 of #763: callback lives on `DictationLifecycleCoordinator` now.
    dictationLifecycleCoordinator?.onPipelineStateChange = { [weak self] state in
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
    // PR10 of #763 — façade pass-through; HotkeyController owns the
    // `settings.hotkeyEnabled` gate and the `hotkeyService.start()` call.
    dictationRuntime?.startHotkeyServiceIfEnabled()

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
            self?.appState?.settings.selectedBackend ?? .parakeet
          }
        )
        endpoint.start()
        debugFaultEndpoint = endpoint
      }
    #endif

    audioEnvironmentSnapshotter = AudioEnvironmentSnapshotter(
      routeProvider: { [weak self] in
        self?.appState?.audioCapture.currentAudioRoute
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
      pipelineStateProvider: { [weak self] in
        // PR7 of #763: pipeline phase resolves through LiveRecordingState.
        self?.liveRecordingState?.pipelineState ?? .idle
      },
      onAudioDeviceEvent: { [weak self] in
        self?.audioEnvironmentSnapshotter?.audioDeviceEventOccurred()
      }
    )
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    audioEnvironmentSnapshotter?.applicationBecameActive()

    // Re-warm LLM backend when app comes to foreground.
    guard let appState = self.appState else { return }
    LLMNetworkSession.shared.preWarmModel(
      provider: appState.settings.llmProvider,
      model: appState.settings.llmModel,
      keychainManager: appState.keychainManager
    )
  }

  // MARK: - Onboarding Window

  /// Open the onboarding window and begin monitoring for early close (abort flow).
  func openOnboardingWindow() {
    guard let appState = self.appState else { return }
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
          if self.appState?.settings.onboardingState != .completed {
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
    iconAnimator.audioLevelProvider = { [weak self] in self?.appState?.audioCapture.audioLevel ?? 0
    }

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

    guard let appState = self.appState else { return }
    // PR7 of #763: live pipeline phase + display labels now resolve through
    // App-owned homes attached during `EnviousWisprApp.init()`. Fall back
    // to `.idle` / empty strings if a home is unavailable (only possible
    // during very-early teardown — never on a live path).
    let state = liveRecordingState?.pipelineState ?? .idle
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
    // PR7 of #763: display labels resolve through `backendMetadata`. Fall
    // back to empty strings if the home is unavailable (defensive only).
    let asrModel = backendMetadata?.modelLabel ?? ""
    let llmInfo = backendMetadata?.llmLabel ?? ""
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

    // Check for Updates — retargets to SparkleUpdateController so it can
    // tag the install source as "menu" for telemetry attribution (issue #343).
    // PR-B.1 of #763: target/action both moved to the controller.
    if sparkleUpdateController?.hasUpdater == true {
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
      title: "Quit \(AppConstants.appName)", action: #selector(quitApp), keyEquivalent: "q")
    quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: "Quit")
    quitItem.target = self
    menu.addItem(quitItem)
  }

  /// Update the status item icon based on pipeline state.
  func updateIcon() {
    guard let appState = self.appState else { return }
    // PR7 of #763: live pipeline phase resolves through `liveRecordingState`.
    let state = liveRecordingState?.pipelineState ?? .idle
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
    // PR10 of #763 — façade pass-through to RecordingStarter via DictationRuntime.
    guard let dictationRuntime = self.dictationRuntime else { return }
    Task {
      await dictationRuntime.toggleRecording(source: .menuBar)
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
    navigationCoordinator?.request(.speechEngine)
    showWindow()
  }

  @objc private func openPermissionsSettings() {
    navigationCoordinator?.request(.permissions)
    showWindow()
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
    appState?.setup.ollamaSetup.cleanup()
    // PR10 of #763 — shared HotkeyService is owned by EnviousWisprApp as
    // `@State`; AppDelegate holds a weak ref pushed via `attach(...)`.
    hotkeyService?.stop()
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
