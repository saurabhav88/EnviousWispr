import AppKit
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprModelDelivery
import EnviousWisprPostProcessing
import EnviousWisprServices
import EnviousWisprStorage
import Foundation

// MARK: - Learn from edits: composition (#996 chunk 5h)
//
// Everything the feature needs at runtime, built once at the composition root
// and retained for the app's lifetime: the durable ledger, the vocabulary
// access over the real word list, the proposal coordinator, the overlay
// presenter (the coordinator holds it WEAKLY, so this holder is what keeps it
// alive), the paste observer and the watcher (the paste registry holds
// subscribers WEAKLY, likewise), the one arm-selection value the watcher and
// the Settings row both read, and the source-app name lookup the Pending tab
// uses. `WisprBootstrapper` constructs it and injects `coordinator`,
// `availability` and `sourceAppName` into the Settings environment.
//
// Production's judge (#996 phase D): the DELIVERED classifier. `ModelDeliveryHome`
// registers the `edit_judge` family; this type asks `EditJudgeFetchPolicy`
// when a download may start, loads `CoreMLCorrectionJudge` from the admitted
// folder when the delivery state says `.admitted`, and publishes it ONLY when
// `CorrectionJudgeArmSelection.select` answers `.arm(.classifier)` for the
// loaded identity digest. Until `qualified` carries a classifier entry (the
// fp16 exam receipt), `select` answers `.unavailable(.noQualifiedArm)`
// everywhere, the fetch policy holds, the watcher's `selectJudge` returns nil
// (`model_unavailable`) and the Settings row is disabled with its reason. The
// Debug UAT door below stays the way an unshipped candidate serves.

/// `TelemetryService` already carries the nine `learn*` emitters (5c); the
/// coordinator and watcher talk to the protocol so a spy can stand in.
extension TelemetryService: LearnFromEditsTelemetrySink {}

#if DEBUG
  /// Debug builds mirror every learn event into app.log as one
  /// `[LearnFromEdits]` line (shape only, the same fields the wire row
  /// carries), so a Live UAT reads its verdict from the log the way every
  /// other drill does (`code-tooling.md` RULE: uat-verdicts-from-app-log).
  /// Forwards everything to the real sink; Release has no such type.
  @MainActor
  final class LearnFromEditsLoggingSink: LearnFromEditsTelemetrySink {
    private let inner: any LearnFromEditsTelemetrySink
    init(_ inner: any LearnFromEditsTelemetrySink) { self.inner = inner }

    private func log(_ line: String) {
      Task { await AppLogger.shared.log(line, category: "LearnFromEdits") }
    }

    func learnSkipped(reason: T.SkipReason) {
      log("learn_skipped reason=\(reason.rawValue)")
      inner.learnSkipped(reason: reason)
    }
    func learnObservationEnded(
      reason: PastedRegionEndReason, settledBursts: Int, appClass: T.AppClass, durationMs: Int
    ) {
      log("learn_observation_ended reason=\(reason.rawValue) settled_bursts=\(settledBursts) app_class=\(appClass.rawValue) duration_ms=\(durationMs)")
      inner.learnObservationEnded(reason: reason, settledBursts: settledBursts, appClass: appClass, durationMs: durationMs)
    }
    func learnJudged(
      arm: T.Arm, outcome: T.JudgeOutcome, candidates: Int, accepted: Int, latencyMs: Int, queueWaitMs: Int?
    ) {
      log("learn_judged arm=\(arm.rawValue) outcome=\(outcome.rawValue) candidates=\(candidates) accepted=\(accepted) latency_ms=\(latencyMs)")
      inner.learnJudged(arm: arm, outcome: outcome, candidates: candidates, accepted: accepted, latencyMs: latencyMs, queueWaitMs: queueWaitMs)
    }
    func learnProposed(state: T.TargetState) {
      log("learn_proposed state=\(state.rawValue)")
      inner.learnProposed(state: state)
    }
    func learnCardShown() {
      log("learn_card_shown")
      inner.learnCardShown()
    }
    func learnCardExpired() {
      log("learn_card_expired")
      inner.learnCardExpired()
    }
    func learnResolved(decision: T.Decision, surface: T.Surface, state: T.TargetState, outcome: T.ResolutionOutcome) {
      log("learn_resolved decision=\(decision.rawValue) surface=\(surface.rawValue) state=\(state.rawValue) outcome=\(outcome.rawValue)")
      inner.learnResolved(decision: decision, surface: surface, state: state, outcome: outcome)
    }
    func learnSaveFailed(reason: T.SaveFailure) {
      log("learn_save_failed reason=\(reason.rawValue)")
      inner.learnSaveFailed(reason: reason)
    }
    func learnLedgerUntrusted(kind: T.LedgerUntrustedKind, disposition: T.LedgerDisposition) {
      log("learn_ledger_untrusted kind=\(kind.rawValue) disposition=\(disposition.rawValue)")
      inner.learnLedgerUntrusted(kind: kind, disposition: disposition)
    }
  }
#endif

@MainActor
final class LearnFromEditsWiring {
  let store: CorrectionProposalStore
  let coordinator: CorrectionProposalCoordinator
  let presenter: CorrectionProposalOverlayPresenter
  let observer: any PastedRegionObserving
  let watcher: ObservedCorrectionWatcher
  /// The step 7 selection: the rules/AFM rungs read ONCE at composition, then
  /// re-selected with the classifier's identity each time the delivered judge
  /// loads or is released. The watcher and the Settings row share it through
  /// `selectJudge()` and `availability`, so the two cannot disagree.
  private(set) var selection: CorrectionJudgeArmSelection
  /// The Settings row's live picture (phase D); injected by type.
  let availability: LearnFromEditsAvailability
  /// The retained judge instances the selection maps onto; nil when unavailable.
  private var productionJudge: SelectedCorrectionJudge?
  /// The two fallback rungs, retained so re-selection after the delivered
  /// judge loads or leaves can put a qualified rules or AFM judge back
  /// (round 16 finding 3).
  private let rulesJudge: RulesCorrectionJudge
  private let afmJudge: WordSuggestionService
  /// The delivered judge, once loaded and qualified. Released on removal.
  private var deliveredJudge: CoreMLCorrectionJudge?
  /// Phase D collaborators, nil in a build whose manifest did not load (tests
  /// construct without them and behave as before).
  private let deliveryHome: ModelDeliveryHome?
  private let isOnboardingComplete: @MainActor () -> Bool
  private let osMajor: Int
  private let afmAvailable: @MainActor () -> Bool
  private let afmDigest: String?
  private let rulesDigest: String
  private let compiledCacheDirectory: URL
  /// One counter for every load: a load that finishes after a removal or a
  /// newer admission compares its generation and publishes nothing.
  private var loadGeneration: UInt64 = 0
  private var loadTask: Task<Void, Never>?
  /// The delivery-side phase the row shows while no classifier serves.
  private var judgePhase: LearnFromEditsSettingsPresentation.JudgePhase = .none
  private var lastDeliveryState: DeliveryState = .notReady
  package private(set) var fetchDecisionsForTests: [EditJudgeFetchPolicy.Decision] = []
  #if DEBUG
    /// The UAT door's judge, once loaded. Until then (and in every launch
    /// without the door) `selectJudge` falls through to production.
    private(set) var debugOverride: SelectedCorrectionJudge?
    private(set) var debugDoor: DebugJudgeDoor?
  #endif

  init(
    settings: SettingsManager,
    customWords: CustomWordsCoordinator,
    packs: VocabularyPackManager,
    overlay: OverlayDirector,
    pasteCompletionRegistry: PasteCompletionRegistry,
    telemetry: any LearnFromEditsTelemetrySink,
    storeDirectory: URL = AppConstants.appSupportURL,
    osMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
    // Test seams, all defaulted to the live objects: a scripted observer and
    // frontmost app so a composition test can walk a paste to a card without
    // the accessibility API, and a selection override so it can stage a
    // serving judge while `qualified` stays empty.
    observer: (any PastedRegionObserving)? = nil,
    scheduler: (any PastedRegionScheduling)? = nil,
    frontmost: (@MainActor () -> FrontmostApplication?)? = nil,
    selectJudgeForTests: (@MainActor () -> SelectedCorrectionJudge?)? = nil,
    debugExportPath: String? = LearnFromEditsWiring.debugExportPathFromEnvironment(),
    deliveryHome: ModelDeliveryHome? = nil,
    isOnboardingComplete: @escaping @MainActor () -> Bool = { true },
    compiledCacheDirectory: URL = CoreMLCorrectionJudge.defaultCompiledCacheDirectory()
  ) {
    let store = CorrectionProposalStore(directory: storeDirectory)
    let suggestionService = customWords.suggestionService
    let vocabulary = CorrectionVocabularyAccess(
      userWords: { [weak customWords] in customWords?.customWords ?? [] },
      packTerms: { [weak packs] in packs?.enabledPackTerms() ?? [] },
      refreshTrustworthy: { [weak customWords] in
        guard let customWords, customWords.refreshFromDiskIfPossible() else { return .unreadable }
        return .fresh(customWords.customWords)
      },
      save: { [weak customWords] word, spelling in
        guard let customWords else { return "Couldn't save" }
        return CustomWordSaveHelper.saveAndConfirm(word, carrying: spelling, through: customWords)
      },
      classify: { WordSuggestionService.classifyByHeuristic($0) })
    let coordinator = CorrectionProposalCoordinator(
      store: store, vocabulary: vocabulary, presenter: nil, telemetry: telemetry)
    coordinator.initialize()
    let presenter = CorrectionProposalOverlayPresenter(host: overlay, coordinator: coordinator)
    coordinator.attach(presenter: presenter)

    // Step 7 at composition: platform, measured qualification and
    // availability for the rules and AFM rungs. The classifier rung joins when
    // the delivered judge loads (`reselect`).
    let rulesDigest = RulesCorrectionJudge.configDigest(policy: .v2)
    let afmDigest = WordSuggestionService.correctionJudgeConfigDigest
    let selection = CorrectionJudgeArmSelection.select(
      osMajor: osMajor,
      afmAvailable: suggestionService.isAvailable,
      rulesDigest: rulesDigest,
      afmDigest: afmDigest)
    let rulesJudge = RulesCorrectionJudge(policy: .v2)
    let productionJudge: SelectedCorrectionJudge?
    switch selection {
    case .arm(.rules):
      productionJudge = SelectedCorrectionJudge(arm: .rules, judge: rulesJudge)
    case .arm(.afm):
      productionJudge = SelectedCorrectionJudge(arm: .afm, judge: suggestionService)
    case .arm(.classifier), .unavailable:
      // `.classifier` cannot be selected here: no identity has loaded yet.
      productionJudge = nil
    }
    self.productionJudge = productionJudge
    self.rulesJudge = rulesJudge
    self.afmJudge = suggestionService
    self.selection = selection
    self.rulesDigest = rulesDigest
    self.afmDigest = afmDigest
    self.osMajor = osMajor
    self.afmAvailable = { [weak suggestionService] in suggestionService?.isAvailable ?? false }
    self.deliveryHome = deliveryHome
    self.isOnboardingComplete = isOnboardingComplete
    self.compiledCacheDirectory = compiledCacheDirectory
    // `.none` until the launch probe's policy result says otherwise: a
    // not-yet-decided row must never offer a Download the policy will refuse.
    let judgePhase: LearnFromEditsSettingsPresentation.JudgePhase = .none
    self.judgePhase = judgePhase
    self.availability = LearnFromEditsAvailability(
      presentation: LearnFromEditsSettingsPresentation(selection: selection, judge: judgePhase))

    // One scheduler for the observer and the watcher's paste clock, so the
    // deadline and the observation share a time base.
    let scheduler = scheduler ?? TaskPastedRegionScheduler()
    let observer = observer ?? PastedRegionObserver(ax: LivePastedRegionAXOperations(), scheduler: scheduler)
    // `self` is not available to the closures yet; a box hands the watcher a
    // stable reference the moment `self` exists.
    let box = SelectionBox()
    let watcher = ObservedCorrectionWatcher(
      dependencies: ObservedCorrectionWatcherDependencies(
        isLearnFromEditsOn: { [weak settings] in settings?.learnFromEdits ?? false },
        selectJudge: { selectJudgeForTests?() ?? box.wiring?.selectJudge() },
        frontmost: frontmost ?? {
          guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
          return FrontmostApplication(pid: app.processIdentifier, bundleID: app.bundleIdentifier)
        },
        observer: observer,
        nowMs: { scheduler.nowMs },
        userWords: { [weak customWords] in customWords?.customWords ?? [] },
        packTerms: { [weak packs] in packs?.enabledPackTerms() ?? [] },
        coordinator: coordinator,
        telemetry: telemetry))
    pasteCompletionRegistry.subscribe(watcher)

    self.store = store
    self.coordinator = coordinator
    self.presenter = presenter
    self.observer = observer
    self.watcher = watcher
    box.wiring = self

    // Set BEFORE the door loads: its synchronous rejection (a relative path)
    // clears the flag through `onFailure`, and wiring below must see that
    // (cloud review P3), so the flag is never re-derived from the path later.
    self.debugDoorPresent = debugExportPath != nil
    #if DEBUG
      if let debugExportPath {
        let door = DebugJudgeDoor(exportPath: debugExportPath)
        self.debugDoor = door
        publishPhase(.debugLoading)
        door.load(
          { [weak self] judge in
            guard let self else { return }
            self.debugOverride = judge
            // The row follows `selectJudge()`'s precedence: the door serves.
            self.availability.publish(
              LearnFromEditsSettingsPresentation(selection: .arm(.classifier), judge: .ready))
          },
          onFailure: { [weak self] in
            // The door failed: fall back to production consistently (the
            // historical behaviour), and let the delivery path proceed.
            guard let self else { return }
            self.publishPhase(.debugFailed)
            self.debugDoorPresent = false
            self.reselect()
            self.deliveryStateChanged(self.lastDeliveryState)
            self.startFetch(trigger: "debug_door_failed")
          })
      }
    #endif

    wireDelivery()
  }

  // MARK: - Phase D: the delivered judge's lifecycle

  private var debugDoorPresent = false
  /// Every AUTOMATIC trigger waits for the launch probe (first-run baseline,
  /// adopt-only admission); a Parakeet admission replayed before the probe
  /// finishes must not start a fetch first (cloud review P2). User presses
  /// are not gated: the probe is a launch matter, not a permission.
  private var launchProbeFinished = false

  /// Bind the delivery home's judge registration: state observation → load on
  /// admission; the row's actions; the removal drain; the automatic fetch once
  /// the launch probe has finished, on onboarding completion and on Parakeet
  /// admission.
  private func wireDelivery() {
    guard let home = deliveryHome, let handle = home.editJudgeHandle else { return }
    availability.download = { [weak self] in self?.startFetch(trigger: "settings", userInitiated: true) }
    availability.cancel = { [weak home] in home?.cancelEditJudgeDownload() }
    availability.retryLoad = { [weak self] in self?.loadDeliveredJudge(reason: "retry") }
    availability.removeAndDownload = { [weak self] in
      Task { @MainActor [weak self] in await self?.removeAndDownload() }
    }
    home.drainEditJudgeHoldersBeforeRemoval = { [weak self] in
      await self?.releaseDeliveredJudge() ?? true
    }
    home.onParakeetAdmitted = { [weak self] in self?.startFetch(trigger: "parakeet_admitted") }
    // The controller replays each identity's current state to a late observer,
    // so an `.admitted` published by the launch probe before this line is still
    // delivered (`ModelDeliveryController.addStateObserver`).
    handle.observeState { [weak self] state in self?.deliveryStateChanged(state) }
    // Automatic fetch only AFTER the probe has recorded the first-run baseline
    // and adopted an existing copy; the hook replays if the probe already ran.
    home.onEditJudgeLaunchProbeFinished = { [weak self] in
      self?.launchProbeFinished = true
      self?.startFetch(trigger: "launch")
    }
  }

  /// The bootstrapper's onboarding fan-out (beside EG-1's).
  func onboardingDidComplete() {
    startFetch(trigger: "onboarding_completed")
  }

  private func startFetch(trigger: String, userInitiated: Bool = false) {
    guard deliveryHome?.editJudgeHandle != nil else { return }
    guard userInitiated || launchProbeFinished else {
      Task {
        await AppLogger.shared.log(
          "learn-from-edits judge fetch \(trigger): held, launch probe not finished",
          category: "LearnFromEdits")
      }
      return
    }
    // Parakeet's admission is read from its persisted marker (a returning
    // user's mirror stays `.notReady` until the first dictation), so the
    // decision is made after one async read; the policy itself stays pure.
    Task { [weak self] in
      guard let self, let home = self.deliveryHome else { return }
      let parakeetAdmitted = await home.isParakeetAdmitted()
      self.decideFetch(trigger: trigger, userInitiated: userInitiated, parakeetAdmitted: parakeetAdmitted)
    }
  }

  private func decideFetch(trigger: String, userInitiated: Bool, parakeetAdmitted: Bool) {
    guard let home = deliveryHome, let handle = home.editJudgeHandle else { return }
    let inputs = EditJudgeFetchPolicy.Inputs(
      classifierQualifiedSomewhere: CorrectionJudgeArmSelection.classifierIsQualifiedSomewhere(
        digest: home.editJudgeRegistration?.manifest.runtimeIdentityDigest),
      onboardingComplete: isOnboardingComplete(),
      parakeetAdmitted: parakeetAdmitted,
      debugDoorPresent: debugDoorPresent,
      killSwitchOn: handle.isEnabled(),
      judgeState: lastDeliveryState,
      userInitiated: userInitiated)
    let decision = EditJudgeFetchPolicy.decide(inputs)
    fetchDecisionsForTests.append(decision)
    Task {
      await AppLogger.shared.log(
        "learn-from-edits judge fetch \(trigger): \(decision)", category: "LearnFromEdits")
    }
    // The row tells the truth about a hold (round 16 finding 5).
    switch decision {
    case .start:
      home.startEditJudgeDownload()
    case .hold(.notQualified):
      publishPhase(.none)
    case .hold(.onboardingIncomplete):
      publishPhase(.waitingForOnboarding)
    case .hold(.parakeetNotAdmitted):
      publishPhase(.waitingForSpeechModel)
    case .hold(.debugDoorPresent):
      break  // the door's own load publishes `.debugLoading` / `.ready` / `.debugFailed`
    case .hold(.killSwitchOff):
      publishPhase(.pausedByKillSwitch)
    case .hold(.alreadyAdmitted), .hold(.inFlight), .hold(.cancelledByUser):
      break
    }
  }

  /// Remove and download again: outcome-based, no optimistic flag. A refused
  /// removal (kill switch) leaves the loaded judge in place and says why.
  private func removeAndDownload() async {
    guard let home = deliveryHome else { return }
    switch await home.removeEditJudge() {
    case .removed:
      lastDeliveryState = .notReady
      publishPhase(.notInstalled)
      startFetch(trigger: "removal_finished", userInitiated: true)
    case .killSwitchOff:
      publishPhase(.pausedByKillSwitch)
    case .runtimeCleanupFailed, .deliveryRemovalFailed:
      publishPhase(.removalFailed)
    case .notRegistered:
      publishPhase(.none)
    }
  }

  private func deliveryStateChanged(_ state: DeliveryState) {
    lastDeliveryState = state
    // The Debug door owns this launch's row and judge; delivery states are
    // recorded (for the policy) and not shown.
    if debugDoorPresent { return }
    switch state {
    case .notReady:
      // Derived from the policy, never a bare "not installed": a late replay
      // must not overwrite a truthful hold (`.none`, waiting for setup, …).
      startFetch(trigger: "delivery_not_ready")
    case .preparing:
      publishPhase(.verifying)
    case .downloading(let fraction, let written, let total):
      publishPhase(.downloading(fractionCompleted: fraction, bytesWritten: written, totalBytes: total))
    case .verifying:
      publishPhase(.verifying)
    case .admitted:
      loadDeliveredJudge(reason: "admitted")
    case .cancelled:
      publishPhase(.cancelled)
    case .failed:
      publishPhase(.deliveryFailed)
    }
  }

  /// Load the admitted folder in its own generation and publish through the
  /// selection authority. A load that ends after a newer generation began
  /// (removal, re-admission, retry) discards itself.
  private func loadDeliveredJudge(reason: String) {
    // Single-flight: a duplicate `.admitted` never starts a second compile
    // whose handle nobody retains (round 17).
    guard loadTask == nil else { return }
    guard let home = deliveryHome, let registration = home.editJudgeRegistration,
      let handle = home.editJudgeHandle
    else { return }
    guard handle.isEnabled() else {
      publishPhase(.pausedByKillSwitch)
      return
    }
    loadGeneration &+= 1
    let generation = loadGeneration
    publishPhase(.loading)
    let folder = registration.installDirectory
    let cache = compiledCacheDirectory
    loadTask = Task { [weak self] in
      let loaded: Result<CoreMLCorrectionJudge, Error>
      do {
        loaded = .success(try await CoreMLCorrectionJudge.load(exportDirectory: folder, compiledCacheDirectory: cache))
      } catch {
        loaded = .failure(error)
      }
      guard let self, self.loadGeneration == generation, !Task.isCancelled else { return }
      self.loadTask = nil
      switch loaded {
      case .failure(let error):
        await AppLogger.shared.log(
          "learn-from-edits judge load (\(reason)) failed: \(error)", category: "LearnFromEdits")
        self.publishPhase(.loadFailed)
      case .success(let judge):
        self.deliveredJudge = judge
        self.reselect()
      }
    }
  }

  /// Re-run step 7 with the loaded classifier's identity and publish through
  /// the authority: a qualified classifier serves; otherwise a qualified rules
  /// or AFM judge is put (back) in place, never cleared by the classifier's
  /// arrival or departure (round 16 finding 3).
  private func reselect() {
    let digest = deliveredJudge?.classifierIdentityDigest
    let selection = CorrectionJudgeArmSelection.select(
      osMajor: osMajor, afmAvailable: afmAvailable(), rulesDigest: rulesDigest,
      afmDigest: afmDigest, classifierDigest: digest)
    self.selection = selection
    switch selection {
    case .arm(.classifier):
      guard let judge = deliveredJudge else {
        productionJudge = nil
        publishPhase(.loadFailed)
        return
      }
      productionJudge = SelectedCorrectionJudge(arm: .classifier, judge: judge)
      publishPhase(.ready)
    case .arm(.rules):
      productionJudge = SelectedCorrectionJudge(arm: .rules, judge: rulesJudge)
      publishPhase(deliveredJudge == nil ? judgePhase : .ready)
    case .arm(.afm):
      productionJudge = SelectedCorrectionJudge(arm: .afm, judge: afmJudge)
      publishPhase(deliveredJudge == nil ? judgePhase : .ready)
    case .unavailable:
      productionJudge = nil
      guard deliveredJudge != nil else {
        publishPhase(judgePhase)
        return
      }
      // Loaded, but not selected: qualified for another macOS (`.ready` under
      // `.unavailable` renders "not on this macOS") or a package no receipt
      // names anywhere (substituted bytes).
      let qualifiedAnywhere = CorrectionJudgeArmSelection.qualified.contains {
        $0.arm == .classifier && $0.configDigest == digest
      }
      Task {
        await AppLogger.shared.log(
          "learn-from-edits judge loaded but not selected: digest=\(digest ?? "nil") "
            + "qualifiedAnywhere=\(qualifiedAnywhere)", category: "LearnFromEdits")
      }
      publishPhase(qualifiedAnywhere ? .ready : .identityMismatch)
    }
  }

  private func publishPhase(_ phase: LearnFromEditsSettingsPresentation.JudgePhase) {
    judgePhase = phase
    availability.publish(LearnFromEditsSettingsPresentation(selection: selection, judge: phase))
  }

  /// Awaited by the delivery home before it deletes the folder: stop selecting
  /// the classifier, cut a live watch, wait out an in-flight load and any
  /// in-flight judgement, drop the model, delete the compiled cache. Order is
  /// the contract (round 16 finding 2): nothing may still map the model when
  /// the bytes go, and no late load may re-create the compiled cache.
  private func releaseDeliveredJudge() async -> Bool {
    loadGeneration &+= 1
    let loading = loadTask
    loadTask = nil
    loading?.cancel()
    watcher.modelBecameUnavailable()
    let judge = deliveredJudge
    deliveredJudge = nil
    reselect()
    await loading?.value
    await judge?.drain()
    do {
      try CoreMLCorrectionJudge.removeCompiledModels(cacheDirectory: compiledCacheDirectory)
    } catch {
      await AppLogger.shared.log(
        "learn-from-edits compiled cache could not be deleted: \(error)", category: "LearnFromEdits")
      publishPhase(.removalFailed)
      return false
    }
    publishPhase(.notInstalled)
    return true
  }

  /// The env var is read here and nowhere else, and only in Debug: Release
  /// has no env-var read, no loader and no override.
  static func debugExportPathFromEnvironment() -> String? {
    #if DEBUG
      return ProcessInfo.processInfo.environment[DebugJudgeDoor.environmentKey]
    #else
      return nil
    #endif
  }

  /// What the watcher runs: the Debug door's judge when it has loaded, else
  /// production's (nil = `model_unavailable`).
  func selectJudge() -> SelectedCorrectionJudge? {
    #if DEBUG
      if let debugOverride { return debugOverride }
    #endif
    return productionJudge
  }

  /// `SettingsManager.onChange` fan-out for the one key this feature owns.
  func settingChanged(_ key: SettingsManager.SettingKey, settings: SettingsManager) {
    guard key == .learnFromEdits else { return }
    watcher.learnFromEditsChanged(isOn: settings.learnFromEdits)
  }

  /// Each real transition into `.recording` (the pipeline-state owner calls it).
  func recordingStarted() {
    watcher.recordingStarted()
  }

  /// The Pending tab's app-name lookup: the app's display name from its bundle,
  /// nil when the id resolves to nothing (never the raw identifier).
  static func sourceAppName(bundleID: String) -> String? {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
      return nil
    }
    let bundle = Bundle(url: url)
    let candidates: [String?] = [
      bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
      bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String,
      url.deletingPathExtension().lastPathComponent,
    ]
    return candidates.compactMap { $0 }.first { !$0.isEmpty }
  }

  var sourceAppName: @MainActor (String) -> String? { { Self.sourceAppName(bundleID: $0) } }

  private final class SelectionBox {
    weak var wiring: LearnFromEditsWiring?
  }
}

#if DEBUG
  /// The founder-approved UAT door (plan §16, 2026-09-19): when
  /// `EW_LEARN_FROM_EDITS_JUDGE_EXPORT` names a locked candidate's FP32 export
  /// directory, this launch runs that judge as arm `classifier`. Read once at
  /// composition, loaded asynchronously; until it is ready the watcher sees
  /// production's selection. A load failure publishes nothing and is logged.
  /// Release compiles none of this: no env-var read, no loader, no override.
  @MainActor
  final class DebugJudgeDoor {
    static let environmentKey = "EW_LEARN_FROM_EDITS_JUDGE_EXPORT"

    enum State: Equatable {
      case loading
      case ready
      case failed(String)
      case rejected(String)
    }

    let exportPath: String
    private(set) var state: State = .loading
    private var task: Task<Void, Never>?

    init(exportPath: String) {
      self.exportPath = exportPath
    }

    func load(
      _ publish: @escaping @MainActor (SelectedCorrectionJudge) -> Void,
      onFailure: @escaping @MainActor () -> Void = {}
    ) {
      guard exportPath.hasPrefix("/") else {
        state = .rejected("not an absolute path")
        Self.log("learn-from-edits UAT door REJECTED: \(exportPath) is not an absolute path")
        onFailure()
        return
      }
      let url = URL(fileURLWithPath: exportPath, isDirectory: true)
      task = Task { @MainActor [weak self] in
        do {
          let judge = try await CoreMLCorrectionJudge.load(exportDirectory: url)
          guard let self else { return }
          self.state = .ready
          let id = judge.identity
          Self.log(
            "learn-from-edits UAT door ACTIVE: export=\(id.exportDirectory.path) "
              + "threshold=\(id.threshold) languages=all "
              + "package_sha256=\(id.executionIdentity["package_sha256"] ?? "?") arm=classifier")
          publish(SelectedCorrectionJudge(arm: .classifier, judge: judge))
        } catch {
          self?.state = .failed("\(error)")
          Self.log("learn-from-edits UAT door FAILED to load \(url.path): \(error)")
          onFailure()
        }
      }
    }

    private static func log(_ line: String) {
      Task { await AppLogger.shared.log(line, category: "LearnFromEdits") }
    }
  }
#endif
