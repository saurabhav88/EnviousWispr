import EnviousWisprASR
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprPipeline
import EnviousWisprServices
import EnviousWisprStorage
import SwiftUI

@main
struct EnviousWisprApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  // PR-A of #763: SwiftUI App struct is the composition root. App-owned homes
  // live here as `@State` and are injected into views via `.environment(...)`.
  @State private var navigationCoordinator: NavigationCoordinator
  @State private var diagnosticsCoordinator: DiagnosticsCoordinator
  @State private var languageSuggestionPresenter: LanguageSuggestionPresenter
  @State private var updateCoordinatorHolder: UpdateCoordinatorHolder
  @State private var sparkleUpdateController: SparkleUpdateController
  @State private var transcriptWorkflowCoordinator: TranscriptWorkflowCoordinator
  @State private var liveRecordingState: LiveRecordingState
  @State private var lastRecordingResult: LastRecordingResult
  @State private var backendMetadata: BackendMetadata
  @State private var dictationRuntime: DictationRuntime
  @State private var hotkeyService: HotkeyService
  @State private var appWindowCoordinator: AppWindowCoordinator
  @State private var menuBarController: MenuBarController
  @State private var appLifecycleCoordinator: AppLifecycleCoordinator

  // The nine view-facing subsystems are App-owned `@State` homes, injected
  // into both Window scenes' environment. Every Settings / Main / Onboarding
  // view reads these homes directly (epic #763).
  @State private var settings: SettingsManager
  @State private var permissions: PermissionsService
  @State private var asrManager: any ASRManagerInterface
  @State private var customWordsCoordinator: CustomWordsCoordinator
  @State private var setup: SetupCoordinator
  @State private var audioDeviceList: AudioDeviceList
  @State private var aiAvailability: AIAvailabilityCoordinator
  @State private var keychainManager: KeychainManager
  @State private var llmDiscovery: LLMModelDiscoveryCoordinator

  // The re-polish service is App-owned (epic #763): the composition root
  // holds the canonical reference; views and consumers read it directly.
  @State private var polishService: TranscriptPolishService

  @State private var isOnboardingPresented: Bool =
    !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")

  init() {
    // ===== Subsystem construction (epic #763) =====
    // `EnviousWisprApp` is the composition root: every subsystem is constructed
    // here. Construction order is load-bearing: `polishService` before the
    // pipelines (they read its `pasteCompletionRegistry`); `settingsSync` after
    // both pipelines + `setup`.

    let settings = SettingsManager()
    let permissions = PermissionsService()
    let keychainManager = KeychainManager()
    let recordingOverlay = RecordingOverlayPanel()
    let audioDeviceList = AudioDeviceList()
    let captureTelemetry = CaptureTelemetryState()
    let customWordsCoordinator = CustomWordsCoordinator()
    let customWordsPropagator = CustomWordsPropagator()
    let aiAvailability = AIAvailabilityCoordinator()

    // XPC audio service — default ON. Audio capture runs in a separate XPC
    // service process for crash isolation. Read directly from UserDefaults
    // (the `object(forKey:) ?? true` pattern so existing installs with no key
    // written get the new default). Escape hatch:
    // `defaults write ... useXPCAudioService -bool false`.
    let useXPC = UserDefaults.standard.object(forKey: "useXPCAudioService") as? Bool ?? true
    let audioCapture: any AudioCaptureInterface =
      useXPC ? AudioCaptureProxy() : AudioCaptureManager()

    // XPC ASR service — default ON. ASR inference runs in a separate XPC
    // service process for memory isolation. Escape hatch:
    // `defaults write ... useXPCASRService -bool false`.
    let useXPCASR = UserDefaults.standard.object(forKey: "useXPCASRService") as? Bool ?? true
    let asrManager: any ASRManagerInterface =
      useXPCASR ? ASRManagerProxy() : ASRManager()

    let llmDiscovery = LLMModelDiscoveryCoordinator(keychainManager: keychainManager)

    let transcriptStore = TranscriptStore()
    let transcriptCoordinator = TranscriptCoordinator(store: transcriptStore)

    // Phase 0 (#640) — single shared paste-completion registry. `polishService`
    // is constructed before the pipelines so both receive the same instance.
    let polishService = TranscriptPolishService(
      keychainManager: keychainManager,
      transcriptStore: transcriptStore
    )

    // PR-5 Rung 5 (#827): the VAD signal source is App-owned and shared
    // between both kernel drivers. `audioCapture.onVADAutoStop` is bound
    // exactly once here; the factory's `assembleDriver` no longer binds
    // (Codex r2 new defect 1). Without this, the second driver's
    // construction would silently overwrite the first driver's VAD callback.
    let vadSource = KernelDictationDriverFactory.makeSharedVADSignalSource(
      audioCapture: audioCapture)

    // PR-4b.4 of #827: Parakeet recordings flow through the kernel via the
    // driver constructed by `KernelDictationDriverFactory`. The factory
    // builds the kernel + Parakeet engine adapter + lifecycle telemetry sink
    // + heart-path telemetry observer internally and wires kernel-state
    // observation post-construction (PR-4b.2).
    let kernelDriver = KernelDictationDriverFactory.makeForParakeet(
      inputs: KernelDictationDriverFactory.ParakeetInputs(
        audioCapture: audioCapture,
        asrManager: asrManager,
        vadSignalSource: vadSource,
        transcriptStore: transcriptStore,
        keychainManager: keychainManager,
        captureTelemetry: captureTelemetry,
        pasteCompletionRegistry: polishService.pasteCompletionRegistry
      ))

    // W6: language-flip telemetry wired via a closure so `EnviousWisprASR`
    // stays vendor-contained. The detector fires this from an actor; hop to
    // MainActor to call the @MainActor-isolated `TelemetryService`.
    let languageDetector = LanguageDetector(
      onLanguageFlip: { @Sendable event in
        Task { @MainActor in
          TelemetryService.shared.trackLanguageFlip(
            fromLang: event.fromLang,
            toLang: event.toLang,
            confidenceBoth: event.confidenceBoth
          )
        }
      }
    )

    // PR-5 Rung 5 (#827): WhisperKit recordings now flow through a second
    // `KernelDictationDriver` built by the factory's WhisperKit branch. The
    // App still builds one driver per backend; PR-6 (#827) introduced the
    // `KernelAdapterFactory` construction owner that the driver factory calls
    // into, not a single-dispatch-surface consolidation (still two drivers).
    // LID-to-polish wiring is
    // owned by `KernelFinalizationWiring.processText` via the
    // `ASREngineLanguageIdentifying` cast on the adapter; the silent
    // App-init cache pre-load is owned by the driver's
    // `prepareBackendSilently()` via the `ASREngineCacheModelLoadable` cast.
    let whisperKitKernelDriver = KernelDictationDriverFactory.makeForWhisperKit(
      inputs: KernelDictationDriverFactory.WhisperKitInputs(
        audioCapture: audioCapture,
        whisperKitBackend: WhisperKitBackend(),
        languageDetector: languageDetector,
        vadSignalSource: vadSource,
        transcriptStore: transcriptStore,
        keychainManager: keychainManager,
        captureTelemetry: captureTelemetry,
        pasteCompletionRegistry: polishService.pasteCompletionRegistry
      ))

    // Phase F (#501) — `SetupCoordinator` needs `asrManager` + the WhisperKit
    // preload closure. `[weak whisperKitKernelDriver]` so it does not retain it.
    // PR-5 Rung 5: `prepareBackendSilently()` forwards via the
    // `ASREngineCacheModelLoadable` cast on the WhisperKit adapter (parity
    // with OLD `WhisperKitPipeline.prepareBackendSilently()`).
    let setup = SetupCoordinator(
      asrManager: asrManager,
      preloadAction: { [weak whisperKitKernelDriver] in
        await whisperKitKernelDriver?.prepareBackendSilently()
      }
    )

    // PR10 of #763 — shared `HotkeyService`. One owner so the single instance
    // threads into `HotkeyController`, `PipelineSettingsSync`,
    // `DictationLifecycleCoordinator`, and `AppDelegate` termination.
    let hotkeyService = HotkeyService()

    let settingsSync = PipelineSettingsSync(
      kernelDriver: kernelDriver,
      whisperKitKernelDriver: whisperKitKernelDriver,
      polishService: polishService,
      audioCapture: audioCapture,
      asrManager: asrManager,
      hotkeyService: hotkeyService,
      whisperKitSetup: setup.whisperKitSetup
    )
    settingsSync.applyInitialSettings(settings)

    recordingOverlay.setGrantHandler { [weak permissions] in
      _ = permissions?.requestAccessibilityAccess()
    }
    recordingOverlay.setAccessibilityWarningDismissedProvider { [weak permissions] in
      permissions?.accessibilityWarningDismissed ?? false
    }

    // Custom-words propagator wiring (seed → register consumers → install
    // `onWordsChanged`). Phase D (#496). `wireCustomWords` strong-captures the
    // propagator so its lifetime is anchored to `customWordsCoordinator`.
    wireCustomWords(
      propagator: customWordsPropagator,
      initialWords: customWordsCoordinator.customWords,
      correctorConsumers: [
        kernelDriver.wordCorrection,
        whisperKitKernelDriver.wordCorrection,
      ],
      polishConsumers: [
        kernelDriver.llmPolish,
        whisperKitKernelDriver.llmPolish,
        polishService.llmPolishStep,
      ],
      coordinator: customWordsCoordinator
    )

    settingsSync.onNeedsPreloadObservation = { [weak setup] in
      setup?.startPreloadObservation()
    }

    // Restore persisted backend selection synchronously (no race with first record).
    asrManager.setInitialBackendType(settings.selectedBackend)
    SentryBreadcrumb.updateASRBackend(
      settings.selectedBackend == .whisperKit ? "whisperkit" : "parakeet")

    settings.onChange = { [weak settingsSync, weak settings] key in
      guard let settingsSync, let settings else { return }
      settingsSync.handleSettingChanged(key, settings: settings)
    }

    // Pre-load the selected backend's model in the background to eliminate
    // cold-start delay. Parakeet: direct silent load. WhisperKit:
    // observation-based (waits for setupState to become .ready first).
    if settings.selectedBackend == .parakeet {
      Task { [weak asrManager] in
        await asrManager?.loadModelSilently()
      }
    }
    Task { [weak setup] in
      await setup?.whisperKitSetup.detectState()
      setup?.startPreloadObservation()
    }

    let navigationCoordinator = NavigationCoordinator()
    let diagnosticsCoordinator = DiagnosticsCoordinator()

    // PR4 of #763 construction-order constraint preserved: LanguageSuggestionPresenter
    // captures `recordingOverlay` through narrow closures.
    let overlay = recordingOverlay
    let languageSuggestionPresenter = LanguageSuggestionPresenter(
      showOverlay: { [weak overlay] intent in overlay?.show(intent: intent) },
      readCurrentIntent: { [weak overlay] in overlay?.currentIntent ?? .hidden },
      // Silent hide for chip dismissal — bypasses the .hidden case's
      // "Recording complete" AX announcement (PR4 Codex code-diff r5 [P3]).
      hideOverlay: { [weak overlay] in overlay?.hide() }
    )
    // Wires the `LanguageDetector` actor's passive-chip callback to the
    // presenter. The presenter is captured directly (App-lifetime `@State`).
    Task {
      await languageDetector.setPassiveChipHandler {
        @Sendable (trigger: PassiveChipTrigger) in
        Task { @MainActor in
          languageSuggestionPresenter.bufferTrigger(trigger)
        }
      }
    }

    // Wire RecordingOverlayPanel chip handler closures into the presenter.
    recordingOverlay.setPassiveChipHandlers(
      onLock: { [weak settings, presenter = languageSuggestionPresenter] in
        if let lang = presenter.accept(), let settings = settings {
          // Capture prior mode for telemetry before mutating settings.
          let priorMode = settings.languageMode
          let fromLang: String
          switch priorMode {
          case .auto: fromLang = "auto"
          case .locked(let prev): fromLang = prev
          }
          settings.languageMode = .locked(lang)
          // PR4 Codex code-diff r6 [P2]: chip-driven locks emit the same
          // language.manual_lock_used event as Settings-driven locks.
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
      polishService: polishService
    )

    let liveRecordingState = LiveRecordingState(
      kernelDriver: kernelDriver,
      whisperKitKernelDriver: whisperKitKernelDriver,
      audioCapture: audioCapture,
      asrManager: asrManager
    )
    let lastRecordingResult = LastRecordingResult()
    let backendMetadata = BackendMetadata(
      settings: settings,
      asrManager: asrManager,
      llmDiscovery: llmDiscovery
    )
    // `LiveRecordingState` provides `DictationActivityProviding`: `polishService`
    // blocks a re-polish while live dictation is in flight. Wired after
    // `liveRecordingState` exists.
    polishService.setDictationActivity(liveRecordingState)

    // PR9 of #763: construct the lifecycle home BEFORE DictationRuntime.
    // PR-C.3: the hands-free lock flag is rehomed onto `LiveRecordingState`.
    let recordingLockedAccess = DictationLifecycleCoordinator.RecordingLockedAccess(
      get: { liveRecordingState.isRecordingLocked },
      set: { locked in liveRecordingState.isRecordingLocked = locked }
    )
    let dictationLifecycleCoordinator = DictationLifecycleCoordinator(
      kernelDriver: kernelDriver,
      whisperKitKernelDriver: whisperKitKernelDriver,
      recordingOverlay: recordingOverlay,
      hotkeyService: hotkeyService,
      settingsSync: settingsSync,
      audioCapture: audioCapture,
      transcriptCoordinator: transcriptCoordinator,
      settings: settings,
      lastRecordingResult: lastRecordingResult,
      languageSuggestionPresenter: languageSuggestionPresenter,
      recordingLockedAccess: recordingLockedAccess
    )
    dictationLifecycleCoordinator.install()

    // PR8 of #763: heart-path event-routing home. PR10: also constructs
    // HotkeyController / RecordingStarter / RecordingFinalizer internally.
    let dictationRuntime = DictationRuntime(
      audioCapture: audioCapture,
      asrManager: asrManager,
      kernelDriver: kernelDriver,
      whisperKitKernelDriver: whisperKitKernelDriver,
      captureTelemetry: captureTelemetry,
      settings: settings,
      permissions: permissions,
      recordingOverlay: recordingOverlay,
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

    // PR-B.2 of #763: window-lifecycle home.
    let appWindowCoordinator = AppWindowCoordinator(
      canOpenOnboarding: { [weak settings] in
        guard let settings else { return false }
        return settings.onboardingState != .completed
      },
      isOnboardingComplete: { [weak settings] in
        settings?.onboardingState == .completed
      }
    )

    // PR-B.3 of #763: menu bar surface home.
    let menuBarController = MenuBarController(
      liveRecordingState: liveRecordingState,
      backendMetadata: backendMetadata,
      sparkleUpdateController: sparkleUpdateController,
      settings: settings,
      permissions: permissions,
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

    // PR-B.4 of #763: process-lifecycle home. Constructed last. It receives the
    // 10 specific homes it reads.
    let appLifecycleCoordinator = AppLifecycleCoordinator(
      settings: settings,
      permissions: permissions,
      keychainManager: keychainManager,
      customWordsCoordinator: customWordsCoordinator,
      aiAvailability: aiAvailability,
      audioCapture: audioCapture,
      asrManager: asrManager,
      kernelDriver: kernelDriver,
      whisperKitKernelDriver: whisperKitKernelDriver,
      setup: setup,
      dictationRuntime: dictationRuntime,
      dictationLifecycleCoordinator: dictationLifecycleCoordinator,
      liveRecordingState: liveRecordingState,
      menuBarController: menuBarController,
      appWindowCoordinator: appWindowCoordinator,
      hotkeyService: hotkeyService
    )

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

    // PR-C.1 of #763: the nine view-facing homes.
    _settings = State(initialValue: settings)
    _permissions = State(initialValue: permissions)
    _asrManager = State(initialValue: asrManager)
    _customWordsCoordinator = State(initialValue: customWordsCoordinator)
    _setup = State(initialValue: setup)
    _audioDeviceList = State(initialValue: audioDeviceList)
    _aiAvailability = State(initialValue: aiAvailability)
    _keychainManager = State(initialValue: keychainManager)
    _llmDiscovery = State(initialValue: llmDiscovery)

    // PR-C.3 of #763: App-owned re-polish service.
    _polishService = State(initialValue: polishService)

    // PR-A: push App-owned homes into AppDelegate before any
    // NSApplicationDelegate callback fires.
    appDelegate.attach(
      sparkleUpdateController: sparkleUpdateController,
      appLifecycleCoordinator: appLifecycleCoordinator
    )

    // Initialize observability (PostHog + Sentry) unconditionally at launch.
    ObservabilityBootstrap.initialize()
  }

  var body: some Scene {
    Window(AppConstants.appName, id: "main") {
      UnifiedWindowView()
        .frame(minWidth: 580, minHeight: 400)
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
        // The nine view-facing homes (epic #763).
        .environment(settings)
        .environment(permissions)
        .environment(customWordsCoordinator)
        .environment(setup)
        .environment(audioDeviceList)
        .environment(aiAvailability)
        .environment(llmDiscovery)
        .environment(\.asrManager, asrManager)
        .environment(\.keychainManager, keychainManager)
        .background(
          ActionWirer(
            settings: settings,
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
      .environment(navigationCoordinator)
      .environment(languageSuggestionPresenter)
      .environment(dictationRuntime)
      .environment(appWindowCoordinator)
      // The nine view-facing homes (epic #763).
      .environment(settings)
      .environment(permissions)
      .environment(customWordsCoordinator)
      .environment(setup)
      .environment(audioDeviceList)
      .environment(aiAvailability)
      .environment(llmDiscovery)
      .environment(\.asrManager, asrManager)
      .environment(\.keychainManager, keychainManager)
    }
    .windowResizability(.contentSize)
    .defaultSize(width: 500, height: 550)
  }
}

/// Hidden view that wires SwiftUI environment actions into App-owned homes.
/// Must live inside a SwiftUI view hierarchy to access @Environment.
private struct ActionWirer: View {
  /// The onboarding-auto-open gate reads `onboardingState` off the settings
  /// store directly (epic #763).
  let settings: SettingsManager
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
        // PR-B.2 of #763: drain any queued onboarding-open request FIRST.
        let replayed = appWindowCoordinator.consumePendingOpenOnboarding()
        // Auto-open onboarding if needed (first launch), only if nothing was
        // already replayed.
        if !replayed, settings.onboardingState != .completed {
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
