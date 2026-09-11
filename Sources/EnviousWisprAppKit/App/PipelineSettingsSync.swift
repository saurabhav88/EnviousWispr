import EnviousWisprASR
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprPipeline
import EnviousWisprServices
import Foundation

/// Forwards live-mutable settings changes. Per-recording values are frozen
/// via `DictationSessionConfig` at `startRecording` and do not flow here —
/// see #195 plan for the full frozen/live classification.
@MainActor
final class PipelineSettingsSync {
  private let kernelDriver: KernelDictationDriver
  private let whisperKitKernelDriver: KernelDictationDriver
  private let audioCapture: any AudioCaptureInterface
  private let asrManager: any ASRManagerInterface
  private let hotkeyService: HotkeyService

  /// #1171 — fired when the user changes the engine picker. The composition root
  /// binds this to `EngineCoordinator.poke(.settingsChanged)`; the coordinator is
  /// the SOLE owner of engine selection / status / switching, so this settings
  /// fanout only forwards the trigger (it no longer stores any "want" state or
  /// calls `switchBackend`). Settable because the coordinator is built after this
  /// home; default no-op keeps legacy/test construction unchanged.
  var onSelectedBackendChanged: () -> Void = {}

  /// #2108: fired when Live Preview is switched OFF, so the limb can release a
  /// cached engine. Same shape as `onSelectedBackendChanged` above: a closure the
  /// composition root wires, so this type still learns nothing about the preview.
  var onLivePreviewDisabled: () -> Void = {}
  /// #2123: the chosen preview engine changed. Separate from the disabled hook
  /// because the two mean different things — "stop previewing" versus "preview
  /// with something else" — and a single hook would have to re-derive which.
  var onLivePreviewEngineChanged: () -> Void = {}

  /// Tracks the last evictable Ollama model for #295. Independent of the
  /// kernel's polish step because SettingsManager's cascading didSet can
  /// corrupt a pre-snapshot read from the polish step.
  private var lastEvictableOllamaModel: String?

  /// The import's counterpart (#2772). With dictation on another provider, an import can
  /// load its own Ollama model and leave it resident for the keep-alive window; tracking
  /// only dictation's model meant an import swap evicted nothing. Found by the cloud review
  /// of PR #2786, the same class as every other import-surface reach into shared engine
  /// state: the reconciler was keyed on dictation's settings alone.
  private var lastEvictableImportOllamaModel: String?

  /// #1914: is this Ollama model one the daemon proxies to Ollama's servers?
  ///
  /// `true` proven remote · `false` proven local · **`nil` absent from the
  /// catalog**, which is a THIRD answer and not a synonym for either. Only
  /// `true` suppresses eviction; `nil` falls through to today's behaviour.
  ///
  /// Required, with no default. A defaulted lookup would silently answer for a
  /// composition root that forgot to wire it, and "silently answers" is the
  /// entire defect class this epic removes.
  private let ollamaRemotenessLookup: (String) -> Bool?

  /// #1914 test seam. Nil uses the production scheduler, which still routes
  /// through `LLMPolishStep.evictPreviousOllamaModel`.
  ///
  /// Shaped as an optional OVERRIDE rather than a defaulted closure (the shape
  /// `LLMPolishStep.evictOllamaModel` uses) because the production default
  /// needs `self.kernelDriver`, and a stored property cannot reference `self`
  /// in its own initializer. The alternative — a no-op default reassigned in
  /// `init` — would leave a closure that silently disables eviction for any
  /// future initializer that forgot to overwrite it.
  ///
  /// It exists because suppression happens BEFORE any connector call, so the
  /// connector's own `networkExecutor` seam is downstream of the gate and
  /// cannot observe a request that was never scheduled.
  var evictionScheduler: ((String) -> Void)?

  /// #2648 — see the initializer parameter of the same name.
  private let importPinnedLocalProvider: @MainActor () -> LLMProvider?

  /// #2648 — the Ollama model a RUNNING file import froze, or nil.
  private let importPinnedOllamaModel: @MainActor () -> String?

  init(
    kernelDriver: KernelDictationDriver,
    whisperKitKernelDriver: KernelDictationDriver,
    audioCapture: any AudioCaptureInterface,
    asrManager: any ASRManagerInterface,
    hotkeyService: HotkeyService,
    egOneRuntime: EGOneRuntime? = nil,
    s1MiniRuntime: EGOneRuntime? = nil,
    ollamaRemotenessLookup: @escaping (String) -> Bool?,
    /// #2648 — the bundled local polisher a RUNNING file import has frozen, or
    /// nil.
    ///
    /// `pinnedLocalProvider()` reads the two dictation drivers' session configs,
    /// and an import has no session config, so switching provider mid-import
    /// deactivated the very server the import was polishing through and the
    /// remaining parts came back raw. Found by cloud review. Defaults to nil so
    /// every existing construction is unchanged.
    importPinnedLocalProvider: @escaping @MainActor () -> LLMProvider? = { nil },
    /// #2648 — the Ollama model a RUNNING file import froze, or nil.
    ///
    /// `isOllamaModelPinnedInFlight` reads the two DICTATION drivers' session
    /// configs, and an import has no session config, so its frozen model was
    /// unprotected: a provider or model change elsewhere in Settings evicted the
    /// weights the remaining passages were about to use, and each one then paid
    /// a reload it could exceed its polish deadline waiting for. Found by Codex.
    /// Defaults to nil so every existing construction is unchanged.
    importPinnedOllamaModel: @escaping @MainActor () -> String? = { nil }
  ) {
    self.importPinnedLocalProvider = importPinnedLocalProvider
    self.importPinnedOllamaModel = importPinnedOllamaModel
    self.kernelDriver = kernelDriver
    self.whisperKitKernelDriver = whisperKitKernelDriver
    self.audioCapture = audioCapture
    self.asrManager = asrManager
    self.hotkeyService = hotkeyService
    self.egOneRuntime = egOneRuntime
    self.s1MiniRuntime = s1MiniRuntime
    self.ollamaRemotenessLookup = ollamaRemotenessLookup
    // #1271 matrix gap 3: Remove Model defers while a recording froze
    // `.egOne`. The pinned-session authority is THIS class (it owns both
    // drivers), so it wires the runtime's read itself.
    egOneRuntime?.isPinnedInFlight = { [weak self] in
      self?.pinnedLocalProvider() == .egOne
    }
    // #2649: each engine's Remove refusal asks about ITS OWN frozen session.
    // Sharing EG-1's answer would refuse an S1-mini removal while an EG-1 take
    // was running, and allow one while an S1-mini take was.
    s1MiniRuntime?.isPinnedInFlight = { [weak self] in
      self?.pinnedLocalProvider() == .s1Mini
    }
    // #2649 (cloud review P1): a direct activation (refresh button, completed
    // download) must not evict the engine a running take froze. Same authority
    // as `reconcileEGOneActivation`'s own defer, wired to the two entry points
    // that do not pass through it.
    egOneRuntime?.isBlockedByOtherPinnedSession = { [weak self] in
      guard let pinned = self?.pinnedLocalProvider() else { return false }
      return pinned != .egOne
    }
    s1MiniRuntime?.isBlockedByOtherPinnedSession = { [weak self] in
      guard let pinned = self?.pinnedLocalProvider() else { return false }
      return pinned != .s1Mini
    }
  }

  /// #1271 (Codex r2): EG-1 server lifecycle follows the PROVIDER SETTING,
  /// and this class is the canonical settings→pipeline side-effect route
  /// (same home as the Ollama eviction below). Switch to EG-1 → server up +
  /// probe; switch away → server down (a multi-GB child never lingers past
  /// its selection, the #295 RAM lesson).
  private let egOneRuntime: EGOneRuntime?
  /// #2649: the second local engine. Switching TO it must start it, and
  /// switching AWAY must stop it, exactly as EG-1 does.
  private let s1MiniRuntime: EGOneRuntime?

  /// Seed live-mutable subsystems. Per-recording values are captured fresh
  /// at each `startRecording` and are not seeded here.
  ///
  /// Custom words are NOT seeded here — `CustomWordsPropagator` (registered
  /// in the former root state init) owns that fanout. See Phase D (#496).
  func applyInitialSettings(_ settings: SettingsManager) {
    kernelDriver.wordCorrection.wordCorrectionEnabled = settings.wordCorrectionEnabled
    kernelDriver.fillerRemoval.fillerRemovalEnabled = settings.fillerRemovalEnabled
    kernelDriver.emojiFormatter.emojiFormatterEnabled = settings.emojiFormatterEnabled
    whisperKitKernelDriver.wordCorrection.wordCorrectionEnabled = settings.wordCorrectionEnabled
    whisperKitKernelDriver.fillerRemoval.fillerRemovalEnabled = settings.fillerRemovalEnabled
    whisperKitKernelDriver.emojiFormatter.emojiFormatterEnabled = settings.emojiFormatterEnabled
    kernelDriver.spokenPunctuationEnabled = settings.spokenPunctuationEnabled
    whisperKitKernelDriver.spokenPunctuationEnabled = settings.spokenPunctuationEnabled

    audioCapture.selectedInputDeviceUID = settings.selectedInputDeviceUID
    audioCapture.preferredInputDeviceIDOverride = settings.preferredInputDeviceIDOverride
    audioCapture.inputChannelByDeviceUID = settings.inputChannelByDeviceUID
    audioCapture.warmEnginePolicy = settings.warmEnginePolicy
    audioCapture.configureVAD(
      autoStop: settings.vadAutoStop,
      silenceTimeout: settings.vadSilenceTimeout,
      sensitivity: settings.vadSensitivity,
      energyGate: settings.vadEnergyGate
    )

    // #295: seed eviction trackers. No initial eviction on app launch.
    lastEvictableOllamaModel = OllamaConnector.effectiveOllamaModel(
      provider: settings.llmProvider, model: settings.effectiveLLMModel
    )
    lastEvictableImportOllamaModel = OllamaConnector.effectiveOllamaModel(
      provider: settings.effectiveFileImportLLMProvider,
      model: settings.effectiveFileImportLLMModel
    )

    // #728: AppLogger defaults to debug=off / level=.info. Sync the persisted
    // values at launch so the file handle opens (or stays closed) according
    // to the user's saved preference instead of requiring a toggle off-then-on.
    // Capture values upfront so the unstructured Task is not racing settings
    // mutation. Level is set first so the file-open log line in `setDebugMode`
    // is not filtered out when the saved level is more permissive than .info.
    let logLevel = settings.debugLogLevel
    let debugEnabled = settings.isDebugModeEnabled
    Task {
      await AppLogger.shared.setLogLevel(logLevel)
      await AppLogger.shared.setDebugMode(debugEnabled)
    }
  }

  /// #1305: whether a `.llmModel` change should mirror into `ollamaModel` (the
  /// remembered Ollama preference). "" means "nothing armed" — discovery found
  /// no installed models — and must never overwrite the remembered preference,
  /// which powers the Download-suggestion copy in Settings. Non-empty picks
  /// mirror exactly as before. Pure + static so it is directly unit-testable.
  static func shouldMirrorLLMModelToOllama(provider: LLMProvider, llmModel: String) -> Bool {
    provider == .ollama && !llmModel.isEmpty
  }

  /// Handle a settings change by forwarding to the appropriate subsystem.
  func handleSettingChanged(_ key: SettingsManager.SettingKey, settings: SettingsManager) {
    switch key {
    case .selectedBackend:
      // #1171 — the EngineCoordinator owns engine selection, status, and the
      // switch operation (it reads `settings.selectedBackend` live, serializes
      // switches through a single mailbox, and defers while recording/recovering).
      // This fanout only notifies it of the picker change.
      onSelectedBackendChanged()
    case .recordingMode:
      hotkeyService.recordingMode = settings.recordingMode
    case .llmProvider:
      // Eviction fires for RAM management (#295). Pipeline polish uses the
      // frozen value from `DictationSessionConfig`; live steps are seeded per
      // recording, so nothing to mirror here since #1106 removed re-polish.
      reconcileOllamaEviction(settings: settings)
      // #1271: EG-1 server follows the provider selection live.
      reconcileEGOneActivation(settings: settings)
    case .llmModel:
      if Self.shouldMirrorLLMModelToOllama(
        provider: settings.llmProvider, llmModel: settings.llmModel)
      {
        settings.ollamaModel = settings.llmModel
      }
      reconcileOllamaEviction(settings: settings)
    case .ollamaModel:
      reconcileOllamaEviction(settings: settings)
    // #2772: import preference changes trigger reconciliation. Ollama eviction tracks the
    // import's previous model beside dictation's and protects in-flight import pins.
    // Bundled-runtime activation for an import is the import's own job at run start, not
    // this reconciler's — see the note on `reconcileEGOneActivation`.
    case .fileImportLLMProvider, .fileImportLLMModel, .fileImportOllamaModel:
      // #2772 chunk 3: the import's model picker writes `fileImportLLMModel`, exactly as
      // dictation's writes `llmModel`. For Ollama the ARMED field is the ollama one, so
      // without this mirror an Ollama pick made on the Transcribe a File screen changed a
      // field nothing reads and the import kept running the previous model. Same policy
      // object as dictation's arm above, over the import's own two fields, so the two
      // surfaces cannot come to disagree about when a pick is mirrored.
      if key == .fileImportLLMModel,
        Self.shouldMirrorLLMModelToOllama(
          provider: settings.effectiveFileImportLLMProvider,
          llmModel: settings.fileImportLLMModel)
      {
        settings.fileImportOllamaModel = settings.fileImportLLMModel
      }
      reconcileOllamaEviction(settings: settings)
      reconcileEGOneActivation(settings: settings)
    case .hotkeyEnabled:
      if settings.hotkeyEnabled { hotkeyService.start() } else { hotkeyService.stop() }
    case .cancelKeyCode:
      hotkeyService.cancelKeyCode = settings.cancelKeyCode
      hotkeyService.reapplyCancelBinding()
    case .quickAddKeyCode:
      hotkeyService.quickAddKeyCode = settings.quickAddKeyCode
      hotkeyService.reapplyQuickAddBinding()
    case .quickAddModifiers:
      hotkeyService.quickAddModifiers = settings.quickAddModifiers
      hotkeyService.reapplyQuickAddBinding()
    case .cancelModifiers:
      hotkeyService.cancelModifiers = settings.cancelModifiers
      hotkeyService.reapplyCancelBinding()
    case .toggleKeyCode:
      hotkeyService.toggleKeyCode = settings.toggleKeyCode
      reregisterHotkeys()
    case .toggleModifiers:
      hotkeyService.toggleModifiers = settings.toggleModifiers
      reregisterHotkeys()
    case .pushToTalkKeyCode, .pushToTalkModifiers:
      // PTT mirrors toggle — single hotkey, mode determines behavior. No separate registration needed.
      break
    case .modelUnloadPolicy:
      // Frozen per recording; cancel idle timer live when switched to .never.
      if settings.modelUnloadPolicy == .never {
        asrManager.cancelIdleTimer()
      }
    case .emojiFormatterEnabled:
      kernelDriver.emojiFormatter.emojiFormatterEnabled = settings.emojiFormatterEnabled
      whisperKitKernelDriver.emojiFormatter.emojiFormatterEnabled = settings.emojiFormatterEnabled
    case .wordCorrectionEnabled:
      kernelDriver.wordCorrection.wordCorrectionEnabled = settings.wordCorrectionEnabled
      whisperKitKernelDriver.wordCorrection.wordCorrectionEnabled = settings.wordCorrectionEnabled
    case .fillerRemovalEnabled:
      kernelDriver.fillerRemoval.fillerRemovalEnabled = settings.fillerRemovalEnabled
      whisperKitKernelDriver.fillerRemoval.fillerRemovalEnabled = settings.fillerRemovalEnabled
    case .spokenPunctuationEnabled:
      // Live-mutable, matching its three Cleanup siblings above. A take already in
      // text processing keeps the value it started with (the step snapshots before
      // its actor hop); the next take uses the new value.
      kernelDriver.spokenPunctuationEnabled = settings.spokenPunctuationEnabled
      whisperKitKernelDriver.spokenPunctuationEnabled = settings.spokenPunctuationEnabled
    case .isDebugModeEnabled:
      Task { await AppLogger.shared.setDebugMode(settings.isDebugModeEnabled) }
    case .debugLogLevel:
      Task { await AppLogger.shared.setLogLevel(settings.debugLogLevel) }
    case .selectedInputDeviceUID:
      // Rebuilds next recording's capture source; in-flight recordings unaffected.
      audioCapture.selectedInputDeviceUID = settings.selectedInputDeviceUID
    case .preferredInputDeviceIDOverride:
      audioCapture.preferredInputDeviceIDOverride = settings.preferredInputDeviceIDOverride
    case .inputChannelByDeviceUID:
      // #2664: same contract as `.selectedInputDeviceUID` — rebuilds the next
      // recording's capture source (the manager's warm-reuse check reads this
      // map live); an in-flight recording is unaffected.
      audioCapture.inputChannelByDeviceUID = settings.inputChannelByDeviceUID
    case .warmEnginePolicy:
      audioCapture.warmEnginePolicy = settings.warmEnginePolicy
    case .autoCopyToClipboard, .vadAutoStop, .vadSilenceTimeout, .vadSensitivity,
      .vadEnergyGate, .restoreClipboardAfterPaste, .smartInsertion, .languageMode,
      .useStreamingASR:
      break  // Frozen per recording; see `DictationSessionConfig`.
    case .whisperKitLanguage:
      break  // Deprecated — legacy migration only (SettingsManager:460-484).
    case .onboardingState, .hasCompletedOnboarding,
      .contactsSyncOnLaunchEnabled:
      break  // UI-only or cold flag.
    case .quickAddClipboardFallback:
      // #2465: read live by `QuickAddWiring` at each invocation, and there is no dictation session
      // to sync it into. Deliberately NOT grouped with the frozen-per-recording cases above, which
      // would be a false statement about when it takes effect.
      break
    case .crashRecoveryEnabled:
      break  // #1063: read by the recovery wiring at capture start, not the live pipeline.
    case .s1MiniStyling, .s1MiniStructure, .s1MiniContext:
      // #2649: frozen into `DictationSessionConfig` at recording start, like
      // provider and model, so a pick applies to the NEXT recording. Recovery
      // replays the record-time value from the spool snapshot.
      break
    case .escapeRecoveryEnabled:
      // #2087: deliberately NOT synced live. The value is frozen into
      // `DictationSessionConfig` at recording start, so a recording always ends
      // under the rules it began with and a change applies to the NEXT one.
      // Same classification as `crashRecoveryEnabled` above.
      break
    case .isDictationAudioArchiveEnabled:
      break  // #1247: kernel pulls this live via `dictationAudioArchiveOptInProvider` — no push needed here.
    case .livePreviewEnabled:
      // #1988: display-only limb, read live by `LivePreviewCoordinator` off the
      // overlay seam. The PIPELINE still never learns it exists, which is the
      // point — this notifies the limb, not the pipeline.
      //
      // #2108: the limb now caches a loaded model, so switching the preview OFF
      // has to release it. Without this the release only ran at the next
      // recording start, which a user who simply stops using the feature never
      // reaches.
      onLivePreviewDisabled()
    case .livePreviewEngine:
      // #2123: the preview is still ON — the engine underneath it changed. The
      // limb releases what it prepared for the old one; the PIPELINE still never
      // learns the preview exists, which is why this is a notification and not a
      // dependency.
      onLivePreviewEngineChanged()
    case .appearance:
      break  // UI-only; applied to NSApp.appearance by the app shell (#1047).
    case .overlayPillPosition:
      break  // #1341: UI-only; read at fresh panel creation.
    case .recordingPillDesignWithoutWords, .recordingPillDesignWithWords:
      break  // #2376: UI-only; read at the start of the next fresh recording.
    case .showBluetoothTips:
      break  // #1480: UI-only; read by BluetoothAwarenessPresenter, no pipeline sync.
    case .playRecordingSounds, .recordingSoundPairing:
      break  // #1342: UI-only; read live by RecordingSoundCue, no pipeline sync.
    }
  }

  // MARK: - Ollama eviction on swap (#295)

  /// Fires best-effort unload when the tracked previous Ollama model differs
  /// from the new one. Also coalesces cascading .llmModel → .ollamaModel fires.
  /// Set when a switch away from EG-1 arrived while a recording had `.egOne`
  /// frozen in its session config — stopping the server then would silently
  /// degrade that recording's polish to raw (#1271 Codex r7). The terminal
  /// pipeline transition retries (same shape as the Ollama eviction defer).
  private var egOneDeactivationPending = false

  /// EG-1 server follows the provider selection live: activate on switch-to,
  /// stop on switch-away — but never underneath an in-flight session that
  /// froze `.egOne` at recording start.
  private func reconcileEGOneActivation(settings: SettingsManager) {
    // #2649: a session that froze EITHER local engine blocks the whole
    // reconciliation, not just the stop half. Deferring only the stop and then
    // starting the incoming model would have the coordinator evict the frozen
    // engine to make room, which is the outcome the defer exists to prevent.
    if isLocalPolishPinnedInFlight(), pinnedLocalProvider() != settings.llmProvider {
      egOneDeactivationPending = true
      return
    }
    // #2649: BOTH local engines are reconciled on every switch, and the order
    // is load-bearing. The outgoing model is stopped FIRST, so the incoming one
    // is never started while the other still holds the server — the coordinator
    // would then have to evict it mid-start, and the user would wait through a
    // stop the switch had already asked for.
    reconcile(runtime: egOneRuntime, isSelected: settings.llmProvider == .egOne, deselectFirst: true)
    reconcile(
      runtime: s1MiniRuntime, isSelected: settings.llmProvider == .s1Mini, deselectFirst: true)
    reconcile(runtime: egOneRuntime, isSelected: settings.llmProvider == .egOne)
    reconcile(runtime: s1MiniRuntime, isSelected: settings.llmProvider == .s1Mini)
  }

  /// One pass over one engine. `deselectFirst` runs only the STOP half, so the
  /// caller can stop every unselected engine before starting the selected one.
  private func reconcile(
    runtime: EGOneRuntime?, isSelected: Bool, deselectFirst: Bool = false
  ) {
    guard let runtime else { return }
    if isSelected {
      guard !deselectFirst else { return }
      egOneDeactivationPending = false
      runtime.activateAndProbe()
      return
    }
    // #2649 (local review, after the class sweep): an unselected engine is
    // stopped in the FIRST pass only. The second pass used to stop it again,
    // which claimed a THIRD intent stamp after the selected engine's start.
    // Intents run in separate tasks that Swift does not order, so if that
    // later stop reached the coordinator first it stopped the resident and
    // advanced the honoured stamp past the start, which was then refused,
    // leaving BOTH engines off until the next activation. One stop, one
    // start, two stamps: the coordinator's ordering then does the right thing
    // whichever task runs first.
    guard deselectFirst else { return }
    // The guard is about the RECORDING, not about which engine it froze:
    // stopping ANY local server underneath a session that froze a local
    // provider degrades that take's polish to raw. `isEGOnePinnedInFlight`
    // reads the frozen provider, so it already answers for both — but the
    // reconciliation must return BEFORE starting the incoming model too,
    // otherwise the coordinator evicts the frozen one anyway on the caller's
    // behalf and the defer buys nothing.
    if isLocalPolishPinnedInFlight() {
      egOneDeactivationPending = true
      return
    }
    egOneDeactivationPending = false
    runtime.deactivate()
  }

  /// Retry a deferred EG-1 shutdown AND a deferred model removal after an
  /// in-flight session ends. Called alongside `retryDeferredOllamaEviction`
  /// on terminal pipeline states. Idempotent: each retry no-ops unless
  /// actually pending.
  /// - Parameter forceReconciliation: reconcile even when nothing armed the pending flag.
  ///   **#2772: a file import that started its OWN bundled polisher arms nothing.** The
  ///   flag is set when a SETTINGS CHANGE is deferred, and an import that runs start to
  ///   finish with no interaction never sets it — so dictation on S1-mini, an import on
  ///   EG-1, and a clean finish left EG-1 resident and S1-mini never restored. Caught by
  ///   chunk-2 review round 2; the first version's comment claimed restoration happened
  ///   through this path, which was a promise the code did not keep.
  ///   Requesting reconciliation is not the same as completing it: the pin checks inside
  ///   `reconcileEGOneActivation` still apply, which is why this routes through it rather
  ///   than activating anything directly.
  func retryDeferredEGOneDeactivation(
    settings: SettingsManager, forceReconciliation: Bool = false
  ) {
    egOneRuntime?.retryPendingRemoval()
    // #2649: a deferred REMOVAL belongs to whichever engine the user asked to
    // remove, so both are retried. Retrying only EG-1 left an S1-mini removal
    // pending forever, with the model still on disk and nothing saying so.
    s1MiniRuntime?.retryPendingRemoval()
    guard forceReconciliation || egOneDeactivationPending else { return }
    reconcileEGOneActivation(settings: settings)
  }

  /// #1386 PR-2c: true while a WhisperKit dictation session is in flight —
  /// the Remove refusal's one read (a session-state READ, not an engine
  /// write; L7 untouched). Same authority pattern as the EG-1 twin below:
  /// this class owns both drivers, so it owns the read.
  func isWhisperKitDictationInFlight() -> Bool {
    whisperKitKernelDriver.currentSessionConfig != nil
  }

  /// True if either pipeline's frozen `DictationSessionConfig` targets EG-1.
  /// Single authority (#1271 matrix gap 3) — the runtime's Remove Model
  /// defer reads it through the closure the bootstrapper wires.
  func isEGOnePinnedInFlight() -> Bool {
    pinnedLocalProvider() == .egOne
  }

  /// #2649: which LOCAL engine an in-flight recording froze, if any.
  ///
  /// The old check named EG-1 because it was the only bundled engine. With two,
  /// a name is the wrong shape: the question is "is a local server load-bearing
  /// for a take that is still running", and the answer has to say WHICH, so a
  /// switch back to the frozen engine is not needlessly deferred.
  func pinnedLocalProvider() -> LLMProvider? {
    // #2648: the file import is a third holder of a bundled local server, and it
    // has no session config for the loop below to read.
    if let imported = importPinnedLocalProvider() { return imported }
    for cfg in [kernelDriver.currentSessionConfig, whisperKitKernelDriver.currentSessionConfig] {
      // #2651: the optional is unwrapped BEFORE the switch, so `.none` means
      // `LLMProvider.none` and nothing else. Matching on `cfg?.llmProvider`
      // directly makes `.none` read as `Optional.none`, which leaves the
      // provider's own `.none` case uncovered and does not compile.
      guard let provider = cfg?.llmProvider else { continue }
      switch provider {
      case .egOne: return .egOne
      case .s1Mini: return .s1Mini
      // Enumerated rather than `default:`. This answers "is a bundled local
      // server load-bearing for a take that is still running", so a NEW
      // bundled engine on a `default:` arm would report NOT pinned, and a
      // provider switch would tear its server down under a live recording.
      case .openAI, .gemini, .claude, .ollama, .appleIntelligence, .none: continue
      }
    }
    return nil
  }

  func isLocalPolishPinnedInFlight() -> Bool { pinnedLocalProvider() != nil }

  /// #2772: **bundled-runtime activation has ONE target, and it is dictation's.**
  ///
  /// The first version of this chunk took the UNION of both surfaces here. Chunk-2 review
  /// rejected it for two reasons, both correct. It only widened the DESELECT pass — the
  /// two activation calls below it still read dictation alone, so an import-only EG-1 was
  /// never started and the widening bought nothing. And widening the activation calls too
  /// would be worse: the #2649 note above records that these two engines COMPETE for one
  /// resource, so starting both is the outcome the ordering exists to prevent.
  ///
  /// The import does not need a permanently resident server. It needs one running for the
  /// length of its run, which is what `FileImportSettingsFreeze` already pins and what
  /// `pinnedLocalProvider()` already reports. So the import ACTIVATES its own bundled
  /// polisher as part of starting a run (`WisprBootstrapper`'s `beginRun`), the pin guard
  /// above keeps this reconciler off it while the run holds it, and `onEngineReleased`
  /// reconciles back to dictation's selection afterwards.

  private func reconcileOllamaEviction(settings: SettingsManager) {
    // #2772: two surfaces, two trackers, one policy. Each surface's PREVIOUS model is
    // evicted when that surface leaves it, unless the other surface still selects it: a
    // model one surface walked away from is not idle while the other is about to ask for
    // it. And a model both walked away from in the same pass is evicted once.
    let dictation = OllamaConnector.effectiveOllamaModel(
      provider: settings.llmProvider, model: settings.effectiveLLMModel
    )
    let fileImport = OllamaConnector.effectiveOllamaModel(
      provider: settings.effectiveFileImportLLMProvider,
      model: settings.effectiveFileImportLLMModel
    )
    // Canonical, like every other Ollama-name comparison in this file: `llama3.2` and
    // `llama3.2:latest` are one model, and the two surfaces can hold either spelling. An
    // exact set let an import walk away from `:latest` and evict the model dictation still
    // selected under the bare name. Found by the cloud review of PR #2786.
    let stillWanted = Set([dictation, fileImport].compactMap { $0 }.map(Self.canonical))
    var scheduledThisPass = Set<String>()
    reconcileEvictableModel(
      \.lastEvictableOllamaModel, new: dictation, stillWanted: stillWanted,
      scheduled: &scheduledThisPass)
    reconcileEvictableModel(
      \.lastEvictableImportOllamaModel, new: fileImport, stillWanted: stillWanted,
      scheduled: &scheduledThisPass)
  }

  /// One surface's tracker. The rules below predate the second tracker and apply to each
  /// unchanged; only the "still wanted elsewhere" and "already scheduled" checks are new.
  private func reconcileEvictableModel(
    _ tracker: ReferenceWritableKeyPath<PipelineSettingsSync, String?>, new: String?,
    stillWanted: Set<String>, scheduled: inout Set<String>
  ) {
    let pre = self[keyPath: tracker]
    guard let pre, Self.canonical(pre) != new.map(Self.canonical) else {
      self[keyPath: tracker] = new
      return
    }
    if stillWanted.contains(Self.canonical(pre)) || scheduled.contains(Self.canonical(pre)) {
      self[keyPath: tracker] = new
      return
    }
    // #1914: remote models are skipped BEFORE the in-flight deferral below,
    // and the order is load-bearing. Eviction unloads weights from THIS Mac's
    // memory; a model running on Ollama's servers has none here, so the request
    // buys nothing and spends the user's cloud quota. A remote model may well
    // have a polish request in flight — what it does not have is local weights
    // the deferral exists to protect, so eviction is unnecessary either way.
    // Deferring would leave the tracker pinned at `pre` and re-ask the same
    // question on every later settings change.
    //
    // Only a PROVEN remote model is skipped. `nil` means the catalog has no row
    // for this name, and that falls through to eviction on purpose: the cost of
    // a needless unload is one local request, while the cost of skipping a real
    // local model is a model left resident in VRAM, which is the #286
    // Bluetooth-audio regression. That is the OPPOSITE default from the warm-up
    // policy (#1914 Chunk 3), which skips unknown models, because there the
    // costs are reversed: a needless warm-up spends cloud quota and a skipped
    // one only costs a slower first polish.
    if ollamaRemotenessLookup(pre) == true {
      self[keyPath: tracker] = new
      Task {
        await AppLogger.shared.log(
          "Ollama eviction skipped: model=\(pre) reason=remote",
          level: .info, category: "Ollama")
      }
      return
    }

    // Phase B: if either pipeline has frozen `pre` into its in-flight
    // session via `DictationSessionConfig`, the upcoming polish call is
    // pinned to that model. Evicting now would cold-swap the active
    // recording's polish. Defer by leaving the tracker at
    // `pre`; the next setting change re-evaluates.
    if isOllamaModelPinnedInFlight(pre) { return }
    self[keyPath: tracker] = new
    scheduled.insert(Self.canonical(pre))
    scheduleOllamaEviction(pre)
  }

  /// The repository's one Ollama-name identity rule, so a tag-less spelling and its
  /// `:latest` twin compare equal everywhere this file asks whether two names are one model.
  private static func canonical(_ model: String) -> String {
    OllamaSetupService.canonicalModelName(model)
  }

  /// #1106: eviction is a stateless server-unload by model NAME
  /// (`OllamaConnector.evictModel`), so it routes through the live kernel's
  /// polish step (where the Ollama models actually load) rather than the
  /// deleted re-polish step. Any `LLMPolishStep` instance works.
  ///
  /// #1914: extracted so a test can observe THIS call site. Suppression happens
  /// before the connector exists, so the connector's network seam is downstream
  /// of the gate and can never see a request that was never scheduled.
  private func scheduleOllamaEviction(_ model: String) {
    if let evictionScheduler {
      evictionScheduler(model)
      return
    }
    let polishStep = kernelDriver.llmPolish
    Task { [polishStep, model] in
      await polishStep.evictPreviousOllamaModel(model)
    }
  }

  /// #1914: name to remoteness, against the Manage Models catalog.
  ///
  /// Production code, not a test helper, and the composition root calls THIS
  /// rather than writing its own matcher — a test that reimplemented canonical
  /// matching would prove only that the copy works.
  ///
  /// Matching is canonical (`llama2` and `llama2:latest` are one model), and
  /// the fact comes from the row's already-decoded `facts`. This never reads
  /// `remote_host`, never inspects the name for a `-cloud` suffix (plan §3
  /// Decision 1 rejects that classifier), and never issues a request.
  ///
  /// Returns `nil` when the catalog has no row for the name, which is a real
  /// third answer: the catalog can legitimately be empty before the first
  /// `/api/tags` refresh.
  static func ollamaRemoteness(
    of model: String, in catalog: [OllamaDownloadedModel]
  ) -> Bool? {
    let target = OllamaSetupService.canonicalModelName(model)
    let matched = catalog.first {
      OllamaSetupService.canonicalModelName($0.exactName) == target
    }
    return matched?.facts.isRemote
  }

  /// The production wiring for `ollamaRemotenessLookup`, living beside the
  /// semantics it depends on rather than in the composition root — which only
  /// needs to name it, not explain it.
  ///
  /// Reads `downloadedModels` at CALL time, never capturing a snapshot, so a
  /// model pulled or deleted after launch is seen. The capture is weak and a
  /// deallocated service answers `nil`, which is the fail-open direction: an
  /// unknown model is still evicted.
  static func liveOllamaRemotenessLookup(
    _ ollamaSetup: OllamaSetupService
  ) -> (String) -> Bool? {
    { [weak ollamaSetup] model in
      guard let ollamaSetup else { return nil }
      return ollamaRemoteness(of: model, in: ollamaSetup.downloadedModels)
    }
  }

  /// Retry a deferred Ollama eviction after an in-flight session ends.
  /// Called from the pipeline state-change side-effect path when either
  /// pipeline transitions to a terminal state. Idempotent: no-op if nothing
  /// is pending.
  func retryDeferredOllamaEviction(settings: SettingsManager) {
    reconcileOllamaEviction(settings: settings)
  }

  /// True if either pipeline's frozen `DictationSessionConfig` targets the
  /// given Ollama model. Used by `reconcileOllamaEviction` to avoid evicting
  /// a model the in-flight polish still needs.
  private func isOllamaModelPinnedInFlight(_ model: String) -> Bool {
    // #2648: a file import is the THIRD workload that can have this model
    // frozen, and it is the one with no `DictationSessionConfig` to read.
    let target = Self.canonical(model)
    if importPinnedOllamaModel().map(Self.canonical) == target { return true }
    for cfg in [kernelDriver.currentSessionConfig, whisperKitKernelDriver.currentSessionConfig] {
      guard let cfg else { continue }
      if cfg.llmProvider == .ollama && Self.canonical(cfg.llmModel) == target {
        return true
      }
    }
    return false
  }

  /// Re-register Carbon hotkeys after a config change.
  private func reregisterHotkeys() {
    guard hotkeyService.isEnabled else { return }
    // Not `stop()` + `start()`: that pair disarms an in-flight recording's cancel
    // key, because `start()` deliberately leaves cancel to the recording that
    // owns it. The service preserves the arming across the restart instead.
    hotkeyService.restartPreservingCancelArming()
  }
}
