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

    _appState = State(initialValue: appState)
    _navigationCoordinator = State(initialValue: navigationCoordinator)
    _diagnosticsCoordinator = State(initialValue: diagnosticsCoordinator)
    _languageSuggestionPresenter = State(initialValue: languageSuggestionPresenter)
    _updateCoordinatorHolder = State(initialValue: updateCoordinatorHolder)
    _transcriptWorkflowCoordinator = State(initialValue: transcriptWorkflowCoordinator)
    _liveRecordingState = State(initialValue: liveRecordingState)
    _lastRecordingResult = State(initialValue: lastRecordingResult)
    _backendMetadata = State(initialValue: backendMetadata)
    _dictationRuntime = State(initialValue: dictationRuntime)
    _hotkeyService = State(initialValue: hotkeyService)

    // PR-A: push App-owned homes into AppDelegate before any
    // NSApplicationDelegate callback fires.
    // PR10 of #763: also push `dictationRuntime` (so AppDelegate's menu-bar
    // `toggleRecording` action and `applicationDidFinishLaunching`
    // hotkey-start path resolve through the new façade) and `hotkeyService`
    // (so `applicationWillTerminate` can stop the shared service without
    // reaching through the deleted `appState.hotkeyService` path).
    appDelegate.attach(
      appState: appState,
      navigationCoordinator: navigationCoordinator,
      updateCoordinatorHolder: updateCoordinatorHolder,
      liveRecordingState: liveRecordingState,
      backendMetadata: backendMetadata,
      dictationLifecycleCoordinator: dictationLifecycleCoordinator,
      dictationRuntime: dictationRuntime,
      hotkeyService: hotkeyService
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
        .background(
          ActionWirer(
            appDelegate: appDelegate,
            appState: appState,
            isOnboardingPresented: $isOnboardingPresented
          )
        )
    }
    .defaultSize(width: 820, height: 600)

    // Onboarding window — non-resizable, centered, auto-opens on first launch.
    Window(AppConstants.onboardingWindowTitle, id: "onboarding") {
      OnboardingV2View(onComplete: {
        appDelegate.closeOnboardingWindow()
      })
      .environment(appState)
      .environment(navigationCoordinator)
      .environment(languageSuggestionPresenter)
      .environment(dictationRuntime)
    }
    .windowResizability(.contentSize)
    .defaultSize(width: 500, height: 550)
  }
}

/// Hidden view that wires SwiftUI environment actions to the AppDelegate.
/// Must live inside a SwiftUI view hierarchy to access @Environment.
private struct ActionWirer: View {
  let appDelegate: AppDelegate
  /// PR-A: App-owned AppState passed in directly. AppDelegate no longer
  /// exposes `appState`; reading it through the delegate would have to go
  /// through its weak ref and risk a stale read during teardown.
  let appState: AppState
  @Binding var isOnboardingPresented: Bool
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismissWindow) private var dismissWindow

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .task {
        appDelegate.openMainWindowAction = { [openWindow] in
          openWindow(id: "main")
        }
        appDelegate.openOnboardingAction = { [openWindow] in
          openWindow(id: "onboarding")
        }
        appDelegate.dismissOnboardingAction = { [dismissWindow] in
          dismissWindow(id: "onboarding")
        }
        // Auto-open onboarding if needed (first launch).
        // ActionWirer runs inside the main Window scene which is always created,
        // so the callbacks are wired before we attempt to open the onboarding window.
        if appState.settings.onboardingState != .completed {
          appDelegate.openOnboardingWindow()
        }
      }
      .onChange(of: isOnboardingPresented) { _, newValue in
        if !newValue {
          // State-driven dismissal: binding flipped to false → close window.
          dismissWindow(id: "onboarding")
          NSApp.setActivationPolicy(.accessory)
          appDelegate.updateIcon()
        }
      }
  }
}
