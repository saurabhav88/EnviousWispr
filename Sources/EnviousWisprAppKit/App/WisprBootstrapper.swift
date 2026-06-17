import EnviousWisprASR
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprPipeline
import EnviousWisprServices
import EnviousWisprStorage
import SwiftUI

/// #919: the single production composition root, relocated out of the `@main`
/// `EnviousWisprApp` struct into `EnviousWisprAppKit` so the unit-test target
/// can link this code WITHOUT launching the app. The thin `EnviousWisprApp`
/// shell (still `@main`, still owning the `@NSApplicationDelegateAdaptor` and
/// app identity) constructs ONE of these in `App.init()`, attaches it to the
/// shell `AppDelegate`, and shows `mainWindowContent()` / `onboardingWindowContent()`.
/// App-owned homes stay `internal` to this module (no public leak); only the
/// bootstrapper type + its init + 4 lifecycle methods + 2 view factories + 2
/// window-title accessors cross to the shell.
@MainActor
public final class WisprBootstrapper {
  // App-owned homes (epic #763 composition root). Held as `let` on this
  // bootstrapper (which the shell keeps alive via a single `@State`); injected
  // into views via `.environment(...)` inside the view factories below.
  let navigationCoordinator: NavigationCoordinator
  let diagnosticsCoordinator: DiagnosticsCoordinator
  let languageSuggestionPresenter: LanguageSuggestionPresenter
  let updateCoordinatorHolder: UpdateCoordinatorHolder
  let sparkleUpdateController: SparkleUpdateController
  let updateTriggerCoordinator: UpdateTriggerCoordinator
  let transcriptWorkflowCoordinator: TranscriptWorkflowCoordinator
  let liveRecordingState: LiveRecordingState
  let lastRecordingResult: LastRecordingResult
  let backendMetadata: BackendMetadata
  let dictationRuntime: DictationRuntime
  let hotkeyService: HotkeyService
  let appWindowCoordinator: AppWindowCoordinator
  let menuBarController: MenuBarController
  let appLifecycleCoordinator: AppLifecycleCoordinator

  // The nine view-facing subsystems (epic #763), injected into both Window
  // scenes' environment by the view factories.
  let settings: SettingsManager
  let permissions: PermissionsService
  let asrManager: any ASRManagerInterface
  let customWordsCoordinator: CustomWordsCoordinator
  let contactsImportCoordinator: ContactsImportCoordinator
  let setup: SetupCoordinator
  let audioDeviceList: AudioDeviceList
  let aiAvailability: AIAvailabilityCoordinator
  let keychainManager: KeychainManager
  let llmDiscovery: LLMModelDiscoveryCoordinator
  let vocabularyPackManager: VocabularyPackManager

  // The re-polish service is App-owned (epic #763).
  let polishService: TranscriptPolishService

  /// App-owned output-safety classifier holder (#832/#913 PR8). The classifier
  /// is loaded asynchronously off the heart path at prewarm; the holder lets the
  /// live-dictation and re-polish `LLMPolishStep`s pick it up once ready.
  let outputClassifierHolder: OutputClassifierHolder

  public init() {
    // ===== Subsystem construction (epic #763) =====
    // `EnviousWisprApp` is the composition root: every subsystem is constructed
    // here. Construction order is load-bearing: `polishService` before the
    // pipelines (they read its `pasteCompletionRegistry`); `settingsSync` after
    // both pipelines + `setup`.

    // #923: one-time dev→shared settings migration; MUST precede SettingsManager()
    // (mutates the store it reads). Release/shipped builds no-op. See migration doc.
    SettingsDefaultsMigration.migrateIfNeeded()
    let settings = SettingsManager()
    // #1047: apply the persisted appearance before any window is built so a
    // pinned Dark never flashes white. `.system` clears the override (follow OS).
    AppearanceController.apply(settings.appearancePreference)
    let permissions = PermissionsService()
    let keychainManager = KeychainManager()
    let recordingOverlay = RecordingOverlayPanel()
    let audioDeviceList = AudioDeviceList()
    let captureTelemetry = CaptureTelemetryState()
    let customWordsCoordinator = CustomWordsCoordinator()
    // #636: contacts-import orchestrator (opt-in import + bulk-remove + background
    // alias enrichment via the reused on-device suggester). #636 follow-up.
    let contactsImportCoordinator = ContactsImportCoordinator(
      customWords: customWordsCoordinator,
      aliasSuggester: customWordsCoordinator.aliasSuggester)
    let customWordsPropagator = CustomWordsPropagator()
    // #633 Phase 9: owns enabled vocabulary-pack state; merges pack terms into
    // the corrector lane (default OFF). Wired into `wireCustomWords` below.
    let vocabularyPackManager = VocabularyPackManager()
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

    // #832/#913 PR8: app-owned output-safety classifier holder. Created before
    // the polish service + both kernel drivers so all three receive the same
    // instance; the classifier itself loads asynchronously at prewarm (below).
    let outputClassifierHolder = OutputClassifierHolder()

    // Phase 0 (#640) — single shared paste-completion registry. `polishService`
    // is constructed before the pipelines so both receive the same instance.
    let polishService = TranscriptPolishService(
      keychainManager: keychainManager,
      transcriptStore: transcriptStore,
      outputClassifierHolder: outputClassifierHolder
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
        pasteCompletionRegistry: polishService.pasteCompletionRegistry,
        outputClassifierHolder: outputClassifierHolder
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
    // `ASREngineLanguageIdentifying` cast on the adapter; the launch warm-up
    // is owned by the shared `ensureEngineWarm(reason: .launch)` (#879).
    let whisperKitKernelDriver = KernelDictationDriverFactory.makeForWhisperKit(
      inputs: KernelDictationDriverFactory.WhisperKitInputs(
        audioCapture: audioCapture,
        whisperKitBackend: WhisperKitBackend(),
        languageDetector: languageDetector,
        vadSignalSource: vadSource,
        transcriptStore: transcriptStore,
        keychainManager: keychainManager,
        captureTelemetry: captureTelemetry,
        pasteCompletionRegistry: polishService.pasteCompletionRegistry,
        outputClassifierHolder: outputClassifierHolder
      ))

    // Phase F (#501) — `SetupCoordinator` needs `asrManager` + the WhisperKit
    // preload closure. `[weak whisperKitKernelDriver]` so it does not retain it.
    // The WhisperKit launch warm-up routes through the shared
    // `ensureEngineWarm(reason: .launch)` (gated by `SetupCoordinator` on
    // `setupState == .ready`, so it only fires for a downloaded model — never
    // an unprompted download for a non-opted-in user).
    let setup = SetupCoordinator(
      asrManager: asrManager,
      preloadAction: { [weak whisperKitKernelDriver] in
        await whisperKitKernelDriver?.ensureEngineWarm(reason: .launch)
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
      coordinator: customWordsCoordinator,
      packManager: vocabularyPackManager
    )

    settingsSync.onNeedsPreloadObservation = { [weak setup] in
      setup?.startPreloadObservation()
    }

    // Restore persisted backend selection synchronously (no race with first record).
    asrManager.setInitialBackendType(settings.selectedBackend)
    SentryBreadcrumb.updateASRBackend(
      settings.selectedBackend == .whisperKit ? "whisperkit" : "parakeet")

    settings.onChange = { [weak settingsSync, weak settings, outputClassifierHolder] key in
      guard let settingsSync, let settings else { return }
      settingsSync.handleSettingChanged(key, settings: settings)
      // #1047: appearance is a view-shell concern (no pipeline sync) — apply it
      // to NSApp here so both the menu and the Settings picker take effect live.
      if key == .appearance {
        AppearanceController.apply(settings.appearancePreference)
      }
      // #832/#913 PR8: if the user switches polish to Apple Intelligence after
      // launch, prewarm the classifier then (idempotent — no-op if loaded).
      // Captures the holder (not self — self isn't fully initialized here).
      if key == .llmProvider {
        WisprBootstrapper.prewarmOutputClassifierIfNeeded(
          holder: outputClassifierHolder, provider: settings.llmProvider)
      }
    }

    // Pre-load the selected backend's model in the background to eliminate
    // cold-start delay. Parakeet: shared warm-up via the active driver.
    // WhisperKit: observation-based (waits for setupState to become .ready
    // first, then `preloadAction` → `ensureEngineWarm`).
    if settings.selectedBackend == .parakeet {
      Task { [weak kernelDriver] in
        // Discard the outcome so the Task's Success type stays Void
        // (`EngineWarmupOutcome` is @MainActor-only, not Sendable).
        _ = await kernelDriver?.ensureEngineWarm(reason: .launch)
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

    // #1019: event-driven update-discovery triggers (wake / network). Data-free
    // — it reads `updateCoordinator` lazily (nil until `startUpdater()`), so it
    // tolerates being constructed before Sparkle boots.
    let updateTriggerCoordinator = UpdateTriggerCoordinator(
      onTrigger: { [weak sparkleUpdateController] trigger in
        sparkleUpdateController?.updateCoordinator?.checkForUpdatesProactively(trigger: trigger)
      })

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
      contactsImportCoordinator: contactsImportCoordinator,
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

    self.navigationCoordinator = navigationCoordinator
    self.diagnosticsCoordinator = diagnosticsCoordinator
    self.languageSuggestionPresenter = languageSuggestionPresenter
    self.updateCoordinatorHolder = updateCoordinatorHolder
    self.sparkleUpdateController = sparkleUpdateController
    self.updateTriggerCoordinator = updateTriggerCoordinator
    self.transcriptWorkflowCoordinator = transcriptWorkflowCoordinator
    self.liveRecordingState = liveRecordingState
    self.lastRecordingResult = lastRecordingResult
    self.backendMetadata = backendMetadata
    self.dictationRuntime = dictationRuntime
    self.hotkeyService = hotkeyService
    self.appWindowCoordinator = appWindowCoordinator
    self.menuBarController = menuBarController
    self.appLifecycleCoordinator = appLifecycleCoordinator

    // PR-C.1 of #763: the nine view-facing homes.
    self.settings = settings
    self.permissions = permissions
    self.asrManager = asrManager
    self.customWordsCoordinator = customWordsCoordinator
    self.contactsImportCoordinator = contactsImportCoordinator
    self.setup = setup
    self.audioDeviceList = audioDeviceList
    self.aiAvailability = aiAvailability
    self.keychainManager = keychainManager
    self.llmDiscovery = llmDiscovery
    self.vocabularyPackManager = vocabularyPackManager

    // PR-C.3 of #763: App-owned re-polish service.
    self.polishService = polishService

    // #832/#913 PR8: App-owned output-safety classifier holder.
    self.outputClassifierHolder = outputClassifierHolder

    // Initialize observability (PostHog + Sentry) unconditionally at launch.
    // #919: same timing as before — the shell's `App.init()` constructs this
    // bootstrapper synchronously, before any NSApplicationDelegate callback.
    ObservabilityBootstrap.initialize()

    // #832/#913 PR8: prewarm the output-safety classifier off the heart path.
    // Gated on Apple Intelligence (the only provider it scores); a later switch
    // to Apple Intelligence re-triggers via `settings.onChange` above. Never
    // blocks launch, recording, ASR, or paste.
    Self.prewarmOutputClassifierIfNeeded(
      holder: outputClassifierHolder, provider: settings.llmProvider)
  }

  /// Load the on-device output-safety classifier in the background and publish
  /// it into `holder`. Idempotent (no-op if already loaded) and gated on Apple
  /// Intelligence polish. Every failure fails open (the polish path keeps
  /// working without the extra safety net). Static so the `settings.onChange`
  /// closure can call it without capturing a not-yet-initialized `self`.
  /// #832/#913 PR8.
  private static func prewarmOutputClassifierIfNeeded(
    holder: OutputClassifierHolder, provider: LLMProvider
  ) {
    guard provider == .appleIntelligence, holder.classifier == nil else { return }
    Task {
      guard let resourceURL = Bundle.main.resourceURL else {
        await AppLogger.shared.log(
          "[OutputClassifier] preWarm skipped: no bundle resourceURL — fail open",
          level: .info, category: "LLM")
        return
      }
      let start = DispatchTime.now()
      do {
        // `load` is nonisolated-async → the heavy compile/load runs off the main
        // actor (SE-0338); the holder is set back on the main actor here.
        let classifier = try await CoreMLOutputClassifier.load(resourceURL: resourceURL)
        holder.classifier = classifier
        let elapsedMs = Int(
          Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
        await AppLogger.shared.log(
          "[OutputClassifier] preWarm complete latency_ms=\(elapsedMs)",
          level: .info, category: "LLM")
      } catch {
        let reason = (error as? OutputClassifierError)?.reason.rawValue ?? "load_failed"
        await AppLogger.shared.log(
          "[OutputClassifier] preWarm failed reason=\(reason) — fail open to raw/sync-filtered polish",
          level: .info, category: "LLM")
      }
    }
  }

  // MARK: - Lifecycle (forwarded by the shell `AppDelegate`)
  // #919: preserves the exact pre-split timing — `startUpdater()` runs in
  // `applicationWillFinishLaunching`, before the first SwiftUI scene body
  // evaluates (issue #739 / SparkleUpdateController contract).

  public func applicationWillFinishLaunching() {
    sparkleUpdateController.startUpdater()
    // #1019: wire the active-dictation guard so the new install affordances
    // (menu item / notification) never relaunch the app mid-capture.
    sparkleUpdateController.updateCoordinator?.dictationActiveProvider = { [weak self] in
      self?.liveRecordingState.isDictationActive ?? false
    }
    // #958: proactive launch check, right after startUpdater per Sparkle guidance.
    sparkleUpdateController.updateCoordinator?.checkForUpdatesProactively(trigger: "launch")
    // #1019: begin observing wake / network for an always-on, windowless user.
    updateTriggerCoordinator.start()
  }

  public func applicationDidFinishLaunching() {
    appLifecycleCoordinator.runDidFinishLaunching()
  }

  public func applicationDidBecomeActive() {
    appLifecycleCoordinator.runDidBecomeActive()
    // #958: proactive foreground check (post-sleep freshness), strict >=3600 gated.
    sparkleUpdateController.updateCoordinator?.checkForUpdatesProactively(trigger: "foreground")
  }

  public func applicationWillTerminate() {
    // #1019: tear down the network path monitor + wake observer.
    updateTriggerCoordinator.stop()
    appLifecycleCoordinator.runWillTerminate()
  }

  // MARK: - Window titles (so the shell needs no EnviousWisprCore dependency)

  public var mainWindowTitle: String { AppConstants.appName }
  public var onboardingWindowTitle: String { AppConstants.onboardingWindowTitle }

  // MARK: - Root content
  // Homes are injected here, INSIDE the kit — the shell injects nothing, so no
  // home type crosses the module boundary (keeps the public surface tiny).

  public func mainWindowContent() -> some View {
    MainWindowRoot(b: self)
  }

  public func onboardingWindowContent() -> some View {
    OnboardingWindowRoot(b: self)
  }
}

/// The main window's root view. Owns the onboarding-presented view-state (was
/// `@State` on the old App struct) and injects every App-owned home.
private struct MainWindowRoot: View {
  let b: WisprBootstrapper
  @State private var isOnboardingPresented: Bool

  init(b: WisprBootstrapper) {
    self.b = b
    // #923: derive from the SettingsManager instance, not a raw `.standard` read
    // (which on the dev build would hit the wrong per-build store).
    _isOnboardingPresented = State(initialValue: !b.settings.hasCompletedOnboarding)
  }

  var body: some View {
    UnifiedWindowView()
      // 710 covers the pinned sidebar (200) + the NavigationSplitView divider
      // (~8, AX-measured) + the History pane floors (230 + 8 + 260 = 498), so
      // the window can never crush any column (#1024).
      .frame(minWidth: 710, minHeight: 400)
      .environment(b.navigationCoordinator)
      .environment(b.diagnosticsCoordinator)
      .environment(b.languageSuggestionPresenter)
      .environment(b.updateCoordinatorHolder)
      .environment(b.transcriptWorkflowCoordinator)
      .environment(b.liveRecordingState)
      .environment(b.lastRecordingResult)
      .environment(b.backendMetadata)
      .environment(b.dictationRuntime)
      .environment(b.appWindowCoordinator)
      // The nine view-facing homes (epic #763).
      .environment(b.settings)
      .environment(b.permissions)
      .environment(b.customWordsCoordinator)
      .environment(b.contactsImportCoordinator)
      .environment(b.setup)
      .environment(b.audioDeviceList)
      .environment(b.aiAvailability)
      .environment(b.llmDiscovery)
      .environment(b.vocabularyPackManager)
      .environment(\.asrManager, b.asrManager)
      .environment(\.keychainManager, b.keychainManager)
      .background(
        ActionWirer(
          settings: b.settings,
          appWindowCoordinator: b.appWindowCoordinator,
          menuBarController: b.menuBarController,
          isOnboardingPresented: $isOnboardingPresented
        )
      )
  }
}

/// The onboarding window's root view.
private struct OnboardingWindowRoot: View {
  let b: WisprBootstrapper

  var body: some View {
    OnboardingV2View(onComplete: {
      b.appWindowCoordinator.closeOnboardingWindow()
    })
    .environment(b.navigationCoordinator)
    .environment(b.languageSuggestionPresenter)
    .environment(b.dictationRuntime)
    .environment(b.appWindowCoordinator)
    // The nine view-facing homes (epic #763).
    .environment(b.settings)
    .environment(b.permissions)
    .environment(b.customWordsCoordinator)
    .environment(b.setup)
    .environment(b.audioDeviceList)
    .environment(b.aiAvailability)
    .environment(b.llmDiscovery)
    .environment(\.asrManager, b.asrManager)
    .environment(\.keychainManager, b.keychainManager)
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
