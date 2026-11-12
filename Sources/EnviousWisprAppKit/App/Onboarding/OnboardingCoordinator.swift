import EnviousWisprCore
import IOKit.pwr_mgt
import EnviousWisprServices
import Foundation

/// A model Setup may download, for the disk preflight and the sleep assertion.
enum OnboardingModel: Hashable, Sendable {
  case speech(ASRBackendType)
  case polish(LocalPolishModelID)
}

/// Why Setup's downloads are held, typed so the screens reuse existing failure presentation
/// (plan §3.4, M8). Retry clears it and starts the current picks again.
enum OnboardingDownloadBlock: Equatable, Sendable {
  /// The chosen pair needs `neededBytes` (manifest totals × 1.2) and the Mac has `freeBytes`.
  case insufficientDisk(neededBytes: Int64, freeBytes: Int64)
  case speechRefused(ASRBackendType)
  case polishRefused(String)
}

/// What the coordinator reports to Setup's telemetry at its existing execution points (#4528
/// chunk F2b, plan §3.8, M68). Observation only: nothing here changes the flow.
enum OnboardingObservation: Equatable {
  /// An accepted transition changed the picks (never a refusal, DEBUG positioning or restore),
  /// with the recommendation the flow held at that moment.
  case choicesCommitted(
    before: OnboardingChoices, after: OnboardingChoices, recommendedSpeech: ASRBackendType,
    recommendedPolish: String)
  /// A Setup download start is about to reach its owner (before any owner call can change the
  /// model's phase). `request` numbers it; its answer reports the same number.
  /// `ownerReportsEnd`: the owner answers only once the attempt ended (Parakeet).
  case downloadStarting(
    OnboardingTelemetry.DownloadModel, request: Int, at: Date, bytes: Int64?, ownerReportsEnd: Bool)
  /// The owner's answer for that start (an accepted attempt only when `.requested`), with the
  /// attempt's end when the owner reports it.
  case downloadAnswered(
    request: Int, OnboardingStartAnswer, ended: OnboardingTelemetry.DownloadResult?)
  /// Cancel on the download screen (or reset): the owners' explicit cancels were sent.
  case downloadsCancelled
  /// The typed download block changed.
  case blockChanged(OnboardingDownloadBlock?, step: OnboardingStep, choices: OnboardingChoices)
  /// Restart Onboarding: the picks start over.
  case reset
  /// Completion is durable (SettingsManager already wrote `.completed`). `interrupted` is a
  /// completion finished on relaunch, with no visit shown.
  case completed(OnboardingChoices, interrupted: Bool)
}

/// Owns the one live Setup flow (#4528 chunk C2b, plan §3.3-3.4, §5). It applies C1's reducer
/// (the only navigation authority), runs each transition's effects in order and orchestrates
/// the existing owners through C2a's adapters. Every async result carries the generation and
/// pick it was started for and is dropped once either changed.
@MainActor
final class OnboardingCoordinator {
  /// The narrow boundaries the coordinator uses. `live(...)` is assembled with the window and
  /// door wiring (C2c); tests inject every one.
  struct Dependencies {
    var downloads: OnboardingDownloads
    var readinessSources: OnboardingReadinessSources
    var legacyState: () -> OnboardingState
    var checkpointData: () -> Data?
    var writeCheckpoint: (Data) -> Void
    /// Writes the coarse projection for readers that still use it; never `.completed`.
    var writeLegacyState: (OnboardingState) -> Void
    /// `onboardingState = .completed` through SettingsManager (deletes the checkpoint, runs
    /// the completion migrations).
    var markCompleted: () -> Void
    /// `SettingsManager.restartOnboarding()`.
    var restartOnboarding: () -> Void
    /// Writes the dictation language pick through SettingsManager (`languageMode`).
    var writeLanguage: (LanguageMode) -> Void
    /// Writes an Apple Intelligence, cloud or off pick through SettingsManager.
    var writeNonLocalPolish: (OnboardingChoices) -> Void
    var savedChoices: () -> OnboardingChoices
    var recommendedSpeech: () -> ASRBackendType
    var recommendedPolish: () -> String
    /// `memoryGiB >= activeRules.parallelDownloadsMinMemoryGiB`.
    var downloadsInParallel: () -> Bool
    /// Manifest `totalBytes` for a model; nil when unknown (delivery's own checks still run).
    var downloadBytes: (OnboardingModel) -> Int64?
    var freeDiskBytes: () -> Int64?
    var acquireSleepAssertion: () -> Void
    var releaseSleepAssertion: () -> Void
    var now: () -> Date
    /// Observers (telemetry and window wiring attach here; none emit from this file).
    var onPracticeOutcome: (OnboardingPracticeOutcome) -> Void = { _ in }
    var onCompleted: () -> Void = {}
  }

  private let deps: Dependencies
  private(set) var state = OnboardingFlowState()
  private(set) var block: OnboardingDownloadBlock? {
    didSet {
      if block != oldValue, !holdBlockObservation { reportBlock() }
    }
  }
  /// Retry clears the block and may set it again in the same call: telemetry sees one change.
  private var holdBlockObservation = false
  /// The last refusal the reducer returned, for the screen to explain a disabled step.
  private(set) var lastRefusal: String?
  /// Bumped by every pick change and by reset; readiness results from an older one drop.
  private(set) var generation = 0
  /// Bumped only when the speech context (engine or language) changes, so a polish pick never
  /// supersedes a still-current speech start (plan M50).
  private(set) var speechGeneration = 0
  /// Every transfer this flow requested, through pick changes, so reset and Cancel reach all
  /// unfinished ones (plan M18, M50).
  private var ownedSpeech: Set<ASRBackendType> = []
  private var ownedPolish: Set<String> = []
  private var speechStartsInFlight = 0
  /// Numbers each download start for telemetry's start/answer pairing (observation only).
  private var downloadRequests = 0
  private(set) var isActive = false
  /// True when this flow was restored from a checkpoint (the first screen shown is a resume, not
  /// a forward move). A narrow observation hook for telemetry (#4528 F2a); never navigation.
  private(set) var resumedFromCheckpoint = false
  private var startedAt: Date?
  private var queuedPolish: String?
  private var holdsSleepAssertion = false
  private var speechTask: Task<Void, Never>?
  private var readinessTask: Task<Void, Never>?
  /// Every task this coordinator started and has not yet awaited; `settle()` drains it.
  private var startedTasks: [Task<Void, Never>] = []
  /// Fires after every published change, so the screens and tests read the new state.
  var onChange: (() -> Void)?
  /// Telemetry's observation hook (F2b); `OnboardingTelemetryObserver.attach` sets it.
  var onObservation: ((OnboardingObservation) -> Void)?

  init(dependencies: Dependencies) {
    deps = dependencies
  }

  // MARK: Restore and presentation

  /// Whether Setup should be shown. Completed installs never open it; an interrupted
  /// completion is finished here without showing Setup or repeating practice.
  @discardableResult
  func begin() -> Bool {
    if isActive { return true }  // Refocus or reopen: same flow, no restart.
    switch OnboardingRestore.resolve(
      legacyState: deps.legacyState(), checkpointData: deps.checkpointData(),
      recommendedSpeech: deps.recommendedSpeech(), recommendedPolish: deps.recommendedPolish(),
      saved: deps.savedChoices())
    {
    case .completed:
      return false
    case .finishCompletion(let outcome):
      // The checkpoint's picks, read before `markCompleted` deletes it, for the summary.
      let choices = resolvedChoices(
        OnboardingCheckpoint.decode(deps.checkpointData())?.choices ?? OnboardingChoices())
      if let outcome { deps.onPracticeOutcome(outcome) }
      deps.markCompleted()
      onObservation?(.completed(choices, interrupted: true))
      deps.onCompleted()
      return false
    case .fresh:
      state = freshState()
      startedAt = deps.now()
      resumedFromCheckpoint = false
    case .resume(let restored, let restoredStart):
      state = restored
      startedAt = restoredStart ?? deps.now()
      resumedFromCheckpoint = true
    }
    isActive = true
    onChange?()
    return true
  }

  /// Completes when every task this coordinator started has finished: the subject's own
  /// completion signal for callers that must observe a result (tests, the door).
  func settle() async {
    while !startedTasks.isEmpty {
      let tasks = startedTasks
      startedTasks.removeAll()
      for task in tasks { await task.value }
    }
  }

  /// The window closed: the checkpoint and the downloads stay; `begin()` resumes the same flow.
  func windowClosed() {}

  /// Practice is usable only once the CURRENT picks are re-measured ready (a resumed Practice
  /// starts with empty readiness).
  var isPracticeUsable: Bool { state.step == .practice && state.isReadyForPractice }

  // MARK: Events

  func send(_ event: OnboardingEvent) {
    guard isActive else { return }
    let before = state
    let transition = OnboardingFlow.reduce(state, event)
    if case .refused(let why) = transition.outcome {
      lastRefusal = why
      onChange?()
      return
    }
    lastRefusal = nil
    if before.choices != transition.state.choices {
      // Before effects, so a final transition's completion follows its picks.
      onObservation?(
        .choicesCommitted(
          before: before.choices, after: transition.state.choices,
          recommendedSpeech: transition.state.recommendedSpeech,
          recommendedPolish: transition.state.recommendedPolish))
      generation &+= 1
      readinessTask?.cancel()
    }
    if before.choices.speech != transition.state.choices.speech
      || before.choices.languageMode != transition.state.choices.languageMode
    {
      speechGeneration &+= 1
      speechTask?.cancel()
    }
    apply(transition, after: before)
  }

  /// Re-measures readiness for the current picks and feeds it to the flow. Live producers
  /// (polling, owner observers) call this; a result for an older generation or pick drops.
  func refreshReadiness() {
    guard isActive else { return }
    let generation = generation
    let choices = state.choices
    readinessTask?.cancel()
    readinessTask = Task { [weak self] in
      guard let self else { return }
      let readiness = await OnboardingReadinessReader.measure(
        choices, from: self.deps.readinessSources)
      guard !Task.isCancelled, self.isActive, self.generation == generation,
        self.state.choices == choices
      else { return }
      self.startQueuedPolishIfSpeechInstalled()
      self.updateSleepAssertion()
      self.send(.readinessChanged(readiness))
    }
    if let readinessTask { startedTasks.append(readinessTask) }
  }

  /// A readiness-relevant fact changed: clear the facts first, so an old pass (a replaced key, a
  /// revoked grant, an unloaded model) can never stand while the re-measure is pending, then
  /// re-measure. Clearing never moves the flow backward.
  func invalidateReadiness() {
    guard isActive else { return }
    readinessTask?.cancel()
    send(.readinessChanged(OnboardingReadiness()))
    refreshReadiness()
  }

  // MARK: Downloads

  /// Retry after a block: clears it and starts the current picks again.
  func retryDownloads() {
    guard isActive else { return }
    let previous = block
    holdBlockObservation = true
    block = nil
    if let speech = state.choices.speech { startSpeech(speech, retry: true) }
    if let polish = state.choices.polish { startPolish(polish, retry: true) }
    holdBlockObservation = false
    if block != previous { reportBlock() }
    onChange?()
  }

  /// Cancel on the download screen: the OWNERS' explicit cancels (a coordinator task
  /// cancellation never stops a transfer), then the coordinator's own work.
  func cancelDownloads() {
    cancelOwnedTransfers()
    onObservation?(.downloadsCancelled)
    queuedPolish = nil
    speechTask?.cancel()
    generation &+= 1
    speechGeneration &+= 1
    updateSleepAssertion()
    onChange?()
  }

  // MARK: Lifecycle

  /// Restart Onboarding: cancels this flow's downloads (installed models and stored keys
  /// stay), invalidates pending work and readiness, deletes the checkpoint through
  /// SettingsManager and starts at Welcome.
  func reset() {
    cancelDownloads()
    readinessTask?.cancel()
    block = nil
    lastRefusal = nil
    deps.restartOnboarding()
    state = freshState()
    startedAt = deps.now()
    resumedFromCheckpoint = false
    isActive = true
    onObservation?(.reset)
    onChange?()
  }

  #if DEBUG
    /// DEBUG positioning for the door's `onboarding goto` (plan §3.9): never evidence that a
    /// prerequisite passed. It ends pending speech and readiness work, clears readiness (re-
    /// measured live), then saves the checkpoint and the legacy projection like any move.
    /// `done` is refused by the door: finishing goes through the real events.
    func debugGoto(_ step: OnboardingStep) {
      guard isActive, step != .done else { return }
      speechTask?.cancel()
      readinessTask?.cancel()
      generation &+= 1
      speechGeneration &+= 1
      var target = state
      target.step = step
      target.readiness = OnboardingReadiness()
      apply(
        OnboardingTransition(state: target, outcome: .moved, effects: [.persistCheckpoint]),
        after: state)
    }
  #endif

  /// App quit: the checkpoint is already written and delivery resumes partial bytes on the
  /// next launch, so only the coordinator's own work and the sleep assertion end.
  func quit() {
    isActive = false
    speechTask?.cancel()
    readinessTask?.cancel()
    generation &+= 1
    speechGeneration &+= 1
    updateSleepAssertion()
  }

  // MARK: Private

  private func nextDownloadRequest() -> Int {
    downloadRequests &+= 1
    return downloadRequests
  }

  private func reportBlock() {
    onObservation?(.blockChanged(block, step: state.step, choices: state.choices))
  }

  private func freshState() -> OnboardingFlowState {
    var s = OnboardingFlowState()
    s.recommendedSpeech = deps.recommendedSpeech()
    s.recommendedPolish = deps.recommendedPolish()
    return s
  }

  /// Explicit owner cancels for every unfinished transfer this flow requested; installed
  /// models are left alone (a cancel records a decline for some owners).
  private func cancelOwnedTransfers() {
    for engine in ownedSpeech where deps.downloads.speechPhase(engine) != .installed {
      deps.downloads.cancelSpeech(engine)
    }
    for id in ownedPolish where deps.downloads.polishPhase(id) != .installed {
      deps.downloads.cancelPolish(id)
    }
    ownedSpeech.removeAll()
    ownedPolish.removeAll()
  }

  private func apply(_ transition: OnboardingTransition, after before: OnboardingFlowState) {
    var deferred: [OnboardingEffect] = []
    for effect in transition.effects {
      switch effect {
      case .persistCheckpoint:
        // Before the new step is published (plan §5 pre-terminal ordering).
        let checkpoint = OnboardingCheckpoint(
          state: transition.state, startedAt: startedAt ?? deps.now(), savedAt: deps.now())
        if let data = try? checkpoint.encoded() { deps.writeCheckpoint(data) }
      default:
        deferred.append(effect)
      }
    }
    state = transition.state
    if let language = state.choices.languageMode, language != before.choices.languageMode {
      // Before any speech work that depends on it.
      deps.writeLanguage(language)
    }
    let legacy = state.legacyState
    if legacy != before.legacyState, legacy != .completed { deps.writeLegacyState(legacy) }
    if before.choices.polish != state.choices.polish
      || before.choices.cloudProvider != state.choices.cloudProvider
      || before.choices.cloudModel != state.choices.cloudModel,
      let polish = state.choices.polish, OnboardingDownloads.localModel(forPolish: polish) == nil
    {
      deps.writeNonLocalPolish(state.choices)
      queuedPolish = nil
    }
    for effect in deferred {
      switch effect {
      case .persistCheckpoint: break
      case .startSpeechDownload(let engine): startSpeech(engine, retry: false)
      case .startPolishDownload(let id): startPolish(id, retry: false)
      case .recordPracticeOutcome(let outcome): deps.onPracticeOutcome(outcome)
      case .markCompleted: complete()
      }
    }
    onChange?()
  }

  private func complete() {
    speechTask?.cancel()
    readinessTask?.cancel()
    queuedPolish = nil
    isActive = false
    updateSleepAssertion()
    deps.markCompleted()
    // After the durable write, before completion hands Setup back.
    onObservation?(.completed(resolvedChoices(state.choices), interrupted: false))
    deps.onCompleted()
  }

  /// The picks for the completion summary: any pick the flow never set reads the saved setting.
  private func resolvedChoices(_ choices: OnboardingChoices) -> OnboardingChoices {
    let saved = deps.savedChoices()
    var c = choices
    if c.languageMode == nil { c.languageMode = saved.languageMode }
    if c.speech == nil { c.speech = saved.speech }
    if c.polish == nil {
      c.polish = saved.polish
      c.cloudProvider = saved.cloudProvider
      c.cloudModel = saved.cloudModel
    }
    return c
  }

  /// The selected pair still to download, × 1.2, against free space (plan M8). Installed
  /// models add nothing; unknown sizes or free space skip the check (delivery checks again).
  private func preflightBlock() -> OnboardingDownloadBlock? {
    guard let free = deps.freeDiskBytes() else { return nil }
    var needed: Int64 = 0
    if let speech = state.choices.speech, deps.downloads.speechPhase(speech) != .installed {
      needed += deps.downloadBytes(.speech(speech)) ?? 0
    }
    if let polish = state.choices.polish,
      let model = OnboardingDownloads.localModel(forPolish: polish),
      deps.downloads.polishPhase(polish) != .installed
    {
      needed += deps.downloadBytes(.polish(model)) ?? 0
    }
    let withMargin = needed + needed / 5
    return free < withMargin ? .insufficientDisk(neededBytes: withMargin, freeBytes: free) : nil
  }

  private func startSpeech(_ engine: ASRBackendType, retry: Bool) {
    if let blocked = preflightBlock() {
      block = blocked
      return
    }
    let speechGeneration = speechGeneration
    speechTask?.cancel()
    ownedSpeech.insert(engine)
    speechStartsInFlight += 1
    updateSleepAssertion()
    let bytes = deps.downloadBytes(.speech(engine))
    speechTask = Task { [weak self] in
      guard let self else { return }
      defer {
        self.speechStartsInFlight -= 1
        self.updateSleepAssertion()
      }
      // A cancelled task still enters its body: do nothing (not even the pick write) once it
      // was cancelled or superseded before it ran.
      guard !Task.isCancelled, self.speechGeneration == speechGeneration else { return }
      // Parakeet answers only after its attempt, so the attempt starts here, before the owner
      // (a retry clears the old failure) can change the phase.
      let request = self.nextDownloadRequest()
      self.onObservation?(
        .downloadStarting(
          .speech(engine), request: request, at: self.deps.now(), bytes: bytes,
          ownerReportsEnd: self.deps.downloads.speechReportsEnd(engine)))
      let start =
        retry
        ? await self.deps.downloads.retrySpeech(engine)
        : await self.deps.downloads.startSpeech(engine)
      // Every answer, even when the pick has since changed (a late answer keeps its own start).
      self.onObservation?(.downloadAnswered(request: request, start.answer, ended: start.ended))
      // Re-check after the (possibly whole-attempt) await before publishing anything.
      guard !Task.isCancelled, self.isActive, self.speechGeneration == speechGeneration,
        self.state.choices.speech == start.id
      else { return }
      switch start.answer {
      case .refused: self.block = .speechRefused(engine)
      case .superseded, .noDownload: break
      case .requested, .alreadyInstalled: self.startQueuedPolishIfSpeechInstalled()
      }
      self.onChange?()
    }
    if let speechTask { startedTasks.append(speechTask) }
  }

  private func startPolish(_ id: String, retry: Bool) {
    guard OnboardingDownloads.localModel(forPolish: id) != nil else { return }
    if let blocked = preflightBlock() {
      block = blocked
      return
    }
    // Below the memory threshold polish waits for speech to be on the Mac (plan §3.4).
    if !deps.downloadsInParallel(), let speech = state.choices.speech,
      deps.downloads.speechPhase(speech) != .installed
    {
      queuedPolish = id
      return
    }
    queuedPolish = nil
    let request = nextDownloadRequest()
    let bytes = OnboardingDownloads.localModel(forPolish: id).flatMap {
      deps.downloadBytes(.polish($0))
    }
    onObservation?(
      .downloadStarting(
        .polish(id), request: request, at: deps.now(), bytes: bytes, ownerReportsEnd: false))
    let start = retry ? deps.downloads.retryPolish(id) : deps.downloads.startPolish(id)
    if start.answer == .requested { ownedPolish.insert(id) }
    onObservation?(.downloadAnswered(request: request, start.answer, ended: start.ended))
    guard state.choices.polish == start.id else { return }
    if start.answer == .refused { block = .polishRefused(id) }
    updateSleepAssertion()
  }

  /// Starts the queued polish only if it is still the current pick and speech is installed.
  private func startQueuedPolishIfSpeechInstalled() {
    guard let queued = queuedPolish else { return }
    guard state.choices.polish == queued else {
      queuedPolish = nil
      return
    }
    guard let speech = state.choices.speech, deps.downloads.speechPhase(speech) == .installed
    else { return }
    startPolish(queued, retry: false)
  }

  /// Holds the idle-sleep assertion while a speech start is being decided or any transfer
  /// this flow requested is downloading or verifying (plan M30). A queued polish waiting on a
  /// failed speech download holds nothing (M50). Never held once the flow is inactive.
  private func updateSleepAssertion() {
    let active: (OnboardingDownloadPhase?) -> Bool = { phase in
      switch phase {
      case .downloading, .verifying: true
      default: false
      }
    }
    let running =
      isActive
      && (speechStartsInFlight > 0
        || ownedSpeech.contains { active(deps.downloads.speechPhase($0)) }
        || ownedPolish.contains { active(deps.downloads.polishPhase($0)) })
    if running, !holdsSleepAssertion {
      deps.acquireSleepAssertion()
      holdsSleepAssertion = true
    } else if !running, holdsSleepAssertion {
      deps.releaseSleepAssertion()
      holdsSleepAssertion = false
    }
  }
}

extension OnboardingCoordinator {
  /// Writes an Apple Intelligence, cloud or off pick through SettingsManager: the provider,
  /// then the cloud model (after the provider, whose setter canonicalizes the model).
  static func writeNonLocalPolish(_ choices: OnboardingChoices, to settings: SettingsManager) {
    switch choices.polish {
    case OnboardingChoices.polishOff?:
      settings.llmProvider = .none
    case OnboardingChoices.polishCloud?:
      guard let provider = choices.cloudProvider else { return }
      settings.llmProvider = provider
      if let model = choices.cloudModel { settings.llmModel = model }
    case let id? where SetupRules.registeredPolish[id]?.provider == .appleIntelligence:
      settings.llmProvider = .appleIntelligence
    default:
      return
    }
  }
}

/// The idle-sleep assertion Setup holds while its downloads run (plan M30), the same IOKit
/// assertion and reason the old onboarding view model used. Acquire and release are idempotent.
@MainActor
final class OnboardingSleepAssertion {
  private var assertionID: IOPMAssertionID = 0
  private var held = false

  func acquire() {
    guard !held else { return }
    let reason = "EnviousWispr is downloading the speech model" as CFString
    held =
      IOPMAssertionCreateWithName(
        kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
        IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &assertionID) == kIOReturnSuccess
  }

  func release() {
    guard held else { return }
    IOPMAssertionRelease(assertionID)
    held = false
  }
}
