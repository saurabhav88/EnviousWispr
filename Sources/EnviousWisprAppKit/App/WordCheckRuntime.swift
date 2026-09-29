import EnviousWisprCore
import EnviousWisprModelDelivery
import EnviousWisprPipeline
import EnviousWisprWordCheck
import Foundation

/// Owns the word check for polish engines without a learned-word checker of their own (#3242):
/// when its model downloads (`WordCheckFetchPolicy`), when it is in memory, the selection a take
/// gets from it. One owner so the download, the loaded model and the Dictionary
/// row cannot disagree.
///
/// Memory: kev-wc-2's weights are 486 MB (embedding 4-bit, layers 5-bit); kev-wc-1's 424 MB of
/// 4-bit weights held about 480 MB while loaded (measured on an M5 Max). It is loaded only
/// by work that will use it (`WordCheckResidencyPolicy`: a recording or file import whose engine
/// has no checker, a take's selection, Try again), never because the settings say some engine
/// might (#3289), and released after `idleUnloadDelay` without a take, when the Dictionary switch
/// goes off, or when no chosen engine needs it any more.
///
/// Ownership of a load is a GENERATION, never the task handle: `unload` bumps it, and a
/// load that finishes under an older generation publishes nothing (a Dictionary off-and-on during
/// the 1.6 s load must not let the first load clear or overwrite the second).
@MainActor
final class WordCheckRuntime {
  /// How the Dictionary row names this check ("Checked by: ..."). A product name, like the engine
  /// names other judges use (`LLMProvider.displayName`), so it is not translated.
  static let judge = LearnedWordJudge(displayName: "Envious Word Check")

  static let idleUnloadDelay: Duration = .seconds(600)

  private let delivery: ModelDeliveryHome
  private let isDictionaryEnabled: @MainActor () -> Bool
  private let someEngineLacksOwnChecker: @MainActor () -> Bool
  private let isOnboardingComplete: @MainActor () -> Bool
  /// The Dictionary row re-reads its status when this fires.
  var onStatusChange: @MainActor () -> Void = {}
  /// Whether the work in flight polishes (by its FROZEN provider: the dictation's session provider,
  /// the import's run provider) with an engine that has no checker of its own. A provider switch
  /// mid-take changes the settings but not the take, so the take keeps the check it will select
  /// (local review, PR #3246); the same holds for an import's remaining parts (#3289).
  /// The idle timer never unloads while this is true: a take that crosses `idleUnloadDelay`,
  /// whether while recording or while its transcription runs, would otherwise lose the model it
  /// pre-loaded at record start (cloud review, PR #3246), and an import would lose it between
  /// parts (#3289). Work that does NOT use this check (an EG-1 or S1-mini dictation or import)
  /// does not hold it in memory (#3289 final review).
  var inFlightWorkNeedsWordCheck: @MainActor () -> Bool = { false }
  /// Crash-recovery replays in progress whose recording's frozen engine uses this check, counted
  /// from `recoveryStarted` to `recoveryFinished` (#3289 final review): work in flight, like a
  /// dictation, for the idle timer and for admission.
  private var recoveriesNeedingCheck = 0
  private var workNeedsCheck: Bool { inFlightWorkNeedsWordCheck() || recoveriesNeedingCheck > 0 }

  private var deliveryState: DeliveryState = .notReady
  private var launchProbeFinished = false
  private var loaded: (model: KevWordCheckModel, contract: KevContract)?
  private var loadTask: Task<Void, Never>?
  private var loadGeneration: UInt64 = 0
  /// Takes waiting on a load right now. A take asks with the provider it RECORDED (crash-recovery
  /// replay, a file import's frozen choice), which today's settings may no longer need; while one
  /// waits, the load is kept even though `wanted` says otherwise.
  private var activeSelections = 0
  /// The revision a load failed for; retried only after the admitted bytes change.
  private var failedLoadRevision: String?
  private var idleUnloadTask: Task<Void, Never>?
  /// The app, not the user, cancelled a download because nothing needed it any more. The fetch
  /// policy holds a user's cancel until they ask again; this one must resume on its own once the
  /// check is wanted again (cloud review, PR #3245).
  private var cancelledBecauseUnwanted = false
  /// Every load still running, cancelled or not, by generation. Cancellation does not stop a load:
  /// the weights are read on a background queue until it ends. A new load waits for these before
  /// reading (two never overlap in memory).
  private var runningLoads: [UInt64: Task<Void, Never>] = [:]

  package private(set) var fetchDecisionsForTests: [WordCheckFetchPolicy.Decision] = []
  /// Load tasks created, counted where one is created (#3289): the residency tests' observable.
  package private(set) var loadAttemptsForTests = 0

  init(
    delivery: ModelDeliveryHome,
    isDictionaryEnabled: @escaping @MainActor () -> Bool,
    someEngineLacksOwnChecker: @escaping @MainActor () -> Bool,
    isOnboardingComplete: @escaping @MainActor () -> Bool
  ) {
    self.delivery = delivery
    self.isDictionaryEnabled = isDictionaryEnabled
    self.someEngineLacksOwnChecker = someEngineLacksOwnChecker
    self.isOnboardingComplete = isOnboardingComplete
    wire()
  }

  /// Needed now: Dictionary on, some chosen engine without its own check, and first-run setup done
  /// (a Diagnostics onboarding reset takes the check back out, download and memory both).
  private var wanted: Bool {
    isDictionaryEnabled() && isOnboardingComplete()
      && (someEngineLacksOwnChecker() || workNeedsCheck)
  }
  /// Read-only, for the idle-memory sample (#3289 §8b): is the model in memory, and would
  /// the current settings or work in flight use it.
  var isLoadedForTelemetry: Bool { loaded != nil }
  var isWantedForTelemetry: Bool { wanted }
  private var isAdmitted: Bool {
    if case .admitted = deliveryState { return true }
    return false
  }

  private func wire() {
    guard let handle = delivery.wordCheckHandle else { return }
    // The controller replays each identity's current state to a late observer.
    handle.observeState { [weak self] state in self?.deliveryStateChanged(state) }
    delivery.addParakeetAdmittedObserver { [weak self] in
      self?.refresh(trigger: .parakeetAdmitted)
    }
    delivery.onWordCheckLaunchProbeFinished = { [weak self] in
      self?.launchProbeFinished = true
      self?.refresh(trigger: .launch)
    }
  }

  /// Re-evaluate download and residency. Called at launch, on onboarding completion, on
  /// Parakeet admission, and when the Dictionary switch or a polish engine choice changes. It
  /// decides the download and unloads a model nobody wants; it never loads one (#3289): memory is
  /// for work, and the work entry points below load for themselves.
  func refresh(trigger: WordCheckResidencyPolicy.Trigger, userInitiated: Bool = false) {
    guard wanted else {
      if activeSelections == 0 { unload(reason: "not_wanted") }
      // The Dictionary switch is the off-switch for the download too: stop one in flight.
      cancelFetchIfInFlight()
      onStatusChange()
      return
    }
    if isAdmitted {
      onStatusChange()
      return
    }
    guard userInitiated || launchProbeFinished else { return }
    Task { [weak self] in
      guard let self else { return }
      let parakeetAdmitted = await self.delivery.isParakeetAdmitted()
      self.decideFetch(
        trigger: trigger, userInitiated: userInitiated, parakeetAdmitted: parakeetAdmitted)
    }
  }

  private func decideFetch(trigger: WordCheckResidencyPolicy.Trigger, userInitiated: Bool, parakeetAdmitted: Bool) {
    guard let handle = delivery.wordCheckHandle else { return }
    let decision = WordCheckFetchPolicy.decide(
      .init(
        dictionaryEnabled: isDictionaryEnabled(),
        someEngineLacksOwnChecker: someEngineLacksOwnChecker(),
        onboardingComplete: isOnboardingComplete(),
        parakeetAdmitted: parakeetAdmitted,
        killSwitchOn: handle.isEnabled(),
        state: deliveryState,
        userInitiated: userInitiated || cancelledBecauseUnwanted))
    fetchDecisionsForTests.append(decision)
    Task {
      await AppLogger.shared.log(
        "word check fetch \(trigger.rawValue): \(decision)", category: "WordCheck")
    }
    if decision == .start {
      cancelledBecauseUnwanted = false
      delivery.startWordCheckDownload()
    }
  }

  /// Stop an in-flight download nothing needs, remembering the app (not the user) cancelled it.
  private func cancelFetchIfInFlight() {
    switch deliveryState {
    case .preparing, .downloading, .verifying:
      cancelledBecauseUnwanted = true
      delivery.cancelWordCheckDownload()
    case .notReady, .admitted, .failed, .cancelled:
      break
    }
  }

  private func deliveryStateChanged(_ state: DeliveryState) {
    let wasAdmitted = isAdmitted
    deliveryState = state
    if isAdmitted {
      cancelledBecauseUnwanted = false  // a cancel that lost the race to admission
      if !wasAdmitted {
        failedLoadRevision = nil
        // A dictation or import that started while the model was still downloading could not
        // preload it; load now for that work only (#3289 final review).
        if wanted { load(for: .deliveryAdmitted, needsWordCheck: workNeedsCheck) }
      }
    } else if wasAdmitted {
      // Removed or superseded: the loaded model may point at deleted files.
      unload(reason: "delivery_\(state)")
    }
    // The wanted decision and the delivery state can cross: a start already under way when the
    // check stopped being needed, or the app's cancel landing after it was needed again.
    if !wanted {
      cancelFetchIfInFlight()
    } else if case .cancelled = state, cancelledBecauseUnwanted {
      refresh(trigger: .appCancelFinished)
    }
    onStatusChange()
  }

  /// The residency tests drive the delivery state the handle would report; a test cannot put real
  /// model files through the delivery controller.
  package func deliveryStateChangedForTests(_ state: DeliveryState) { deliveryStateChanged(state) }

  /// The one way into a load: the policy decides, `startLoadIfNeeded` guards the state.
  private func load(for trigger: WordCheckResidencyPolicy.Trigger, needsWordCheck: Bool = true) {
    guard WordCheckResidencyPolicy.shouldLoad(trigger, needsWordCheck: needsWordCheck) else {
      return
    }
    startLoadIfNeeded()
  }

  private func startLoadIfNeeded() {
    guard loaded == nil, loadTask == nil, isAdmitted,
      let registration = delivery.wordCheckRegistration,
      failedLoadRevision != registration.manifest.identity.revision
    else { return }
    let folder = registration.installDirectory
    let revision = registration.manifest.identity.revision
    loadGeneration &+= 1
    let generation = loadGeneration
    let predecessors = Array(runningLoads.values)
    loadAttemptsForTests += 1
    let task = Task { [weak self] in
      for predecessor in predecessors { await predecessor.value }
      // This task runs on the main actor (created there), so the bookkeeping is ordered with it.
      defer { self?.runningLoads[generation] = nil }
      guard let current = self?.loadGeneration, current == generation, !Task.isCancelled else {
        return
      }
      let started = ContinuousClock.now
      do {
        let model = try await KevWordCheckModel(folder: folder)
        try await model.warmUp()
        let contract = await model.contract
        let elapsed = ContinuousClock.now - started
        // Only the load of the CURRENT generation may publish anything.
        guard let self, self.loadGeneration == generation else { return }
        self.loadTask = nil
        guard self.isAdmitted, self.wanted || self.activeSelections > 0 else { return }
        self.loaded = (model, contract)
        self.scheduleIdleUnload()
        self.onStatusChange()
        await AppLogger.shared.log(
          "word check loaded revision=\(contract.revision) ms=\(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)",
          category: "WordCheck")
      } catch {
        // BEFORE the generation guard (#3289): a failed load never produced a model, so no deinit
        // clears what its weights left in MLX's cache, and a cancelled or superseded failure leaves
        // the same buffers as a current one.
        KevWordCheckModel.releaseCachedBuffers()
        #if DEBUG
          let memory = KevWordCheckModel.memorySnapshotForLog()
          Task {
            await AppLogger.shared.log(
              "word check load failure cleanup mlx_active=\(memory.active) mlx_cache=\(memory.cache)",
              category: "WordCheck")
          }
        #endif
        guard let self, self.loadGeneration == generation else { return }
        self.loadTask = nil
        self.failedLoadRevision = revision
        self.onStatusChange()
        await AppLogger.shared.log(
          "word check load failed revision=\(revision): \(error)", level: .info,
          category: "WordCheck")
      }
    }
    loadTask = task
    runningLoads[generation] = task
  }

  private func unload(reason: String) {
    loadGeneration &+= 1
    idleUnloadTask?.cancel()
    idleUnloadTask = nil
    loadTask?.cancel()
    loadTask = nil
    guard loaded != nil else { return }
    loaded = nil
    // The runtime's reference is gone; the model itself is freed (and MLX's cache cleared, in its
    // deinit) only when its last holder lets go: a take, an import part or a late answer may still
    // hold it.
    #if DEBUG
      let memory = KevWordCheckModel.memorySnapshotForLog()
      Task {
        await AppLogger.shared.log(
          "word check unloaded reason=\(reason) mlx_active=\(memory.active) mlx_cache=\(memory.cache)",
          category: "WordCheck")
      }
    #else
      Task {
        await AppLogger.shared.log("word check unloaded reason=\(reason)", category: "WordCheck")
      }
    #endif
  }

  private func scheduleIdleUnload() {
    idleUnloadTask?.cancel()
    idleUnloadTask = Task { [weak self] in
      try? await Task.sleep(for: Self.idleUnloadDelay)
      guard !Task.isCancelled, let self else { return }
      switch Self.idleExpiry(
        activeSelections: self.activeSelections, workNeedsCheck: self.workNeedsCheck)
      {
      case .keep: return
      case .reschedule: self.scheduleIdleUnload()
      case .release:
        self.unload(reason: "idle")
      }
    }
  }

  enum IdleExpiry: Equatable { case keep, reschedule, release }

  /// What the idle timer does when it fires. A take waiting on a load keeps the model (its selection
  /// reschedules the timer); work in flight that uses this check, a dictation or an engine-held
  /// import, defers the unload by another full delay (#3242, #3289).
  static func idleExpiry(activeSelections: Int, workNeedsCheck: Bool) -> IdleExpiry {
    if activeSelections > 0 { return .keep }
    return workNeedsCheck ? .reschedule : .release
  }

  /// Whether the work in flight needs this check, by each piece of work's FROZEN polish engine: the
  /// dictations' session providers and, while an import holds the engine, the import's run provider
  /// (#3289). The composition root feeds `inFlightWorkNeedsWordCheck` through this.
  static func workNeedsWordCheck(
    dictationProviders: [LLMProvider], importHoldsEngine: Bool, importProvider: LLMProvider?
  ) -> Bool {
    let needs = { (provider: LLMProvider) in LearnedWordCheckerEngine(provider: provider) == nil }
    if dictationProviders.contains(where: needs) { return true }
    guard importHoldsEngine, let importProvider else { return false }
    return needs(importProvider)
  }

  /// A recording just started: load the model now, while the user is still speaking, so the take's
  /// check finds it ready. Measured live (#3242): after the ten-minute idle unload the reload took
  /// 1.6 s, past the 1.2 s selection deadline, so the first take after a quiet stretch went
  /// unchecked. Loading at record start hides that behind the dictation itself.
  /// `needsWordCheckForRecording`: this dictation's own polish engine has no checker. `wanted` alone
  /// is also true when only Transcribe a File needs the check, and a dictation must not load a model
  /// it will not use. The caller passes the take's FROZEN session provider, not the current setting.
  func recordingStarted(needsWordCheckForRecording: Bool) {
    workStarted(.recordingStarted, needsWordCheck: needsWordCheckForRecording)
  }

  /// A file transcription just started (Start or Clean it again): the same preload, for the run's
  /// FROZEN polish engine, so the first part finds the check loading or ready (#3289, #3256).
  func fileImportStarted(needsWordCheck: Bool) {
    workStarted(.fileImportStarted, needsWordCheck: needsWordCheck)
  }

  /// A crash-recovery replay is about to transcribe a recovered recording: the same preload, for
  /// the recording's FROZEN polish engine, hidden behind that transcription (#3289 final review).
  /// Before #3289 the model was already in memory from launch.
  func recoveryStarted(needsWordCheck: Bool) {
    if needsWordCheck { recoveriesNeedingCheck += 1 }
    workStarted(.recoveryStarted, needsWordCheck: needsWordCheck)
  }

  /// The replay that called `recoveryStarted` with the same answer has ended, on any path.
  func recoveryFinished(needsWordCheck: Bool) {
    if needsWordCheck { recoveriesNeedingCheck = max(0, recoveriesNeedingCheck - 1) }
  }

  private func workStarted(_ trigger: WordCheckResidencyPolicy.Trigger, needsWordCheck: Bool) {
    guard needsWordCheck, wanted else { return }
    if loaded != nil {
      scheduleIdleUnload()
    } else {
      load(for: trigger, needsWordCheck: needsWordCheck)
    }
  }

  /// "Try again" in the Dictionary row: a failed download starts again; a failed LOAD of admitted
  /// bytes (for instance under memory pressure) is retried once, by the user. Automatic retries of
  /// a failed load stay blocked so a model that cannot load does not loop.
  func retryDownload() {
    if isAdmitted {
      failedLoadRevision = nil
      load(for: .userRetry)
      onStatusChange()
    } else {
      refresh(trigger: .userRetry, userInitiated: true)
    }
  }

  // MARK: - Selection

  /// The selection for one take whose polish engine has no checker of its own. Awaits an
  /// in-progress load: `LearnedWordCheckStep.selectionDeadline` bounds that wait, and a load that
  /// outlives it finishes in the background for the next take.
  func selection() async -> LearnedWordCheckerSelection {
    if let absence = currentAbsence(triggerFetch: true) { return absence }
    if loaded == nil {
      activeSelections += 1
      defer { activeSelections -= 1 }
      load(for: .takeSelection)
      await loadTask?.value
    }
    guard let loaded else { return Self.absent(.serverUnavailable) }
    scheduleIdleUnload()
    return LearnedWordCheckerSelection(
      checker: KevLearnedWordChecker(model: loaded.model, contract: loaded.contract),
      identity: loaded.contract.revision, judge: Self.judge)
  }

  /// The Dictionary row's line. Never loads the model: reading a status must not put the model in
  /// memory, least of all right after the user turned the Dictionary off.
  func settingsStatus() -> LearnedCheckerSettingsStatus {
    if let absence = currentAbsence(triggerFetch: false) {
      return LearnedCheckerSettingsStatus(selection: absence)
    }
    // While the first load and warm-up run (about 1.6 s measured), a take can still miss its
    // deadline, so the row must not yet say words are checked. Idle-unloaded is different: the
    // next take reloads it.
    if loadTask != nil && loaded == nil {
      return LearnedCheckerSettingsStatus(selection: Self.absent(.serverUnavailable))
    }
    return LearnedCheckerSettingsStatus(checkedBy: Self.judge)
  }

  private static func absent(_ reason: LearnedWordCheckerAbsence, retry: Bool = false)
    -> LearnedWordCheckerSelection
  {
    .init(absence: reason, retryAvailable: retry, judge: judge)
  }

  /// Why no check can run right now, or nil when the model is admitted and loadable.
  private func currentAbsence(triggerFetch: Bool) -> LearnedWordCheckerSelection? {
    guard let handle = delivery.wordCheckHandle, let registration = delivery.wordCheckRegistration
    else { return Self.absent(.adapterDeliveryFailed) }
    switch deliveryState {
    case .admitted:
      if failedLoadRevision == registration.manifest.identity.revision {
        return Self.absent(.serverUnavailable, retry: true)
      }
      return nil
    case .failed, .cancelled:
      return handle.isEnabled()
        ? Self.absent(.adapterDeliveryFailed, retry: true) : Self.absent(.deliveryDisabled)
    case .notReady, .preparing, .downloading, .verifying:
      guard handle.isEnabled() else { return Self.absent(.deliveryDisabled) }
      if triggerFetch { refresh(trigger: .takeSelection) }
      return Self.absent(.adapterDownloading)
    }
  }
}
