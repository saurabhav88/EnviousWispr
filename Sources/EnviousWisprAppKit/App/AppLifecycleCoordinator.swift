import AppKit
import EnviousWisprASR
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprPipeline
import EnviousWisprServices
import Foundation

// Issue #574: `EnviousWisprAudio` and `EnviousWisprASR` are needed in release
// builds because `AudioSystemEventReporter` (production telemetry) references
// `AudioCaptureInterface` and `ASRManagerInterface` from those modules.
// PR-C.3 of #763: `EnviousWisprPipeline` is now an unconditional import — the
// `KernelDictationDriver` homes are stored properties (still read only by
// `DebugFaultEndpoint` in debug builds). PR-5 Rung 5 (#827) flipped the
// WhisperKit home from the legacy `WhisperKitPipeline` to a second
// `KernelDictationDriver`.

/// PR-B.4 of #763: App-owned home for the process-lifecycle sequence.
///
/// Coordinates the launch / foreground-activation / termination side effects
/// that were previously inlined in `AppDelegate`'s `NSApplicationDelegate`
/// callbacks. `EnviousWisprApp` owns this as `@State`; `AppDelegate` holds a
/// weak ref and forwards its three lifecycle callbacks here. The three `run*`
/// methods are verbatim relocations of the corresponding `AppDelegate`
/// callback bodies — same launch order, same telemetry, same teardown.
@MainActor
final class AppLifecycleCoordinator {
  // Owned process-lifetime objects: constructed in `runDidFinishLaunching`,
  // torn down in `runWillTerminate`.
  private var audioEnvironmentSnapshotter: AudioEnvironmentSnapshotter?
  // periphery:ignore - retain anchor: owns audio-system observer lifetime
  private var audioSystemEventReporter: AudioSystemEventReporter?

  #if DEBUG
    /// V2 fault-injection control surface (issue #291). Started only when
    /// `EW_FAULT_INJECTION=1` is set in the launching environment. Stopped in
    /// `runWillTerminate`. Compiled out of release entirely.
    private var debugFaultEndpoint: DebugFaultEndpoint?
  #endif

  // Injected dependencies — delegated to, never owned.
  // PR-C.3 of #763: the single `appState` reference is replaced by the 10
  // specific homes the launch/become-active/terminate bodies actually read.
  private let settings: SettingsManager
  private let permissions: PermissionsService
  private let keychainManager: KeychainManager
  private let customWordsCoordinator: CustomWordsCoordinator
  private let contactsImportCoordinator: ContactsImportCoordinator
  private let aiAvailability: AIAvailabilityCoordinator
  private let audioCapture: any AudioCaptureInterface
  private let asrManager: any ASRManagerInterface
  private let kernelDriver: KernelDictationDriver
  private let whisperKitKernelDriver: KernelDictationDriver
  private let setup: SetupCoordinator
  private let dictationRuntime: DictationRuntime
  private let dictationLifecycleCoordinator: DictationLifecycleCoordinator
  private let liveRecordingState: LiveRecordingState
  private let menuBarController: MenuBarController
  private let appWindowCoordinator: AppWindowCoordinator
  private let hotkeyService: HotkeyService
  // #1451: launch-time App Translocation recovery limb. Called once on launch;
  // never a prerequisite for anything below it.
  private let applicationRelocationCoordinator: ApplicationRelocationCoordinator
  // #1480: forwards launch / device-change / pipeline-state facts to the
  // Bluetooth awareness card's single decision owner. The coordinator carries no
  // Bluetooth predicate, overlay branching, or once-per-launch state — it only
  // hands the presenter a `Trigger` fact.
  private let bluetoothAwarenessPresenter: BluetoothAwarenessPresenter
  /// #1707 Phase 2: DEBUG fault-injection oracle (§11.1/§3.2a-i), forwarded
  /// into `DebugFaultEndpoint`'s construction below — a deliberate, explicit
  /// stored-property allowlist addition (`AppLifecycleCoordinatorCeilingsTests.swift`),
  /// not a workaround around it: the ceilings test exists to catch accidental
  /// growth, and this is one genuinely new capability adding exactly one
  /// dependency.
  private let batchDecodeFaultController: BatchDecodeFaultController?

  init(
    settings: SettingsManager,
    permissions: PermissionsService,
    keychainManager: KeychainManager,
    customWordsCoordinator: CustomWordsCoordinator,
    contactsImportCoordinator: ContactsImportCoordinator,
    aiAvailability: AIAvailabilityCoordinator,
    audioCapture: any AudioCaptureInterface,
    asrManager: any ASRManagerInterface,
    kernelDriver: KernelDictationDriver,
    whisperKitKernelDriver: KernelDictationDriver,
    setup: SetupCoordinator,
    dictationRuntime: DictationRuntime,
    dictationLifecycleCoordinator: DictationLifecycleCoordinator,
    liveRecordingState: LiveRecordingState,
    menuBarController: MenuBarController,
    appWindowCoordinator: AppWindowCoordinator,
    hotkeyService: HotkeyService,
    applicationRelocationCoordinator: ApplicationRelocationCoordinator,
    bluetoothAwarenessPresenter: BluetoothAwarenessPresenter,
    // #1176: captured in the onboarding-dismiss closure below (NOT stored — keeps
    // this coordinator's stored-property ceiling clean).
    onboardingProgress: OnboardingProgress,
    batchDecodeFaultController: BatchDecodeFaultController? = nil
  ) {
    self.settings = settings
    self.permissions = permissions
    self.keychainManager = keychainManager
    self.customWordsCoordinator = customWordsCoordinator
    self.contactsImportCoordinator = contactsImportCoordinator
    self.aiAvailability = aiAvailability
    self.audioCapture = audioCapture
    self.asrManager = asrManager
    self.kernelDriver = kernelDriver
    self.whisperKitKernelDriver = whisperKitKernelDriver
    self.setup = setup
    self.dictationRuntime = dictationRuntime
    self.dictationLifecycleCoordinator = dictationLifecycleCoordinator
    self.liveRecordingState = liveRecordingState
    self.menuBarController = menuBarController
    self.appWindowCoordinator = appWindowCoordinator
    self.hotkeyService = hotkeyService
    self.applicationRelocationCoordinator = applicationRelocationCoordinator
    self.bluetoothAwarenessPresenter = bluetoothAwarenessPresenter
    self.batchDecodeFaultController = batchDecodeFaultController
    // Icon-refresh seam: the window coordinator's two onboarding-dismiss
    // callsites route through this closure. Was wired in `AppDelegate.attach`
    // before PR-B.4.
    appWindowCoordinator.onOnboardingDismissed = {
      [weak menuBarController, onboardingProgress, permissions] in
      menuBarController?.updateIcon()
      // #1176: the window closed before completion → record the abandon (deduped
      // by the box's terminal guard, so a clean finish or a prior quit suppresses it).
      onboardingProgress.emitAbandonIfInFlight(
        reason: "window_closed",
        micStatus: permissions.microphoneStatusString,
        // Live read (not the cached `accessibilityGranted`): a grant made in System
        // Settings just before this close may not have hit the poll yet (cloud Codex
        // review r3). Pure no-prompt read, no side effects.
        accessibilityStatus: permissions.accessibilityGrantedLive ? "granted" : "denied")
    }
  }

  func runDidFinishLaunching() {
    // Hide dock icon on launch — we're a menu bar utility.
    // If onboarding is needed, stay .regular so SwiftUI creates the main window
    // hierarchy and ActionWirer can wire callbacks before opening the
    // onboarding window.
    if settings.onboardingState == .completed {
      NSApp.setActivationPolicy(.accessory)
    }

    // #1451: recover from App Translocation. Runs on EVERY launch (NOT gated by
    // onboarding — the 14 stuck users already finished onboarding), returns
    // immediately after scheduling any prompt, and is a limb: it never blocks
    // the launch sequence below.
    applicationRelocationCoordinator.evaluateAndOfferIfNeeded()

    // #879: the launch-preload telemetry callback wiring was removed. The
    // launch warm-up now routes through `KernelDictationDriver.ensureEngineWarm
    // (reason: .launch)`, which emits `launch.model_preload_completed` directly
    // (it depends on `EnviousWisprServices`, so no cross-module callback hop is
    // needed the way the ASR-layer reporter required).

    // PR-B.2 of #763: the window-close observer lives on AppWindowCoordinator.
    appWindowCoordinator.installOnLaunch()

    // PR-B.3 of #763: the menu bar surface lives on `MenuBarController`.
    menuBarController.installStatusItem()

    // #1386 PR-2: the app is now on screen, so the multilingual migration may
    // look in ~/Documents — the one phase that can raise a Files-and-Folders
    // prompt, which must never appear before there is an app behind it. Owned by
    // `SetupCoordinator` (it already owns this engine's setup lifecycle), so no
    // new dependency lands on this coordinator. A limb: never blocks launch, and
    // a denied prompt leaves the user's copy untouched.
    setup.startWhisperKitMigrationThenDetect()

    // Update menu bar icon whenever pipeline state changes. The closure is
    // composite — it also triggers the audio-environment snapshotter on
    // `.recording`. PR-B.4 of #763: both the snapshotter and this closure now
    // live in `AppLifecycleCoordinator`, so the closure is one coherent unit.
    dictationLifecycleCoordinator.onPipelineStateChange = { [weak self] state in
      guard let self else { return }
      self.menuBarController.updateIcon()
      // Issue #739: do NOT forward pipeline state to the update widget. The
      // widget is bundle-version-driven only — visible whenever an update is
      // pending, matching Claude Desktop / Slack / Cursor conventions.
      if state == .recording {
        self.audioEnvironmentSnapshotter?.recordingStarted()
      }
      // #1480: any pipeline-state change re-evaluates the Bluetooth card — a
      // record start supersedes + dismisses it (records `record_started`); a
      // return to idle lets a not-yet-shown card surface (scenario 4). Deferred to
      // the next run-loop cycle because this callback fires at the TOP of the
      // pipeline handler, BEFORE the terminal overlay intent clears the recording
      // pill (cloud review P2); reconcile must observe the settled `.hidden` slot,
      // else the "Bluetooth connected mid-recording, show when idle returns" case
      // is suppressed. Mirrors how the language chip surfaces after the overlay
      // handler (`DictationLifecycleCoordinator.dispatchChipLifecycle`). Card
      // teardown stays synchronous (single-slot dedup); only this bookkeeping/
      // show re-check is deferred, so the §3D supersession contract holds.
      DispatchQueue.main.async { [weak self] in
        self?.bluetoothAwarenessPresenter.reconcile(trigger: .pipelineStateChanged)
      }
    }

    // Start hotkeys now that the event loop is running.
    // Carbon RegisterEventHotKey requires an active run loop for event delivery.
    dictationRuntime.startHotkeyServiceIfEnabled()

    // Telemetry Bible Phase 1 (#1170): supply `active_recording` / `app_phase`
    // to every telemetry flush (Sparkle pre-relaunch + normal-quit terminate)
    // without coupling the sink to pipeline types. Wired here at launch, before
    // any flush path can fire, so the provider is never nil in production.
    TelemetryService.shared.flushContextProvider = { [weak self] in
      let phase = self?.liveRecordingState.pipelineState ?? .idle
      return TelemetryService.FlushContext(
        activeRecording: phase.isActive, appPhase: phase.telemetryLabel)
    }

    // Run Apple Intelligence diagnostics via coordinator.
    // Handles: Sentry context, PostHog event, persistence, first-launch re-check.
    let isFreshInstall = settings.onboardingState != .completed
    if isFreshInstall {
      aiAvailability.firstLaunchCheck()
    } else {
      Task { await aiAvailability.checkAvailability(trigger: "app_launch") }
    }

    // Fire structured app.launched event (issue #1073). Compute the AI snapshot
    // OFF the launch main thread: the eligibility read (SystemLanguageModel
    // .availability) is synchronous but its cold-boot cost on the main thread is
    // not provable-safe (council + grounded review), so it must never sit on the
    // heart-adjacent launch path. Hop back to the @MainActor TelemetryService to
    // emit (no second telemetry path). The event emits within ms of launch (far
    // faster than awaiting the up-to-10s deep checkAvailability above), though as
    // a detached emit it is best-effort and may be missed on an immediate quit.
    // Task.detached (not Task {}): a plain Task inherits this MainActor context
    // and would run the read on main; withTaskGroup/@concurrent do not fit a
    // one-off fire-and-forget that must leave the actor.
    let version =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    let osVer = ProcessInfo.processInfo.operatingSystemVersion
    let osVersion = "\(osVer.majorVersion).\(osVer.minorVersion).\(osVer.patchVersion)"
    Task.detached(priority: .utility) {
      let snap = AppleIntelligenceDiagnosticsService.launchSnapshot()
      await TelemetryService.shared.appLaunched(
        version: version, build: build, osVersion: osVersion,
        hardware: snap.hardwareClass, isFreshInstall: isFreshInstall,
        aiCapable: snap.isCapable, aiEnabled: snap.isEnabled)
    }

    // Check Accessibility permission on launch (query only — never auto-prompt).
    permissions.refreshOnLaunch()
    menuBarController.updateIcon()  // Reflect accessibility warning state in icon.

    // Begin smart polling if Accessibility is not yet granted.
    permissions.startMonitoring()

    if settings.onboardingState == .completed {
      // Telemetry Bible Phase 0 (#1169) seam, extended by Phase 3 (#1172) with
      // microphone / Accessibility posture. Emitted AFTER refreshOnLaunch() so
      // the posture fields reflect the settled launch state — in particular
      // accessibility_warning_dismissed, which refreshOnLaunch() resets to false
      // when Accessibility is denied (Codex code-diff review caught the stale
      // pre-refresh read). The seven pre-existing settings fields are unaffected
      // by ordering.
      StandingSnapshotBuilder(
        settings: settings,
        keychainManager: keychainManager,
        customWordsCoordinator: customWordsCoordinator,
        permissions: permissions
      ).emit()

      // #1480: first launch-time evaluation of the Bluetooth card, after
      // refreshOnLaunch() settled the launch state. Runs only for completed
      // onboarding (onboarding owns the window otherwise); the presenter's own
      // guards re-check Bluetooth / idle / tips-enabled. A headset that connects
      // later is covered by the device-change ingress.
      bluetoothAwarenessPresenter.reconcile(trigger: .launch)
    }

    // Pre-warm LLM backend with a real inference request.
    LLMNetworkSession.shared.preWarmModel(
      provider: settings.llmProvider,
      model: settings.llmModel,
      keychainManager: keychainManager
    )

    // #636: opt-in launch re-scan of Contacts. Add-only, off the launch path —
    // an unawaited background Task so a slow Contacts read never blocks launch.
    // Limb: the coordinator itself no-ops unless access is granted.
    if settings.contactsSyncOnLaunchEnabled {
      Task { await contactsImportCoordinator.syncNewContacts() }
    }

    // Onboarding auto-open is handled by ActionWirer inside the main Window
    // scene. No deferred dispatch required here.

    #if DEBUG
      // V2 fault-injection (issue #291). Only when explicitly opted in via env var.
      if DebugFaultEndpoint.isRequested {
        let endpoint = DebugFaultEndpoint(
          audioCapture: audioCapture as? AudioCaptureManager,
          asrProxy: asrManager as? ASRManagerProxy,
          kernelDriver: kernelDriver,
          whisperKitKernelDriver: whisperKitKernelDriver,
          activeBackend: { [weak self] in
            self?.settings.selectedBackend ?? .parakeet
          },
          batchDecodeFaultController: batchDecodeFaultController
        )
        endpoint.start()
        debugFaultEndpoint = endpoint
      }
    #endif

    audioEnvironmentSnapshotter = AudioEnvironmentSnapshotter(
      routeProvider: { [weak self] in
        self?.audioCapture.currentAudioRoute
      }
    )
    SentryBreadcrumb.audioEnvironmentProvider = { [weak self] in
      self?.audioEnvironmentSnapshotter?.latestForError()
    }

    // Production telemetry: OS-level audio events (issue #574). Always on in
    // release; ships to all users so we get cross-user data on what real
    // devices/routes/connections users actually hit.
    audioSystemEventReporter = AudioSystemEventReporter(
      audioCapture: audioCapture,
      asrManager: asrManager,
      pipelineStateProvider: { [weak self] in
        // PR7 of #763: pipeline phase resolves through LiveRecordingState.
        self?.liveRecordingState.pipelineState ?? .idle
      },
      onAudioDeviceEvent: { [weak self] in
        self?.audioEnvironmentSnapshotter?.audioDeviceEventOccurred()
        // #1480: a device connect/disconnect/default-change re-evaluates the
        // Bluetooth card (covers connect-later, and route-off dismissal).
        self?.bluetoothAwarenessPresenter.reconcile(trigger: .deviceChanged)
      }
    )
  }

  func runDidBecomeActive() {
    audioEnvironmentSnapshotter?.applicationBecameActive()

    // Re-warm LLM backend when app comes to foreground.
    LLMNetworkSession.shared.preWarmModel(
      provider: settings.llmProvider,
      model: settings.llmModel,
      keychainManager: keychainManager
    )
  }

  func runWillTerminate() {
    // Telemetry Bible Phase 1 (#1170): best-effort at-quit delivery attempt +
    // a durable clean-quit marker (carries active_recording / app_phase).
    // Non-blocking: PostHog flush() only schedules delivery, and capture() has
    // already persisted events to disk, so nothing is lost if the scheduled
    // send doesn't finish before exit. Runs FIRST so the context reflects the
    // real in-flight phase (teardown below resets pipeline state). Crash-time
    // flush is intentionally absent — native crash handlers can't safely do
    // async network; pre-crash events survive via PostHog's disk queue.
    TelemetryService.shared.flushTelemetry(reason: .appTerminate)

    // PR-B.2 of #763: both window-close observers are torn down by the
    // coordinator now.
    appWindowCoordinator.tearDown()
    setup.ollamaSetup.cleanup()
    // PR10 of #763 — shared HotkeyService is owned by EnviousWisprApp as
    // `@State`; this coordinator holds an injected ref.
    hotkeyService.stop()
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
}
