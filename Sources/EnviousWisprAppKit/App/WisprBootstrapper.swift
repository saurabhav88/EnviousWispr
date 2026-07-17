import EnviousWisprASR
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprModelDelivery
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
  /// Owns the crash-recovery limb (#1063 PR1): arms each recording's encrypted
  /// spool, deletes it on durable save, purges orphans on launch.
  let recoveryCoordinator: RecoveryCoordinator
  let languageSuggestionPresenter: LanguageSuggestionPresenter
  let updateCoordinatorHolder: UpdateCoordinatorHolder
  let sparkleUpdateController: SparkleUpdateController
  let updateTriggerCoordinator: UpdateTriggerCoordinator
  let transcriptCoordinator: TranscriptCoordinator
  let liveRecordingState: LiveRecordingState
  let lastRecordingResult: LastRecordingResult
  let backendMetadata: BackendMetadata
  /// #1171 — the sole owner of ASR-engine selection, status, and switching.
  let engineCoordinator: EngineCoordinator
  let dictationRuntime: DictationRuntime
  let hotkeyService: HotkeyService
  let appWindowCoordinator: AppWindowCoordinator
  let menuBarController: MenuBarController
  let appLifecycleCoordinator: AppLifecycleCoordinator

  // The nine view-facing subsystems (epic #763), injected into both Window
  // scenes' environment by the view factories.
  let settings: SettingsManager
  let permissions: PermissionsService
  /// #1176: in-flight onboarding session, read at app-quit to emit abandon.
  let onboardingProgress = OnboardingProgress()
  let asrManager: any ASRManagerInterface
  /// #1386 PR-2: the one door to whichever engine is active. Shared plumbing —
  /// crash recovery (constructed here) and the Diagnostics benchmark (via the
  /// environment) both need the SAME routing, and `DiagnosticsCoordinator` is
  /// capped at its single benchmark collaborator by design.
  let activeEngine: ActiveEngineOperation
  let customWordsCoordinator: CustomWordsCoordinator
  let contactsImportCoordinator: ContactsImportCoordinator
  let setup: SetupCoordinator
  /// #1271 — EG-1 native runtime home (model store + inference server).
  let egOneRuntime: EGOneRuntime
  /// #1348 Phase 2: owned model-delivery home (controller + Parakeet
  /// registration + telemetry bridge + observable UI mirror). The +1 stored
  /// property is the plan's named cost (ceiling 34 -> 35, Bible entry in
  /// EnviousWisprAppCeilingsTests).
  let modelDelivery: ModelDeliveryHome

  /// #1386 PR-2. Stored because nothing else owns it: it is reached only through a closure
  /// `SetupCoordinator` calls once, and a closure capture cannot keep it alive. Held here, it
  /// lives as long as the app — which is what "runs on every launch" requires.
  let whisperKitRetirement: WhisperKitLegacyUpgradeCoordinator?
  let audioDeviceList: AudioDeviceList
  let inputDevicePreferenceReconciler: InputDevicePreferenceReconciler
  let aiAvailability: AIAvailabilityCoordinator
  let keychainManager: KeychainManager
  let llmDiscovery: LLMModelDiscoveryCoordinator
  let vocabularyPackManager: VocabularyPackManager

  /// App-owned output-safety classifier holder (#832/#913 PR8). The classifier
  /// is loaded asynchronously off the heart path at prewarm; the holder lets the
  /// live-dictation `LLMPolishStep`s pick it up once ready.
  let outputClassifierHolder: OutputClassifierHolder

  /// Telemetry Bible Phase 4 (#1173). Observes the settings funnel for coalesced
  /// `settings.changed` deltas + the onboarding-completion baseline. Held
  /// app-lifetime (a weak-only hold would dealloc and silently stop emitting).
  let settingsChangeTelemetry: SettingsChangeTelemetry

  public init() {
    // ===== Subsystem construction (epic #763) =====
    // `EnviousWisprApp` is the composition root: every subsystem is constructed
    // here. Construction order is load-bearing: `pasteCompletionRegistry` before
    // the pipelines (they receive it); `settingsSync` after both pipelines +
    // `setup`.

    // #923: one-time dev→shared settings migration; MUST precede SettingsManager()
    // (mutates the store it reads). Release/shipped builds no-op. See migration doc.
    SettingsDefaultsMigration.migrateIfNeeded()
    let settings = SettingsManager()
    // #1047: apply the persisted appearance before any window is built so a
    // pinned Dark never flashes white. `.system` clears the override (follow OS).
    AppearanceController.apply(settings.appearancePreference)
    let permissions = PermissionsService()
    // #1177 (Telemetry Bible Phase 8): inject the live LLM-module telemetry sink at the
    // composition root. This is the ONLY KeychainManager that gets `.live`; it carries
    // the sink for the legacy-key-cleanup (Q3.3) + cloud-prewarm (A6) quiet limbs.
    let keychainManager = KeychainManager(telemetrySink: .live)
    let recordingOverlay = RecordingOverlayPanel(positionProvider: { settings.overlayPillPosition })
    let audioDeviceList = AudioDeviceList()
    let inputDevicePreferenceReconciler = InputDevicePreferenceReconciler(settings: settings)
    audioDeviceList.onDevicesChanged = { [weak inputDevicePreferenceReconciler] devices in
      inputDevicePreferenceReconciler?.reconcile(availableDevices: devices)
    }
    inputDevicePreferenceReconciler.reconcile(
      availableDevices: audioDeviceList.availableInputDevices)
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

    // Audio capture runs in-process (#1543, D-028 — the separate XPC audio
    // helper was collapsed away). The ASR helper below stays isolated.
    let audioCapture: any AudioCaptureInterface = AudioCaptureManager()

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

    // Phase 0 (#640) — single shared paste-completion registry, owned by the
    // composition root and injected into both pipeline finalizers (and any
    // future #629 auto-learn subscriber). One instance per app session;
    // constructed before the pipelines so both receive the same one. (#1106
    // re-homed this from the deleted re-polish service per
    // `state-ownership.md` shared-infra-homes-not-feature-services.)
    let pasteCompletionRegistry = PasteCompletionRegistry()

    // #1348 Phase 2/3 — owned model delivery. Constructed BEFORE EG-1 so the
    // EG-1 adapter receives the ONE shared `ModelDeliveryController` (#1348
    // §Decision A construction-order fix: the adapter must exist before launch
    // activation calls it). A failed bundled-manifest load leaves the Parakeet
    // handle nil (legacy path), unit-tested can't-happen.
    let modelDelivery = ModelDeliveryHome()

    // #1271/#1348 Phase 3 — EG-1 native runtime: the model bytes now move
    // through the shared delivery engine via `EGOneDeliveryAdapter` (a limb —
    // a delivery failure degrades polish to raw text, never blocks dictation).
    // Shared-infra home, threaded into both kernel drivers + crash recovery.
    // Launch-start below so dictation never depends on settings opening;
    // `isActiveProvider` is a LIVE read (r2). The runtime keeps the EGOne
    // manifest (contextTokens / promptFamily / activation blockers); the
    // adapter owns the delivery manifest (fetch/install/content identity).
    //
    // #1386 PR-1 rev2: retire the one shipped EG-1 monolith. The coordinator
    // recognizes it by exact size + digest, records the owed replacement,
    // deletes it, and asks the adapter for the normal download; fresh
    // installs land in the owned `Models/eg-1` home.
    let egOneManifest = try? EGOneManifest.loadBundled()
    let egOneServerBinaryURL = Bundle.main.url(forResource: "llama-server", withExtension: nil)
    let egOneAppSupport = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask)[0]
    var egOneAdapter: EGOneDeliveryAdapter?
    var egOneLegacyUpgrade:
      (registration: DeliveryRegistration, coordinator: EGOneLegacyUpgradeCoordinator)?
    if let deliveryManifest = try? DeliveryManifest.loadBundled(resource: "eg1-delivery-manifest") {
      let registration = DeliveryRegistration(
        manifest: deliveryManifest,
        installDirectory: egOneAppSupport.appendingPathComponent(
          "EnviousWispr/Models/eg-1", isDirectory: true),
        metadataDirectory: egOneAppSupport.appendingPathComponent(
          "EnviousWispr/ModelDelivery", isDirectory: true))
      let adapter = EGOneDeliveryAdapter(
        controller: modelDelivery.controller,
        registration: registration,
        version: egOneManifest?.version ?? deliveryManifest.identity.revision)
      egOneAdapter = adapter

      let coordinator = EGOneLegacyUpgradeCoordinator(
        adapter: adapter,
        appSupportDirectory: egOneAppSupport)
      // `selected_provider` attaches here (settings in scope); coordinator
      // stays provider-ignorant.
      coordinator.onEvent = EGOneTelemetryBridge.legacyUpgradeHandler(
        selectedProvider: { [weak settings] in settings?.llmProvider == .egOne })
      egOneLegacyUpgrade = (registration, coordinator)
    }
    let egOneRuntime = EGOneRuntime(
      manifest: egOneManifest, serverBinaryURL: egOneServerBinaryURL, delivery: egOneAdapter)
    egOneRuntime.isActiveProvider = { [weak settings] in settings?.llmProvider == .egOne }
    egOneRuntime.onEvent = EGOneTelemetryBridge.handler
    if let egOneLegacyUpgrade {
      // First-run baseline (#1348 §16.2) → legacy launch table → the RUNTIME
      // decides if the completed replacement boots the server (PR #1500 P1).
      let delivery = modelDelivery
      Task {
        await delivery.recordFirstRunBaseline(for: egOneLegacyUpgrade.registration)
        await egOneLegacyUpgrade.coordinator.runLaunch()
        egOneRuntime.activateAfterAutomaticReplacementIfNeeded()
      }
    }
    // Exactly one path sweeps orphans — a detached sweep alongside a spawn
    // would race it and kill the fresh server (Codex r10 P1).
    if settings.llmProvider == .egOne {
      egOneRuntime.startIfActiveProvider()
    } else {
      egOneRuntime.sweepStaleServersAtLaunch()
    }

    // PR-5 Rung 5 (#827): the VAD signal source is App-owned and shared
    // between both kernel drivers. `audioCapture.onVADAutoStop` is bound
    // exactly once here; the factory's `assembleDriver` no longer binds
    // (Codex r2 new defect 1). Without this, the second driver's
    // construction would silently overwrite the first driver's VAD callback.
    let vadSource = KernelDictationDriverFactory.makeSharedVADSignalSource(
      audioCapture: audioCapture)
    // #1224 (#1543): the VAD source reports a typed readiness FACT when the
    // bundled model can't load. The App shell emits a typed in-panel notice and
    // `DictationNarrator` owns the user-facing sentence (#1567). The notice
    // no-ops when no recording panel is showing.
    vadSource.onAutoStopUnavailableNotice = { [weak recordingOverlay] in
      recordingOverlay?.flashRecordingNotice(reason: .autoStopUnavailable, dismissAfter: 4.0)
    }

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
        pasteCompletionRegistry: pasteCompletionRegistry,
        outputClassifierHolder: outputClassifierHolder,
        dictationAudioArchiveOptInProvider: { settings.isDictationAudioArchiveEnabled },
        egOneRuntime: egOneRuntime,
        parakeetDelivery: modelDelivery.parakeetHandle
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
    // #1386 PR-2: the multilingual engine's delivery wiring (owned folder,
    // relocation coordinator, one gated backend, setup surface). Detail lives in
    // `WhisperKitDeliveryWiring`; the root just names it.
    let whisperKit = WhisperKitDeliveryWiring.make(modelDelivery: modelDelivery)
    let whisperKitBackend = whisperKit.backend
    let whisperKitRetirement = whisperKit.retirement

    let whisperKitKernelDriver = KernelDictationDriverFactory.makeForWhisperKit(
      inputs: KernelDictationDriverFactory.WhisperKitInputs(
        audioCapture: audioCapture,
        whisperKitBackend: whisperKitBackend,
        languageDetector: languageDetector,
        vadSignalSource: vadSource,
        transcriptStore: transcriptStore,
        keychainManager: keychainManager,
        captureTelemetry: captureTelemetry,
        pasteCompletionRegistry: pasteCompletionRegistry,
        outputClassifierHolder: outputClassifierHolder,
        dictationAudioArchiveOptInProvider: { settings.isDictationAudioArchiveEnabled },
        egOneRuntime: egOneRuntime
      ))

    // Phase F (#501) — `SetupCoordinator` needs `asrManager` + the WhisperKit
    // preload closure. `[weak whisperKitKernelDriver]` so it does not retain it.
    // The WhisperKit launch warm-up routes through the shared
    // `ensureEngineWarm(reason: .launch)` (gated by `SetupCoordinator` on
    // `setupState == .ready`, so it only fires for a downloaded model — never
    // an unprompted download for a non-opted-in user).
    let setup = SetupCoordinator(
      asrManager: asrManager,
      whisperKitSetup: whisperKit.setupService,
      // Fired from runDidFinishLaunching once the app is on screen, and that
      // timing is the whole reason this is a closure rather than a call in the
      // constructor: retirement reads `~/Documents`, which can raise the
      // Files-and-Folders prompt. A permission dialog thrown at a user before the
      // app has drawn is a bad first impression and an easy accidental "Don't
      // Allow" — which would leave the copy unreadable and retirement declined.
      runDocumentsMigration: { [weak whisperKitRetirement] in
        await whisperKitRetirement?.runLaunch()
      },
      preloadAction: { [weak whisperKitKernelDriver] in
        await whisperKitKernelDriver?.ensureEngineWarm(reason: .launch)
      }
    )

    // PR10 of #763 — shared `HotkeyService`. One owner so the single instance
    // threads into `HotkeyController`, `PipelineSettingsSync`,
    // `DictationLifecycleCoordinator`, and `AppDelegate` termination.
    // #1175: the live telemetry sink is constructor-injected so it is in place
    // before `start()` runs any registration (heart-path + bootstrap ordering).
    let hotkeyService = HotkeyService(telemetry: .live)

    // 2c: the Remove drain's engine-unload seam — assignable only now that the
    // driver (and its adapter) exist; the wiring that built the coordinator ran
    // before them. L1: the drain awaits this BEFORE the delivery deletion.
    whisperKitRetirement?.unloadForRemoval = { [weak whisperKitKernelDriver] in
      await whisperKitKernelDriver?.unloadEngineForRemoval()
    }
    let settingsSync = PipelineSettingsSync(
      kernelDriver: kernelDriver,
      whisperKitKernelDriver: whisperKitKernelDriver,
      audioCapture: audioCapture,
      asrManager: asrManager,
      hotkeyService: hotkeyService,
      egOneRuntime: egOneRuntime
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
      ],
      coordinator: customWordsCoordinator,
      packManager: vocabularyPackManager
    )

    // Restore persisted backend selection synchronously (no race with first record).
    asrManager.setInitialBackendType(settings.selectedBackend)
    SentryBreadcrumb.updateASRBackend(settings.selectedBackend.rawValue)

    // #1173: settings-change telemetry observer. `emitBaseline` re-emits the
    // comprehensive `settings.snapshot` at onboarding-completion (fixes the
    // first-run gap for a long-running app). Built before the funnel is wired.
    let settingsChangeTelemetry = SettingsChangeTelemetry(
      settings: settings,
      emitBaseline: { [keychainManager, customWordsCoordinator, permissions] in
        StandingSnapshotBuilder(
          settings: settings, keychainManager: keychainManager,
          customWordsCoordinator: customWordsCoordinator, permissions: permissions
        ).emit()
      })
    // #1173: drain a pending settings delta before any telemetry flush (quit /
    // update-relaunch) so a change made inside the debounce window isn't lost.
    TelemetryService.shared.onBeforeFlush = { [weak settingsChangeTelemetry] in
      settingsChangeTelemetry?.flush()
    }

    // #1480: late-binding bridge so this early-assigned onChange closure can
    // forward setting-change facts to the (later-constructed) presenter.
    let bluetoothAwarenessPresenterHolder = BluetoothAwarenessPresenterHolder()

    settings.onChange = {
      [
        weak settingsSync, weak settings, weak settingsChangeTelemetry, outputClassifierHolder,
        bluetoothAwarenessPresenterHolder
      ] key
      in
      guard let settingsSync, let settings else { return }
      settingsSync.handleSettingChanged(key, settings: settings)
      // #1173: emit coalesced settings.changed deltas (fire-and-forget, never
      // throws/awaits into the setter path).
      settingsChangeTelemetry?.handle(key)
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
      // #1480: tips on/off, input-device change, and onboarding completion each
      // re-evaluate the Bluetooth card (dismiss/suppress, route re-check, or first
      // surface after onboarding). Deferred to the next run-loop cycle because the
      // input picker writes `preferredInputDeviceIDOverride` and
      // `selectedInputDeviceUID` as a synchronous PAIR (AudioSettingsView), so a
      // reconcile on the first write would read a half-updated selection (cloud
      // review P2). Deferring coalesces the pair into one evaluation over the
      // settled state; the second fires and no-ops.
      switch key {
      case .showBluetoothTips, .preferredInputDeviceIDOverride, .selectedInputDeviceUID,
        .onboardingState:
        DispatchQueue.main.async {
          bluetoothAwarenessPresenterHolder.presenter?.reconcile(trigger: .settingChanged)
        }
      default:
        break
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

    let navigationCoordinator = NavigationCoordinator()
    // #1386 PR-2: the one door to whichever engine is active, for the two callers
    // that never used the normal dictation doors (crash recovery, Diagnostics).
    let activeEngine = ActiveEngineOperation.live(
      asrManager: asrManager, whisperKitBackend: whisperKitBackend)

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

    let liveRecordingState = LiveRecordingState(
      kernelDriver: kernelDriver,
      whisperKitKernelDriver: whisperKitKernelDriver,
      audioCapture: audioCapture,
      asrManager: asrManager
    )
    // #1063 PR2: crash-recovery owner. The per-orphan replayer (decrypt →
    // transcribe → polish → save) is built from existing app deps; the coordinator
    // owns the launch scan, the recording gate, dedup, and cleanup routing. The
    // key store + spool-store factory are shared so arm/recover/cleanup agree on
    // backend + paths.
    let recoveryKeyStore = RecoveryKeyStore()
    let makeRecoverySpoolStore: @Sendable () -> RecoverySpoolStore = { RecoverySpoolStore() }
    let recoverySpoolReplayer = RecoverySpoolReplayer(
      activeEngine: activeEngine,
      keyStore: recoveryKeyStore,
      makeSpoolStore: makeRecoverySpoolStore,
      transcriptStore: transcriptStore,
      transcriptCoordinator: transcriptCoordinator,
      keychainManager: keychainManager,
      outputClassifierHolder: outputClassifierHolder,
      egOneRuntime: egOneRuntime,
      // Best-effort: the snapshot carries only the custom-words version, so recovery
      // applies the user's CURRENT words (pack terms omitted) — normal-quality, not
      // byte-exact. `+ 1` keeps the cache generation non-zero so terms take effect.
      currentVocabulary: { [customWordsCoordinator] in
        LanePartitioner.split(
          customWordsCoordinator.customWords,
          generation: UInt64(customWordsCoordinator.customWords.count) &+ 1)
      })
    let recoveryCoordinator = RecoveryCoordinator(
      keyStore: recoveryKeyStore,
      makeSpoolStore: makeRecoverySpoolStore,
      replayer: recoverySpoolReplayer,
      existingRecoveryIDs: { [transcriptStore] in
        let all = (try? await transcriptStore.loadAll()) ?? []
        return Set(all.compactMap(\.recoverySessionID))
      },
      isDictationActive: { [liveRecordingState] in liveRecordingState.isDictationActive },
      // Discard hard-resets the ACTIVE engine (#445 service-kill) so an in-flight,
      // otherwise-uncancellable recovery load/transcribe aborts and the next
      // recording gets a clean engine. Routed through the active-engine door
      // because recovery itself runs there: resetting only the Parakeet manager
      // would leave a WhisperKit recovery uncancellable (Codex 2b-r2 P1).
      resetEngine: { [activeEngine] in Task { await activeEngine.hardCancel() } })
    // #1063 PR2: the "recovering" pill's Discard action.
    recordingOverlay.setDiscardRecoveryHandler { [weak recoveryCoordinator] in
      recoveryCoordinator?.discardActiveRecovery()
    }
    // #1464: after a leftover recording lands in History, post the standalone green
    // success notice (the `.recovered` path was silent before).
    recoveryCoordinator.onRecoverySucceeded = { [weak recordingOverlay] in
      recordingOverlay?.show(intent: .recoverySucceeded)
    }
    // #1171 — the single owner of ASR-engine selection, status, and switching.
    // Reads the user's choice + active engine + readiness LIVE (no stored "want"
    // copies); serializes switches through one mailbox; defers while a pipeline is
    // active, recovery is replaying, or the active engine is mid-load; publishes
    // one `EngineStatus`. Built here (after recoveryCoordinator, so it can read
    // `isRecovering`; before BackendMetadata + DictationRuntime, which consume it).
    let engineCoordinator = EngineCoordinator(
      dependencies: EngineCoordinator.Dependencies(
        selectedBackend: { settings.selectedBackend },
        activeBackend: { [asrManager] in asrManager.activeBackendType },
        readiness: { [kernelDriver, whisperKitKernelDriver] backend in
          (backend == .whisperKit ? whisperKitKernelDriver : kernelDriver).engineReadiness
        },
        isEngineActive: { [kernelDriver, whisperKitKernelDriver] backend in
          (backend == .whisperKit ? whisperKitKernelDriver : kernelDriver).state.isActive
        },
        isRecovering: { [weak recoveryCoordinator] in recoveryCoordinator?.isRecovering ?? false },
        isInstalled: { [setup] backend in
          backend == .parakeet ? true : setup.whisperKitSetup.setupState == .ready
        },
        stateLabel: { [kernelDriver, whisperKitKernelDriver] backend in
          (backend == .whisperKit ? whisperKitKernelDriver : kernelDriver).state.telemetryLabel
        },
        performSwitch: { [asrManager] backend in
          await asrManager.switchBackend(to: backend)
          SentryBreadcrumb.updateASRBackend(backend.rawValue)
        },
        warm: { [kernelDriver, whisperKitKernelDriver] backend in
          await (backend == .whisperKit ? whisperKitKernelDriver : kernelDriver)
            .ensureEngineWarm(reason: .engineSwap)
        }))
    // The picker change notifies the coordinator (it reads the live selection).
    settingsSync.onSelectedBackendChanged = { [weak engineCoordinator] in
      engineCoordinator?.poke(.settingsChanged)
    }
    // #1063 PR2 / #1171: recovery never starts on top of an in-flight switch.
    recoveryCoordinator.isEngineSwitching = { [weak engineCoordinator] in
      engineCoordinator?.isSwitching ?? false
    }
    // #1171 — after a recovery scan finishes (engine free again), poke the
    // coordinator so an engine switch deferred while recovery held the engine applies.
    recoveryCoordinator.onRecoveryComplete = { [weak engineCoordinator] in
      engineCoordinator?.poke(.recoveryComplete)
    }
    let lastRecordingResult = LastRecordingResult()
    let backendMetadata = BackendMetadata(
      settings: settings,
      asrManager: asrManager,
      llmDiscovery: llmDiscovery,
      // The coordinator's published snapshot covers BOTH engines; the manager's
      // own flag is Parakeet-only since #1386 (cloud review P2).
      activeModelLoaded: { [engineCoordinator] in engineCoordinator.status.activeModelLoaded }
    )
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
    // #1171 — every pipeline state change pokes the coordinator: non-terminal
    // transitions refresh engine status; terminals apply a deferred switch.
    dictationLifecycleCoordinator.onEngineRelevantStateChange = { [weak engineCoordinator] in
      engineCoordinator?.poke(.driverStateChanged)
    }

    // PR8 of #763: heart-path event-routing home. PR10: also constructs
    // HotkeyController / RecordingStarter / RecordingFinalizer internally.
    let dictationRuntime = DictationRuntime(
      audioCapture: audioCapture,
      asrManager: asrManager,
      kernelDriver: kernelDriver,
      whisperKitKernelDriver: whisperKitKernelDriver,
      settings: settings,
      permissions: permissions,
      recordingOverlay: recordingOverlay,
      hotkeyService: hotkeyService,
      lastRecordingResult: lastRecordingResult,
      languageSuggestionPresenter: languageSuggestionPresenter,
      dictationLifecycleCoordinator: dictationLifecycleCoordinator,
      recoveryCoordinator: recoveryCoordinator,
      recordingLockedAccess: recordingLockedAccess,
      resolveActiveCaptureBackend: { [weak dictationLifecycleCoordinator] in
        dictationLifecycleCoordinator?.activeCaptureBackend()
      },
      resolveActiveTelemetryTarget: { [weak dictationLifecycleCoordinator] in
        dictationLifecycleCoordinator?.activeTelemetryTarget()
      },
      isCurrentSession: { [weak dictationLifecycleCoordinator] sessionID in
        dictationLifecycleCoordinator?.isCurrentSession(sessionID) ?? false
      },
      // #1171 — the start-of-recording safety check drives the SELECTED engine to
      // ready (the coordinator owns the single-flight switch + warm) before
      // recording, and gates a press during an in-flight switch.
      ensureSelectedReadyForPress: { [weak engineCoordinator] in
        await engineCoordinator?.ensureSelectedReadyForPress() ?? .notReady
      },
      isEngineSwitching: { [weak engineCoordinator] in engineCoordinator?.isSwitching ?? false },
      beginMinting: { [weak engineCoordinator] in engineCoordinator?.beginMinting() },
      // #1386 PR-2c (founder): a press on a removed/never-installed model shows
      // the honest not-installed pill — and a model MID-REMOVAL counts as
      // removed (founder: no new dictations during a removal drain; the drain's
      // first instants can still read installed+ready). Defaults OPEN on a
      // missing authority.
      isSelectedModelInstalled: { [weak engineCoordinator, weak setup] in
        guard let engineCoordinator else { return true }
        if engineCoordinator.status.selected == .whisperKit,
          setup?.whisperKitSetup.isRemoving == true
        {
          return false
        }
        return engineCoordinator.status.selectedInstalled
      },
      endMinting: { [weak engineCoordinator] in engineCoordinator?.endMinting() }
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

    // #1451: App Translocation recovery limb, driven from the launch sequence.
    let applicationRelocationCoordinator = ApplicationRelocationCoordinator.live()

    // #1480: Bluetooth cold-start card. Single decision owner; ingress facts come
    // from AppLifecycleCoordinator + settings.onChange. Wiring lives in `.live(...)`;
    // built before AppLifecycleCoordinator (which stores it).
    let bluetoothAwarenessPresenter = BluetoothAwarenessPresenter.live(
      overlay: recordingOverlay,
      settings: settings,
      liveRecordingState: liveRecordingState,
      navigationCoordinator: navigationCoordinator,
      appWindowCoordinator: appWindowCoordinator
    )
    bluetoothAwarenessPresenterHolder.presenter = bluetoothAwarenessPresenter

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
      hotkeyService: hotkeyService,
      applicationRelocationCoordinator: applicationRelocationCoordinator,
      bluetoothAwarenessPresenter: bluetoothAwarenessPresenter,
      onboardingProgress: onboardingProgress
    )

    self.navigationCoordinator = navigationCoordinator
    self.diagnosticsCoordinator = diagnosticsCoordinator
    self.recoveryCoordinator = recoveryCoordinator
    self.languageSuggestionPresenter = languageSuggestionPresenter
    self.updateCoordinatorHolder = updateCoordinatorHolder
    self.sparkleUpdateController = sparkleUpdateController
    self.updateTriggerCoordinator = updateTriggerCoordinator
    self.transcriptCoordinator = transcriptCoordinator
    self.liveRecordingState = liveRecordingState
    self.lastRecordingResult = lastRecordingResult
    self.backendMetadata = backendMetadata
    self.engineCoordinator = engineCoordinator
    self.dictationRuntime = dictationRuntime
    self.hotkeyService = hotkeyService
    self.appWindowCoordinator = appWindowCoordinator
    self.menuBarController = menuBarController
    self.appLifecycleCoordinator = appLifecycleCoordinator

    // PR-C.1 of #763: the nine view-facing homes.
    self.settings = settings
    self.permissions = permissions
    self.asrManager = asrManager
    self.activeEngine = activeEngine
    self.customWordsCoordinator = customWordsCoordinator
    self.contactsImportCoordinator = contactsImportCoordinator
    self.setup = setup
    self.whisperKitRetirement = whisperKitRetirement
    self.egOneRuntime = egOneRuntime
    self.modelDelivery = modelDelivery
    self.audioDeviceList = audioDeviceList
    self.inputDevicePreferenceReconciler = inputDevicePreferenceReconciler
    self.aiAvailability = aiAvailability
    self.keychainManager = keychainManager
    self.llmDiscovery = llmDiscovery
    self.vocabularyPackManager = vocabularyPackManager

    // #832/#913 PR8: App-owned output-safety classifier holder.
    self.outputClassifierHolder = outputClassifierHolder

    // #1173: App-owned settings-change telemetry observer.
    self.settingsChangeTelemetry = settingsChangeTelemetry

    // #1171 — launch the coordinator's reconcile worker + WhisperKit setup-state
    // observation and fire the initial reconcile. Wiring above (the picker /
    // recovery / driver-state pokes) is all set, so the worker drains correctly.
    // At boot active == selected (`setInitialBackendType` above), so the first
    // reconcile is a converged no-op.
    // 2c: the Remove refusal reads BOTH session authorities from their owners
    // (Codex 2c-r5 P2): the frozen-config read (PipelineSettingsSync, which
    // owns both drivers) AND the minting gate (EngineCoordinator, gate 5's
    // owner) — a start that has committed but not yet frozen its config would
    // otherwise read as "no session" and let Remove delete under it. nil
    // either way refuses, fail safe.
    setup.whisperKitSetup.isDictationInFlight = { [weak settingsSync, weak engineCoordinator] in
      (settingsSync?.isWhisperKitDictationInFlight() ?? true)
        || (engineCoordinator?.isMintingWhisperKitSession ?? true)
    }
    engineCoordinator.start()

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
    guard provider == .appleIntelligence else { return }
    Task {
      let start = DispatchTime.now()
      let outcome = await holder.beginLoadIfNeeded {
        guard let resourceURL = Bundle.main.resourceURL else {
          throw OutputClassifierError.disabled(.missingFile)
        }
        return try await CoreMLOutputClassifier.load(resourceURL: resourceURL)
      }
      let elapsedMs = Int(
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
      let plan = OutputClassifierEmissionPolicy.forOutcome(outcome)
      if let logMessage = plan.logMessage {
        await AppLogger.shared.log(logMessage, level: .info, category: "LLM")
      }
      if let category = plan.postHogErrorCategory {
        // #1177 (Telemetry Bible Phase 8): the polish path silently lost its safety
        // net. Population event for the aggregate fail-open rate, tagged by which
        // of the three observation units this is (#1452 — see
        // `OutputClassifierEmissionPolicy`). @MainActor static → direct emit.
        TelemetryService.shared.limbFailureObserved(
          limb: "output_safety", operation: "classifier_prewarm", result: "fell_open",
          errorCategory: category, durationMs: plan.attemptedRealLoad ? elapsedMs : nil)
      }
      if let sentryReason = plan.sentryReason {
        // #1452: at most one alert per process per disablement — repeated
        // provider-switch triggers after this point return
        // `.skippedPermanentlyDisabled` and never reach this branch again.
        SentryBreadcrumb.captureError(
          OutputClassifierError.disabled(sentryReason), category: .outputClassifierLoadFailed,
          stage: "llm", fingerprintDetail: sentryReason.rawValue)
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
    // #1029: install the notification tap delegate eagerly at launch (decoupled
    // from posting) so a tap on an already-delivered "update ready" notification —
    // or a cold launch from it — always routes, even when the once-per-version
    // guard suppresses a fresh post on rehydrate.
    sparkleUpdateController.updateCoordinator?.activateNotificationTapRouting()
    // #958: proactive launch check, right after startUpdater per Sparkle guidance.
    sparkleUpdateController.updateCoordinator?.checkForUpdatesProactively(trigger: "launch")
    // #1019: begin observing wake / network for an always-on, windowless user.
    updateTriggerCoordinator.start()
  }

  public func applicationDidFinishLaunching() {
    appLifecycleCoordinator.runDidFinishLaunching()
    // #1063 PR2: scan for orphan crash-recovery spools and recover them behind the
    // blocking "recovering" pill (replaces PR1's purge). Strict limb, single-flight,
    // one attempt per orphan. No-orphan launch is byte-identical to today.
    Task { await recoveryCoordinator.scanAndRecover() }
  }

  public func applicationDidBecomeActive() {
    appLifecycleCoordinator.runDidBecomeActive()
    // #958: proactive foreground check (post-sleep freshness), strict >=3600 gated.
    sparkleUpdateController.updateCoordinator?.checkForUpdatesProactively(trigger: "foreground")
  }

  public func applicationWillTerminate() {
    // #1271: kill the EG-1 child SYNCHRONOUSLY — `Process` children survive
    // parent exit (Codex r1 proved empirically); crash orphans are reaped by
    // the stale-sweep in EGOneServerManager.start on next launch.
    egOneRuntime.terminateServerForAppQuit()
    // #1019: tear down the network path monitor + wake observer.
    updateTriggerCoordinator.stop()
    // #1176: a Cocoa quit during onboarding is an abandon (best-effort — kill -9
    // bypasses this). Capture BEFORE the Phase-1 flush in runWillTerminate so it is
    // durable. Deduped by the box's terminal guard (a clean finish or a prior
    // window-close abandon suppresses it).
    onboardingProgress.emitAbandonIfInFlight(
      reason: "app_quit", micStatus: permissions.microphoneStatusString,
      // Live read so a just-before-quit grant isn't logged denied (cloud Codex r3).
      accessibilityStatus: permissions.accessibilityGrantedLive ? "granted" : "denied")
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
      // 750 = two-card frame chrome (outer inset 28 + sidebar 200 + spacing 14 =
      // 242) + the History split floors inside the detail card (230+8+260=498),
      // so the window can never crush the History split (#1024; #1296 frame).
      .frame(minWidth: 750, minHeight: 400)
      .environment(b.navigationCoordinator)
      .environment(b.diagnosticsCoordinator)
      .environment(b.languageSuggestionPresenter)
      .environment(b.updateCoordinatorHolder)
      .environment(b.transcriptCoordinator)
      .environment(b.liveRecordingState)
      .environment(b.lastRecordingResult)
      .environment(b.backendMetadata)
      .environment(b.engineCoordinator)
      .environment(b.modelDelivery)
      .environment(b.dictationRuntime)
      .environment(b.appWindowCoordinator)
      // The nine view-facing homes (epic #763).
      .environment(b.settings)
      .environment(b.permissions)
      .environment(b.customWordsCoordinator)
      .environment(b.contactsImportCoordinator)
      .environment(b.setup)
      .environment(b.egOneRuntime)
      .environment(b.audioDeviceList)
      .environment(b.aiAvailability)
      .environment(b.llmDiscovery)
      .environment(b.vocabularyPackManager)
      .environment(\.asrManager, b.asrManager)
      .environment(\.activeEngine, b.activeEngine)
      .environment(\.keychainManager, b.keychainManager)
      .background(
        ActionWirer(
          settings: b.settings,
          appWindowCoordinator: b.appWindowCoordinator,
          menuBarController: b.menuBarController,
          onboardingProgress: b.onboardingProgress,
          isOnboardingPresented: $isOnboardingPresented
        )
      )
  }
}

/// The onboarding window's root view.
private struct OnboardingWindowRoot: View {
  let b: WisprBootstrapper

  var body: some View {
    OnboardingV2View(
      onComplete: { b.appWindowCoordinator.closeOnboardingWindow() },
      onboardingProgress: b.onboardingProgress
    )
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
    .environment(\.activeEngine, b.activeEngine)
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
  /// #1176: begin a fresh onboarding session on every window open (first-run AND
  /// Diagnostics restart both funnel through `openOnboardingAction`).
  let onboardingProgress: OnboardingProgress
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
        appWindowCoordinator.openOnboardingAction = { [openWindow, onboardingProgress, settings] in
          // #1176: every onboarding presentation funnels through here. `begin` starts
          // a fresh session only when none is in flight, so a refocus of the open
          // window (status-menu "Continue Setup…") never rewinds it — see the guard
          // in `OnboardingProgress.begin`. `source` reads the durable everCompleted
          // flag from the shared settings store.
          let source = settings.onboardingEverCompleted ? "diagnostics_restart" : "first_run"
          onboardingProgress.begin(source: source)
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

/// Pure mapping from a classifier-load outcome to what `WisprBootstrapper`
/// should log, count, and alert. Colocated with the sole caller
/// (`prewarmOutputClassifierIfNeeded`); stateless and dependency-free (no
/// `TelemetryService`/`SentryBreadcrumb` import) so the outcome→emission
/// decision — the actual alert-dedup contract — is independently unit-testable
/// without touching Sentry or PostHog. #1452.
struct OutputClassifierEmissionPolicy: Equatable {
  let logMessage: String?
  let postHogErrorCategory: String?
  let sentryReason: OutputClassifierDisabledReason?
  /// True only when this call actually attempted a load (so `elapsedMs` is a
  /// real, meaningful duration) — false for suppressed repeats, which measure
  /// nothing because no load was attempted. Kept as an explicit field rather
  /// than inferring it from `sentryReason == nil`, which is also nil for
  /// `.failedRetryable` (a real attempt that just isn't alert-worthy).
  let attemptedRealLoad: Bool

  static func forOutcome(_ outcome: OutputClassifierAttemptOutcome) -> Self {
    switch outcome {
    case .skippedAlreadyReady, .skippedLoadInProgress:
      return .init(
        logMessage: nil, postHogErrorCategory: nil, sentryReason: nil, attemptedRealLoad: false)
    case .succeeded:
      return .init(
        logMessage: "[OutputClassifier] preWarm complete", postHogErrorCategory: nil,
        sentryReason: nil, attemptedRealLoad: true)
    case .skippedPermanentlyDisabled(let reason):
      // Suppressed repeat: counted (unit = "provider-triggered observation of an
      // already-disabled classifier"), never re-alerted — this IS the fix.
      return .init(
        logMessage: nil, postHogErrorCategory: "suppressed_repeat:\(reason.rawValue)",
        sentryReason: nil, attemptedRealLoad: false)
    case .failedFirstTime(let reason):
      return .init(
        logMessage: "[OutputClassifier] preWarm failed reason=\(reason.rawValue) — fail open",
        postHogErrorCategory: "attempted_load:\(reason.rawValue)", sentryReason: reason,
        attemptedRealLoad: true)
    case .failedRetryable(let category):
      // Not the classifier's fault (cancellation / unknown transient error) — counted,
      // never alerted, and the holder itself already allows a later retry.
      return .init(
        logMessage: nil, postHogErrorCategory: "retryable:\(category)", sentryReason: nil,
        attemptedRealLoad: true)
    }
  }
}
