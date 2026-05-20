import EnviousWisprCore
import EnviousWisprServices
import EnviousWisprStorage
import SwiftUI

@main
struct EnviousWisprApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  // PR-A of #763: SwiftUI App struct is the composition root. App-owned homes
  // live here as `@State` and are injected into views via `.environment(...)`.
  @State private var appState: AppState
  @State private var navigationCoordinator: NavigationCoordinator
  @State private var diagnosticsCoordinator: DiagnosticsCoordinator
  @State private var languageSuggestionPresenter: LanguageSuggestionPresenter
  @State private var updateCoordinatorHolder: UpdateCoordinatorHolder
  /// PR-B.1 of #763 — App-owned Sparkle integration. Constructed in `init()`
  /// from `updateCoordinatorHolder` so `startUpdater()` can publish the
  /// coordinator into the env carrier synchronously during
  /// `applicationWillFinishLaunching` (Issue #739 env-capture invariant).
  @State private var sparkleUpdateController: SparkleUpdateController
  @State private var transcriptWorkflowCoordinator: TranscriptWorkflowCoordinator
  @State private var liveRecordingState: LiveRecordingState
  @State private var lastRecordingResult: LastRecordingResult
  @State private var backendMetadata: BackendMetadata
  @State private var dictationRuntime: DictationRuntime
  /// PR10 of #763: the App owns the shared `HotkeyService` so the single
  /// instance can be threaded into `HotkeyController` (wires callbacks),
  /// `PipelineSettingsSync` (live key/modifier/mode updates),
  /// `DictationLifecycleCoordinator` (per-pipeline-state register/unregister
  /// of the cancel hotkey), and `AppDelegate.attach(...)` (termination
  /// `.stop()`). A single owner of the service is required because all
  /// three consumers mutate it; multiple instances would silently lose
  /// settings changes.
  @State private var hotkeyService: HotkeyService
  /// PR-B.2 of #763: App-owned home for window lifecycle. Strong owner is this
  /// `@State`; `AppDelegate` holds a weak ref. Injected into both Window
  /// scenes via `.environment(...)` so `DiagnosticsSettingsView` reaches it
  /// through `@Environment` instead of an `NSApp.delegate` downcast.
  @State private var appWindowCoordinator: AppWindowCoordinator
  /// PR-B.3 of #763: App-owned home for the menu bar surface (status item,
  /// dropdown menu, animated icon). Strong owner is this `@State`;
  /// `AppDelegate` holds a weak ref pushed via `attach(...)`. Not
  /// `.environment(...)`-injected — no SwiftUI view consumes the menu surface.
  @State private var menuBarController: MenuBarController
  /// PR-B.4 of #763: App-owned home for the process-lifecycle sequence
  /// (launch / foreground-activation / termination side effects). Strong owner
  /// is this `@State`; `AppDelegate` holds a weak ref pushed via `attach(...)`
  /// and forwards its three lifecycle callbacks here. Not
  /// `.environment(...)`-injected — no SwiftUI view consumes it.
  @State private var appLifecycleCoordinator: AppLifecycleCoordinator

  @State private var isOnboardingPresented: Bool =
    !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")

  init() {
    // Construct App-owned homes in dependency order. Closure-capture targets
    // (overlay) must exist before the closures are built; AppState's chip
    // handlers must be wired exactly once.
    let transcriptStore = TranscriptStore()
    let transcriptCoordinator = TranscriptCoordinator(store: transcriptStore)
    // PR10 of #763 — shared `HotkeyService` constructed here as a local
    // let so it can be threaded into AppState.init (for PSS), DLC.init,
    // DR.init (which threads it into HotkeyController), and AppDelegate.attach
    // (for termination). Assigned to `_hotkeyService = State(initialValue:)`
    // at the end of init alongside the other @State homes.
    let hotkeyService = HotkeyService()
    let appState = AppState(transcriptStore: transcriptStore, hotkeyService: hotkeyService)
    let navigationCoordinator = NavigationCoordinator()
    let diagnosticsCoordinator = DiagnosticsCoordinator()

    // PR4 of #763 construction-order constraint preserved: LanguageSuggestionPresenter
    // captures `appState.recordingOverlay` through narrow closures. Build
    // overlay reference first, then presenter, then attach to AppState.
    let overlay = appState.recordingOverlay
    let languageSuggestionPresenter = LanguageSuggestionPresenter(
      showOverlay: { [weak overlay] intent in overlay?.show(intent: intent) },
      readCurrentIntent: { [weak overlay] in overlay?.currentIntent ?? .hidden },
      // Silent hide for chip dismissal — bypasses the .hidden case's
      // "Recording complete" AX announcement (PR4 Codex code-diff r5 [P3]).
      hideOverlay: { [weak overlay] in overlay?.hide() }
    )
    // Setter injection: appState now holds a reference to the presenter for
    // dispatching from its chip-handler closure and pipeline state-change closures.
    appState.attachLanguageSuggestionPresenter(languageSuggestionPresenter)
    // Wire RecordingOverlayPanel chip handler closures into the presenter.
    appState.recordingOverlay.setPassiveChipHandlers(
      onLock: { [weak appState, presenter = languageSuggestionPresenter] in
        if let lang = presenter.accept(), let appState = appState {
          // Capture prior mode for telemetry before mutating settings.
          let priorMode = appState.settings.languageMode
          let fromLang: String
          switch priorMode {
          case .auto: fromLang = "auto"
          case .locked(let prev): fromLang = prev
          }
          appState.settings.languageMode = .locked(lang)
          // PR4 Codex code-diff r6 [P2]: chip-driven locks must emit the same
          // language.manual_lock_used event as Settings-driven locks so the
          // chip CTA is visible in analytics. "after_bad_detect" is the
          // reserved reason for this surface (TelemetryService.swift:483).
          TelemetryService.shared.trackManualLockUsed(
            fromLang: fromLang, toLang: lang, reason: "after_bad_detect")
        }
        // presenter.accept() already hid the overlay; no extra hide needed.
      },
      onDismiss: { [presenter = languageSuggestionPresenter] in
        presenter.dismissExplicit()
      },
      onAutoDismiss: { [presenter = languageSuggestionPresenter] generation in
        presenter.autoDismiss(generation: generation)
      }
    )

    let updateCoordinatorHolder = UpdateCoordinatorHolder()
    let sparkleUpdateController = SparkleUpdateController(holder: updateCoordinatorHolder)

    let transcriptWorkflowCoordinator = TranscriptWorkflowCoordinator(
      transcriptCoordinator: transcriptCoordinator,
      polishService: appState.polishService
    )

    let liveRecordingState = LiveRecordingState(
      pipeline: appState.pipeline,
      whisperKitPipeline: appState.whisperKitPipeline,
      audioCapture: appState.audioCapture,
      asrManager: appState.asrManager
    )
    let lastRecordingResult = LastRecordingResult()
    let backendMetadata = BackendMetadata(
      settings: appState.settings,
      asrManager: appState.asrManager,
      llmDiscovery: appState.llmDiscovery
    )
    appState.attachLiveRecordingState(liveRecordingState)
    appState.attachLastRecordingResult(lastRecordingResult)
    appState.attachBackendMetadata(backendMetadata)

    // PR9 of #763: construct the lifecycle home BEFORE DictationRuntime.
    // PR10 of #763: the shared `hotkeyService` is now threaded in
    // explicitly from the App-owned local let, not from `appState.hotkeyService`
    // (which no longer exists).
    let recordingLockedAccess = DictationLifecycleCoordinator.RecordingLockedAccess(
      get: { [weak appState] in appState?.isRecordingLocked ?? false },
      set: { [weak appState] locked in appState?.isRecordingLocked = locked }
    )
    let dictationLifecycleCoordinator = DictationLifecycleCoordinator(
      pipeline: appState.pipeline,
      whisperKitPipeline: appState.whisperKitPipeline,
      recordingOverlay: appState.recordingOverlay,
      hotkeyService: hotkeyService,
      settingsSync: appState.settingsSync,
      audioCapture: appState.audioCapture,
      transcriptCoordinator: transcriptCoordinator,
      settings: appState.settings,
      lastRecordingResult: lastRecordingResult,
      languageSuggestionPresenter: languageSuggestionPresenter,
      recordingLockedAccess: recordingLockedAccess
    )
    dictationLifecycleCoordinator.install()

    // PR8 of #763: construct heart-path event-routing home. Routers install
    // their `audioCapture.on*` / `asrManager.onServiceInterrupted` slots +
    // the `AVAudioEngineConfigurationChange` observer at init.
    // PR10 of #763: also constructs `HotkeyController` / `RecordingStarter` /
    // `RecordingFinalizer` internally and calls `hotkeyController.install()`
    // as the last init step. EnviousWisprApp.init does NOT construct the
    // recording subsystem directly — DR is the composition root for it.
    let dictationRuntime = DictationRuntime(
      audioCapture: appState.audioCapture,
      asrManager: appState.asrManager,
      pipeline: appState.pipeline,
      whisperKitPipeline: appState.whisperKitPipeline,
      captureTelemetry: appState.captureTelemetry,
      settings: appState.settings,
      permissions: appState.permissions,
      recordingOverlay: appState.recordingOverlay,
      hotkeyService: hotkeyService,
      lastRecordingResult: lastRecordingResult,
      languageSuggestionPresenter: languageSuggestionPresenter,
      dictationLifecycleCoordinator: dictationLifecycleCoordinator,
      recordingLockedAccess: recordingLockedAccess,
      resolveActiveCaptureBackend: { [weak dictationLifecycleCoordinator] in
        dictationLifecycleCoordinator?.activeCaptureBackend()
      },
      resolveActiveTelemetryTarget: { [weak dictationLifecycleCoordinator] in
        dictationLifecycleCoordinator?.activeTelemetryTarget()
      },
      isCurrentSession: { [weak dictationLifecycleCoordinator] sessionID in
        dictationLifecycleCoordinator?.isCurrentSession(sessionID) ?? false
      }
    )

    // PR-B.2 of #763: window-lifecycle home. The two closures encode today's
    // two distinct onboarding guards exactly (`canOpenOnboarding` folds the
    // stacked `guard let appState` + `!= .completed`; `isOnboardingComplete`
    // is the close-observer abort gate). Both capture `appState` weakly so the
    // coordinator carries no `AppState` import or stored reference.
    let appWindowCoordinator = AppWindowCoordinator(
      canOpenOnboarding: { [weak appState] in
        guard let appState else { return false }
        return appState.settings.onboardingState != .completed
      },
      isOnboardingComplete: { [weak appState] in
        appState?.settings.onboardingState == .completed
      }
    )

    // PR-B.3 of #763: menu bar surface home. The five menu-action closures
    // compose the previously inline `@objc` AppDelegate action bodies. The
    // controller reads display facts through narrow PR11-survivor refs
    // (`liveRecordingState`, `backendMetadata`, `sparkleUpdateController`,
    // `appState.settings`, `appState.permissions`) — no AppState reference.
    let menuBarController = MenuBarController(
      liveRecordingState: liveRecordingState,
      backendMetadata: backendMetadata,
      sparkleUpdateController: sparkleUpdateController,
      settings: appState.settings,
      permissions: appState.permissions,
      actions: MenuBarActions(
        continueOnboarding: { appWindowCoordinator.openOnboardingWindow() },
        openSettings: {
          navigationCoordinator.request(.speechEngine)
          appWindowCoordinator.showWindow()
        },
        openPermissions: {
          navigationCoordinator.request(.permissions)
          appWindowCoordinator.showWindow()
        },
        toggleRecording: { await dictationRuntime.toggleRecording(source: .menuBar) },
        quit: { NSApp.terminate(nil) }
      )
    )

    // PR-B.4 of #763: process-lifecycle home. Constructed last — it injects
    // seven already-built dependencies and wires the onboarding-dismiss
    // icon-refresh seam in its `init`. Holds the launch / become-active /
    // terminate bodies that were inlined in `AppDelegate` before PR-B.4.
    let appLifecycleCoordinator = AppLifecycleCoordinator(
      appState: appState,
      dictationRuntime: dictationRuntime,
      dictationLifecycleCoordinator: dictationLifecycleCoordinator,
      liveRecordingState: liveRecordingState,
      menuBarController: menuBarController,
      appWindowCoordinator: appWindowCoordinator,
      hotkeyService: hotkeyService
    )

    _appState = State(initialValue: appState)
    _navigationCoordinator = State(initialValue: navigationCoordinator)
    _diagnosticsCoordinator = State(initialValue: diagnosticsCoordinator)
    _languageSuggestionPresenter = State(initialValue: languageSuggestionPresenter)
    _updateCoordinatorHolder = State(initialValue: updateCoordinatorHolder)
    _sparkleUpdateController = State(initialValue: sparkleUpdateController)
    _transcriptWorkflowCoordinator = State(initialValue: transcriptWorkflowCoordinator)
    _liveRecordingState = State(initialValue: liveRecordingState)
    _lastRecordingResult = State(initialValue: lastRecordingResult)
    _backendMetadata = State(initialValue: backendMetadata)
    _dictationRuntime = State(initialValue: dictationRuntime)
    _hotkeyService = State(initialValue: hotkeyService)
    _appWindowCoordinator = State(initialValue: appWindowCoordinator)
    _menuBarController = State(initialValue: menuBarController)
    _appLifecycleCoordinator = State(initialValue: appLifecycleCoordinator)

    // PR-A: push App-owned homes into AppDelegate before any
    // NSApplicationDelegate callback fires.
    // PR-B.4 of #763: `AppDelegate` is now a thin AppKit adapter — it receives
    // only `sparkleUpdateController` (for `applicationWillFinishLaunching`) and
    // `appLifecycleCoordinator` (for the launch / become-active / terminate
    // callbacks). All other dependencies are injected into
    // `AppLifecycleCoordinator.init` instead.
    appDelegate.attach(
      sparkleUpdateController: sparkleUpdateController,
      appLifecycleCoordinator: appLifecycleCoordinator
    )

    // Initialize observability (PostHog + Sentry) unconditionally at launch —
    // captures install/open/update lifecycle events, startup crashes, and the
    // full onboarding funnel. Anonymous from first launch.
    ObservabilityBootstrap.initialize()
  }

  var body: some Scene {
    Window(AppConstants.appName, id: "main") {
      UnifiedWindowView()
        .frame(minWidth: 580, minHeight: 400)
        .environment(appState)
        .environment(navigationCoordinator)
        .environment(diagnosticsCoordinator)
        .environment(languageSuggestionPresenter)
        .environment(updateCoordinatorHolder)
        .environment(transcriptWorkflowCoordinator)
        .environment(liveRecordingState)
        .environment(lastRecordingResult)
        .environment(backendMetadata)
        .environment(dictationRuntime)
        .environment(appWindowCoordinator)
        .background(
          ActionWirer(
            appState: appState,
            appWindowCoordinator: appWindowCoordinator,
            menuBarController: menuBarController,
            isOnboardingPresented: $isOnboardingPresented
          )
        )
    }
    .defaultSize(width: 820, height: 600)

    // Onboarding window — non-resizable, centered, auto-opens on first launch.
    Window(AppConstants.onboardingWindowTitle, id: "onboarding") {
      OnboardingV2View(onComplete: {
        appWindowCoordinator.closeOnboardingWindow()
      })
      .environment(appState)
      .environment(navigationCoordinator)
      .environment(languageSuggestionPresenter)
      .environment(dictationRuntime)
      .environment(appWindowCoordinator)
    }
    .windowResizability(.contentSize)
    .defaultSize(width: 500, height: 550)
  }
}

/// Hidden view that wires SwiftUI environment actions into App-owned homes.
/// Must live inside a SwiftUI view hierarchy to access @Environment.
private struct ActionWirer: View {
  /// PR-A: App-owned AppState passed in directly.
  let appState: AppState
  /// PR-B.2 of #763: the three SwiftUI window bridges are wired onto the
  /// coordinator now, not AppDelegate.
  let appWindowCoordinator: AppWindowCoordinator
  /// PR-B.3 of #763: onboarding-dismissal icon refresh targets the menu home.
  let menuBarController: MenuBarController
  @Binding var isOnboardingPresented: Bool
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismissWindow) private var dismissWindow

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .task {
        appWindowCoordinator.openMainWindowAction = { [openWindow] in
          openWindow(id: "main")
        }
        appWindowCoordinator.openOnboardingAction = { [openWindow] in
          openWindow(id: "onboarding")
        }
        appWindowCoordinator.dismissOnboardingAction = { [dismissWindow] in
          dismissWindow(id: "onboarding")
        }
        // PR-B.2 of #763: drain any queued onboarding-open request FIRST. On a
        // normal fresh-install launch nothing was queued (no caller runs before
        // this task), so `replayed` is false and the auto-open below fires
        // exactly once — identical to today. Draining first prevents a
        // double-open if a queued request exists.
        let replayed = appWindowCoordinator.consumePendingOpenOnboarding()
        // Auto-open onboarding if needed (first launch), only if nothing was
        // already replayed. ActionWirer runs inside the main Window scene which
        // is always created, so the callbacks are wired before this point.
        if !replayed, appState.settings.onboardingState != .completed {
          appWindowCoordinator.openOnboardingWindow()
        }
      }
      .onChange(of: isOnboardingPresented) { _, newValue in
        if !newValue {
          // State-driven dismissal: binding flipped to false → close window.
          dismissWindow(id: "onboarding")
          NSApp.setActivationPolicy(.accessory)
          menuBarController.updateIcon()
        }
      }
  }
}
