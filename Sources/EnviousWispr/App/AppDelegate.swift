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
  // PR-A of #763: App-owned homes. `EnviousWisprApp` owns these as `@State`
  // and pushes them into AppDelegate via `attach(...)` synchronously during
  // `EnviousWisprApp.init()`, before any `NSApplicationDelegate` callback
  // fires. Weak refs so AppDelegate is not a retention root.
  private weak var appState: AppState?
  /// PR-B.1 of #763: App-owned home for the Sparkle integration. Strong
  /// owner is `EnviousWisprApp`'s `@State`. AppDelegate's relationship
  /// is reduced to invoking `startUpdater()` from
  /// `applicationWillFinishLaunching` and gating the menu's
  /// "Check for Updates" item.
  private weak var sparkleUpdateController: SparkleUpdateController?
  /// PR7 of #763: weak ref to the App-owned live-recording home.
  /// `AudioSystemEventReporter.pipelineStateProvider` reads `pipelineState`
  /// from it (see `applicationDidFinishLaunching`). The menu-bar reads that
  /// previously routed through here moved to `MenuBarController` in PR-B.3.
  private weak var liveRecordingState: LiveRecordingState?
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
  /// PR-B.2 of #763: App-owned home for window lifecycle (main + onboarding
  /// window identity, the two `NSWindow.willCloseNotification` observers, the
  /// SwiftUI open/dismiss bridges, activation-policy transitions). Weak ref —
  /// strong owner is `EnviousWisprApp`'s `@State`. AppDelegate routes
  /// `installOnLaunch()` / `tearDown()` from its lifecycle callbacks.
  private weak var appWindowCoordinator: AppWindowCoordinator?
  /// PR-B.3 of #763: App-owned home for the menu bar surface (status item,
  /// dropdown menu, animated icon, menu actions). Weak ref — strong owner is
  /// `EnviousWisprApp`'s `@State`. AppDelegate calls `installStatusItem()`
  /// from launch and routes the three external icon-refresh seams here.
  private weak var menuBarController: MenuBarController?

  /// PR-A of #763: receive App-owned home refs from `EnviousWisprApp.init()`
  /// before delegate callbacks fire.
  ///
  /// PR9 of #763: additionally receive `dictationLifecycleCoordinator` so the
  /// icon-update callback can be installed on the new home (was on AppState
  /// pre-PR9).
  ///
  /// PR-B.1 of #763: replace the `updateCoordinatorHolder` parameter with
  /// `sparkleUpdateController`. AppDelegate no longer owns the holder ref —
  /// the controller does, and the controller publishes into it from
  /// `startUpdater()`.
  ///
  /// PR-B.2 of #763: additionally receive `appWindowCoordinator` so the
  /// lifecycle callbacks can install/tear down the window observers.
  ///
  /// PR-B.3 of #763: additionally receive `menuBarController`; drop
  /// `navigationCoordinator` and `backendMetadata` (both were only read by the
  /// menu code that moved to `MenuBarController`). The `onOnboardingDismissed`
  /// icon-refresh seam now targets `menuBarController`.
  func attach(
    appState: AppState,
    sparkleUpdateController: SparkleUpdateController,
    liveRecordingState: LiveRecordingState,
    dictationLifecycleCoordinator: DictationLifecycleCoordinator,
    dictationRuntime: DictationRuntime,
    hotkeyService: HotkeyService,
    appWindowCoordinator: AppWindowCoordinator,
    menuBarController: MenuBarController
  ) {
    self.appState = appState
    self.sparkleUpdateController = sparkleUpdateController
    self.liveRecordingState = liveRecordingState
    self.dictationLifecycleCoordinator = dictationLifecycleCoordinator
    self.dictationRuntime = dictationRuntime
    self.hotkeyService = hotkeyService
    self.appWindowCoordinator = appWindowCoordinator
    self.menuBarController = menuBarController
    // Icon-refresh seam: the coordinator's two onboarding-dismiss callsites
    // route through this closure. PR-B.3 retargets it to MenuBarController.
    appWindowCoordinator.onOnboardingDismissed = { [weak menuBarController] in
      menuBarController?.updateIcon()
    }
  }

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

    // PR-B.2 of #763: the window-close observer lives on AppWindowCoordinator
    // now. Loud nil-guard, but NOT a method-wide early return — the rest of
    // `applicationDidFinishLaunching` (status item, hotkey start, telemetry,
    // permissions, LLM pre-warm, audio reporters) must always run. Window
    // observation is a limb; app startup is not. Position preserved: same
    // mid-method point the inline observer block occupied before PR-B.2.
    if let appWindowCoordinator {
      appWindowCoordinator.installOnLaunch()
    } else {
      assertionFailure(
        "AppWindowCoordinator must be attached before applicationDidFinishLaunching fires."
      )
      Task {
        await AppLogger.shared.log(
          "Window observer install skipped: coordinator ref is nil. Activation-policy revert on window close will not work this session.",
          level: .info,
          category: "AppDelegate"
        )
      }
    }

    // Issue #739 / PR-B.1 of #763: Sparkle updater, update coordinator, and
    // cross-launch correlation all live on `SparkleUpdateController` now and
    // are invoked from `applicationWillFinishLaunching` so SwiftUI's env
    // value snapshot is non-nil when the App body first evaluates.

    // PR-B.3 of #763: the menu bar surface lives on `MenuBarController` now.
    menuBarController?.installStatusItem()

    // Update menu bar icon whenever pipeline state changes. PR9 of #763: the
    // callback lives on `DictationLifecycleCoordinator`. PR-B.3 of #763: the
    // icon call targets `MenuBarController`. The closure stays here because it
    // is composite — it also triggers the audio-environment snapshotter, which
    // does not move off AppDelegate until PR-B.4.
    dictationLifecycleCoordinator?.onPipelineStateChange = { [weak self] state in
      guard let self else { return }
      self.menuBarController?.updateIcon()
      // Issue #739: do NOT forward pipeline state to the update widget. The
      // widget is now bundle-version-driven only — visible whenever an update
      // is pending, period. Matches Claude Desktop / Slack / Cursor update-prompt
      // conventions (no auto-hide during active work).
      if state == .recording {
        self.audioEnvironmentSnapshotter?.recordingStarted()
      }
    }
    // PR-B.3 of #763: the accessibility-change icon-refresh seam moved into
    // `MenuBarController.installStatusItem()`.

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
    menuBarController?.updateIcon()  // Reflect accessibility warning state in menu bar icon

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

  func applicationWillTerminate(_ notification: Notification) {
    // PR-B.2 of #763: both window-close observers are torn down by the
    // coordinator now.
    appWindowCoordinator?.tearDown()
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
}
