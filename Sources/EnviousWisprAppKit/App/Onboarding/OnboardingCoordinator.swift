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
  private(set) var block: OnboardingDownloadBlock?
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
  private(set) var isActive = false
  private var startedAt: Date?
  private var queuedPolish: String?
  private var holdsSleepAssertion = false
  private var speechTask: Task<Void, Never>?
  private var readinessTask: Task<Void, Never>?
  /// Every task this coordinator started and has not yet awaited; `settle()` drains it.
  private var startedTasks: [Task<Void, Never>] = []
  /// Fires after every published change, so the screens and tests read the new state.
  var onChange: (() -> Void)?

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
      if let outcome { deps.onPracticeOutcome(outcome) }
      deps.markCompleted()
      deps.onCompleted()
      return false
    case .fresh:
      state = freshState()
      startedAt = deps.now()
    case .resume(let restored, let restoredStart):
      state = restored
      startedAt = restoredStart ?? deps.now()
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

  // MARK: Downloads

  /// Retry after a block: clears it and starts the current picks again.
  func retryDownloads() {
    guard isActive else { return }
    block = nil
    if let speech = state.choices.speech { startSpeech(speech, retry: true) }
    if let polish = state.choices.polish { startPolish(polish, retry: true) }
    onChange?()
  }

  /// Cancel on the download screen: the OWNERS' explicit cancels (a coordinator task
  /// cancellation never stops a transfer), then the coordinator's own work.
  func cancelDownloads() {
    cancelOwnedTransfers()
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
    isActive = true
    onChange?()
  }

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
    deps.onCompleted()
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
    speechTask = Task { [weak self] in
      guard let self else { return }
      defer {
        self.speechStartsInFlight -= 1
        self.updateSleepAssertion()
      }
      // A cancelled task still enters its body: do nothing (not even the pick write) once it
      // was cancelled or superseded before it ran.
      guard !Task.isCancelled, self.speechGeneration == speechGeneration else { return }
      let start =
        retry
        ? await self.deps.downloads.retrySpeech(engine)
        : await self.deps.downloads.startSpeech(engine)
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
    let start = retry ? deps.downloads.retryPolish(id) : deps.downloads.startPolish(id)
    if start.answer == .requested { ownedPolish.insert(id) }
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
