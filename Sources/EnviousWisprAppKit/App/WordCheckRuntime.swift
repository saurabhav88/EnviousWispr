import EnviousWisprCore
import EnviousWisprModelDelivery
import EnviousWisprPipeline
import EnviousWisprWordCheck
import Foundation

/// Owns the word check for polish engines without a learned-word checker of their own (#3242):
/// when its model downloads (`WordCheckFetchPolicy`), when it is in memory, and the selection a
/// take gets from it. One owner so the download, the loaded model and the Dictionary row cannot
/// disagree.
///
/// Memory: the 4-bit model holds about 480 MB while loaded (measured on an M5 Max). It is loaded
/// when a take needs it or when the inputs say one soon will (launch, admission, a settings
/// change), and released after `idleUnloadDelay` without a take, when the Dictionary switch goes
/// off, or when no chosen engine needs it any more.
@MainActor
final class WordCheckRuntime {
  /// How the Dictionary row names this check ("Checked by: ...").
  static let judge = LearnedWordJudge(
    displayName: String(
      localized: "Envious Word Check",
      comment:
        "Your Words, Learn from: the name of the on-device word check used when the polish engine has none of its own."
    ))

  static let idleUnloadDelay: Duration = .seconds(600)

  private let delivery: ModelDeliveryHome
  private let isDictionaryEnabled: @MainActor () -> Bool
  private let someEngineLacksOwnChecker: @MainActor () -> Bool
  private let isOnboardingComplete: @MainActor () -> Bool
  /// The Dictionary row re-reads its selection when this fires.
  var onStatusChange: @MainActor () -> Void = {}

  private var deliveryState: DeliveryState = .notReady
  private var launchProbeFinished = false
  private var loaded: (model: KevWordCheckModel, contract: KevContract)?
  private var loadTask: Task<Void, Never>?
  /// The revision a load failed for; retried only after the admitted bytes change.
  private var failedLoadRevision: String?
  private var idleUnloadTask: Task<Void, Never>?

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
      unload(reason: "not_wanted")
      onStatusChange()
      return
    }
    if case .admitted = deliveryState {
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
        userInitiated: userInitiated))
    fetchDecisionsForTests.append(decision)
    Task {
      await AppLogger.shared.log("word check fetch \(trigger): \(decision)", category: "WordCheck")
    }
    if decision == .start { delivery.startWordCheckDownload() }
  }

  private func deliveryStateChanged(_ state: DeliveryState) {
    let wasAdmitted: Bool
    if case .admitted = deliveryState { wasAdmitted = true } else { wasAdmitted = false }
    deliveryState = state
    if case .admitted = state {
      if !wasAdmitted { failedLoadRevision = nil }
      if wanted { startLoadIfNeeded() }
    } else if wasAdmitted {
      // Removed or superseded: the loaded model may point at deleted files.
      unload(reason: "delivery_\(state)")
    }
    onStatusChange()
  }

  private func startLoadIfNeeded() {
    guard loaded == nil, loadTask == nil,
      let registration = delivery.wordCheckRegistration,
      failedLoadRevision != registration.manifest.identity.revision
    else { return }
    let folder = registration.installDirectory
    let revision = registration.manifest.identity.revision
    loadTask = Task { [weak self] in
      let started = ContinuousClock.now
      do {
        let model = try await KevWordCheckModel(folder: folder)
        let contract = await model.contract
        let elapsed = ContinuousClock.now - started
        guard let self else { return }
        self.loadTask = nil
        guard self.wanted else { return }  // turned off while loading: drop it
        self.loaded = (model, contract)
        self.scheduleIdleUnload()
        self.onStatusChange()
        await AppLogger.shared.log(
          "word check loaded revision=\(contract.revision) ms=\(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)",
          category: "WordCheck")
      } catch {
        guard let self else { return }
        self.loadTask = nil
        self.failedLoadRevision = revision
        self.onStatusChange()
        await AppLogger.shared.log(
          "word check load failed revision=\(revision): \(error)", level: .info,
          category: "WordCheck")
      }
    }
  }

  private func unload(reason: String) {
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
      guard !Task.isCancelled else { return }
      self?.unload(reason: "idle")
    }
  }

  /// "Try again" in the Dictionary row.
  func retryDownload() { refresh(trigger: "settings_retry", userInitiated: true) }

  /// The selection for one take whose polish engine has no checker of its own. Awaits an
  /// in-progress load: `LearnedWordCheckStep.selectionDeadline` bounds that wait, and a load that
  /// outlives it finishes in the background for the next take.
  func selection() async -> LearnedWordCheckerSelection {
    func absent(_ reason: LearnedWordCheckerAbsence, retry: Bool = false)
      -> LearnedWordCheckerSelection
    {
      .init(absence: reason, retryAvailable: retry, judge: Self.judge)
    }
    guard let handle = delivery.wordCheckHandle, let registration = delivery.wordCheckRegistration
    else { return absent(.adapterDeliveryFailed) }
    switch deliveryState {
    case .admitted:
      break
    case .failed, .cancelled:
      return handle.isEnabled()
        ? absent(.adapterDeliveryFailed, retry: true) : absent(.deliveryDisabled)
    case .notReady, .preparing, .downloading, .verifying:
      guard handle.isEnabled() else { return absent(.deliveryDisabled) }
      refresh(trigger: "take")
      return absent(.adapterDownloading)
    }
    if loaded == nil {
      if failedLoadRevision == registration.manifest.identity.revision {
        return absent(.serverUnavailable)
      }
      startLoadIfNeeded()
      await loadTask?.value
    }
    guard let loaded else { return absent(.serverUnavailable) }
    scheduleIdleUnload()
    return LearnedWordCheckerSelection(
      checker: KevLearnedWordChecker(model: loaded.model, contract: loaded.contract),
      identity: loaded.contract.revision, judge: Self.judge)
  }
}
