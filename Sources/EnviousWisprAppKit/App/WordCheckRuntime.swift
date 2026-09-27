import EnviousWisprCore
import EnviousWisprModelDelivery
import EnviousWisprPipeline
import EnviousWisprWordCheck
import Foundation

/// Owns the word check for polish engines without a learned-word checker of their own (#3242):
/// when its model downloads (`WordCheckFetchPolicy`), when it is in memory, the selection a take
/// gets from it, and its removal. One owner so the download, the loaded model and the Dictionary
/// row cannot disagree.
///
/// Memory: the 4-bit model holds about 480 MB while loaded (measured on an M5 Max). It is loaded
/// when a take needs it or when the inputs say one soon will (launch, admission, a settings
/// change), and released after `idleUnloadDelay` without a take, when the Dictionary switch goes
/// off, or when no chosen engine needs it any more.
///
/// Ownership of a load is a GENERATION, never the task handle: `unload` and `remove` bump it, and a
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
  /// A removal is draining the last load and deleting the files: no new load may start.
  private var removing = false
  /// The app, not the user, cancelled a download because nothing needed it any more. The fetch
  /// policy holds a user's cancel until they ask again; this one must resume on its own once the
  /// check is wanted again (cloud review, PR #3245).
  private var cancelledBecauseUnwanted = false
  /// Every load still running, cancelled or not, by generation. Cancellation does not stop a load:
  /// the weights are read on a background queue until it ends. A new load waits for these before
  /// reading (two never overlap in memory), and a removal waits for all of them before deleting.
  private var runningLoads: [UInt64: Task<Void, Never>] = [:]

  package private(set) var fetchDecisionsForTests: [WordCheckFetchPolicy.Decision] = []

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

  private var wanted: Bool { isDictionaryEnabled() && someEngineLacksOwnChecker() }
  private var isAdmitted: Bool {
    if case .admitted = deliveryState { return true }
    return false
  }

  private func wire() {
    guard let handle = delivery.wordCheckHandle else { return }
    // The controller replays each identity's current state to a late observer.
    handle.observeState { [weak self] state in self?.deliveryStateChanged(state) }
    delivery.addParakeetAdmittedObserver { [weak self] in
      self?.refresh(trigger: "parakeet_admitted")
    }
    delivery.onWordCheckLaunchProbeFinished = { [weak self] in
      self?.launchProbeFinished = true
      self?.refresh(trigger: "launch")
    }
  }

  /// Re-evaluate download and residency. Called at launch, on onboarding completion, on
  /// Parakeet admission, and when the Dictionary switch or a polish engine choice changes.
  func refresh(trigger: String, userInitiated: Bool = false) {
    guard wanted else {
      if activeSelections == 0 { unload(reason: "not_wanted") }
      // The Dictionary switch is the off-switch for the download too: stop one in flight.
      switch deliveryState {
      case .preparing, .downloading, .verifying:
        cancelledBecauseUnwanted = true
        delivery.cancelWordCheckDownload()
      case .notReady, .admitted, .failed, .cancelled:
        break
      }
      onStatusChange()
      return
    }
    if isAdmitted {
      startLoadIfNeeded()
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

  func onboardingDidComplete() { refresh(trigger: "onboarding_completed") }

  private func decideFetch(trigger: String, userInitiated: Bool, parakeetAdmitted: Bool) {
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
      await AppLogger.shared.log("word check fetch \(trigger): \(decision)", category: "WordCheck")
    }
    if decision == .start {
      cancelledBecauseUnwanted = false
      delivery.startWordCheckDownload()
    }
  }

  private func deliveryStateChanged(_ state: DeliveryState) {
    let wasAdmitted = isAdmitted
    deliveryState = state
    if isAdmitted {
      if !wasAdmitted { failedLoadRevision = nil }
      if wanted { startLoadIfNeeded() }
    } else if wasAdmitted {
      // Removed or superseded: the loaded model may point at deleted files.
      unload(reason: "delivery_\(state)")
    }
    onStatusChange()
  }

  private func startLoadIfNeeded() {
    guard loaded == nil, loadTask == nil, isAdmitted, !removing,
      let registration = delivery.wordCheckRegistration,
      failedLoadRevision != registration.manifest.identity.revision
    else { return }
    let folder = registration.installDirectory
    let revision = registration.manifest.identity.revision
    loadGeneration &+= 1
    let generation = loadGeneration
    let predecessors = Array(runningLoads.values)
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

  /// Waits until no load is reading the model files.
  private func drainRunningLoads() async {
    while let next = runningLoads.values.first {
      await next.value
      runningLoads = runningLoads.filter { $0.value != next }
    }
  }

  private func unload(reason: String) {
    loadGeneration &+= 1
    idleUnloadTask?.cancel()
    idleUnloadTask = nil
    loadTask?.cancel()
    loadTask = nil
    guard loaded != nil else { return }
    loaded = nil
    Task {
      await AppLogger.shared.log("word check unloaded reason=\(reason)", category: "WordCheck")
    }
  }

  private func scheduleIdleUnload() {
    idleUnloadTask?.cancel()
    idleUnloadTask = Task { [weak self] in
      try? await Task.sleep(for: Self.idleUnloadDelay)
      guard !Task.isCancelled, let self, self.activeSelections == 0 else { return }
      self.unload(reason: "idle")
    }
  }

  /// "Try again" in the Dictionary row: a failed download starts again; a failed LOAD of admitted
  /// bytes (for instance under memory pressure) is retried once, by the user. Automatic retries of
  /// a failed load stay blocked so a model that cannot load does not loop.
  func retryDownload() {
    if isAdmitted {
      failedLoadRevision = nil
      startLoadIfNeeded()
      onStatusChange()
    } else {
      refresh(trigger: "settings_retry", userInitiated: true)
    }
  }

  // MARK: - Removal

  /// Whether the Dictionary row offers "Remove": the model is on disk and nothing chosen needs it
  /// (Dictionary off, or every chosen engine has its own check). While it is needed, removing it
  /// would only start the download again.
  var offersRemoval: Bool { isAdmitted && !wanted }

  /// Deletes the downloaded model after releasing the loaded one. Returns whether the bytes went.
  /// It comes back on its own the next time the Dictionary switch or an engine choice needs it.
  ///
  /// A load in flight keeps reading the model files on a background queue even once cancelled, so
  /// the removal waits for it to end before deleting, and blocks new loads meanwhile. A take that
  /// already holds the warmed model needs no files (the weights are materialized at load) and
  /// finishes on its own copy.
  func remove() async -> Bool {
    guard offersRemoval, !removing, let handle = delivery.wordCheckHandle else { return false }
    removing = true
    defer {
      removing = false
      onStatusChange()
    }
    unload(reason: "remove")
    await drainRunningLoads()
    let removed = await handle.remove()
    await AppLogger.shared.log("word check remove: removed=\(removed)", category: "WordCheck")
    return removed
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
      startLoadIfNeeded()
      await loadTask?.value
    }
    guard let loaded else { return Self.absent(.serverUnavailable) }
    scheduleIdleUnload()
    return LearnedWordCheckerSelection(
      checker: KevLearnedWordChecker(model: loaded.model, contract: loaded.contract),
      identity: loaded.contract.revision, judge: Self.judge)
  }

  /// The Dictionary row's line. Never loads the model: reading a status must not put 480 MB in
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
      if removing { return Self.absent(.serverUnavailable) }
      if failedLoadRevision == registration.manifest.identity.revision {
        return Self.absent(.serverUnavailable, retry: true)
      }
      return nil
    case .failed, .cancelled:
      return handle.isEnabled()
        ? Self.absent(.adapterDeliveryFailed, retry: true) : Self.absent(.deliveryDisabled)
    case .notReady, .preparing, .downloading, .verifying:
      guard handle.isEnabled() else { return Self.absent(.deliveryDisabled) }
      if triggerFetch { refresh(trigger: "take") }
      return Self.absent(.adapterDownloading)
    }
  }
}
