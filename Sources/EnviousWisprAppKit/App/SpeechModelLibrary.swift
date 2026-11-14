import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprModelDelivery
import EnviousWisprPipeline
import Foundation

/// Reports, installs and removes the speech engine models on this Mac (#4578).
///
/// One app-owned instance, built by the bootstrapper. Settings, Setup and the jobs that need a
/// speech engine reach the models through it instead of each asking a delivery handle or a
/// setup service on its own. It owns no bytes: the delivery handles, the Whisper setup service
/// and the Parakeet upgrade coordinator stay the owners of their mechanics; this type is the one
/// place that decides which of them a speech-model command or question goes to.
@MainActor
@Observable
final class SpeechModelLibrary {
  /// The Whisper parts the removal command drives, attached once `WhisperDeliveryWiring` has
  /// built them (the wiring needs this library's removal command first).
  struct WhisperParts {
    let setupService: WhisperSetupService
    let migration: WhisperModelMigration
    let removal: WhisperRemovalHook
  }

  /// The answer to a download request: refused, accepted (its end is observed later), or
  /// answered once the attempt ended.
  enum DownloadRequest: Sendable {
    case refused
    case accepted
    case ended(ModelDeliveryController.DeliveryOutcome)
  }

  @ObservationIgnored private let modelDelivery: ModelDeliveryHome
  @ObservationIgnored private var whisper: WhisperParts?

  /// Parakeet's physical installation (owned Ultra or owned v3 admitted), nil until the first
  /// read settles. Runtime eligibility (rejection, spent budgets) is NOT part of it: retained
  /// admitted bytes stay installed and removable; the upgrade owner decides whether they load.
  private(set) var parakeetInstalled: Bool?
  /// The delivery facts (`ModelDeliveryHome.parakeetState` and `parakeetPresentationRevision`)
  /// the settled answer was read against. The answer counts only while they are current.
  @ObservationIgnored private var parakeetReadKey: ParakeetFactsKey?

  /// Home's Parakeet delivery facts at one instant.
  struct ParakeetFactsKey: Equatable {
    let state: DeliveryState
    let revision: UInt64
  }

  private var currentParakeetKey: ParakeetFactsKey {
    ParakeetFactsKey(
      state: modelDelivery.parakeetState, revision: modelDelivery.parakeetPresentationRevision)
  }
  /// Bumped by every read, so an older read never overwrites a newer one.
  @ObservationIgnored private var parakeetReadGeneration: UInt64 = 0
  @ObservationIgnored private var parakeetRead: Task<Void, Never>?
  /// Told when an installation fact changes (`EngineCoordinator.poke`), so its status and
  /// switch gate re-read without polling.
  @ObservationIgnored var onInstallationChanged: (@MainActor () -> Void)?

  /// The physical Parakeet read; nil reads the owned Ultra and v3 handles (production). A test
  /// supplies a held read to drive overlapping readers and invalidation.
  @ObservationIgnored private let readParakeetOverride: (@MainActor () async -> Bool)?

  init(
    modelDelivery: ModelDeliveryHome,
    readParakeetForTesting: (@MainActor () async -> Bool)? = nil
  ) {
    self.modelDelivery = modelDelivery
    self.readParakeetOverride = readParakeetForTesting
    // Re-read when Parakeet's delivery or usability may have changed (an admission, a
    // coordinator outcome); removal and install commands refresh on completion themselves.
    modelDelivery.addParakeetUsableObserver { [weak self] in self?.refreshParakeet() }
    observeParakeetDeliveryFacts()
  }

  /// Any change to Parakeet's delivery state or presentation (a transfer, a failure, an upgrade
  /// outcome) makes the settled answer unknown until it is read again, so no reader acts on an
  /// answer that belonged to older delivery facts.
  private func observeParakeetDeliveryFacts() {
    withObservationTracking {
      _ = modelDelivery.parakeetState
      _ = modelDelivery.parakeetPresentationRevision
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.invalidateParakeet()
        self.observeParakeetDeliveryFacts()
      }
    }
  }

  func attachWhisper(_ parts: WhisperParts) {
    whisper = parts
  }

  // MARK: - Installation facts

  /// The settled installation fact, or nil while unknown. Whisper's comes from its setup owner;
  /// a model mid-removal counts as not installed (no new dictation during a removal drain).
  func installedSnapshot(_ engine: ASRBackendType) -> Bool? {
    switch engine {
    case .parakeet:
      // An answer read against older delivery facts is unknown now, in this same turn.
      guard let installed = parakeetInstalled, parakeetReadKey == currentParakeetKey else {
        return nil
      }
      return installed
    case .whisper:
      guard let setup = whisper?.setupService else { return nil }
      if setup.isRemoving { return false }
      switch setup.setupState {
      case .checking: return nil
      case .ready: return true
      default: return false
      }
    }
  }

  /// The installation fact, read fresh when the snapshot is unknown. Never guesses "missing"
  /// from an unknown answer: it awaits the read.
  func freshInstalled(_ engine: ASRBackendType) async -> Bool {
    if let known = installedSnapshot(engine) { return known }
    switch engine {
    case .parakeet:
      // Join the read in flight (never start a competing one); when a newer read replaced it,
      // wait for that one, until a current answer settles. Unknown never becomes false.
      if parakeetRead == nil { refreshParakeet() }
      while true {
        if let known = installedSnapshot(.parakeet) { return known }
        guard let read = parakeetRead else {
          refreshParakeet()
          continue
        }
        await read.value
      }
    case .whisper:
      await whisper?.setupService.forceDetectState()
      return installedSnapshot(.whisper) ?? false
    }
  }

  /// The set of engines installed now, each read fresh when unknown.
  func freshInstalledEngines() async -> Set<ASRBackendType> {
    var installed: Set<ASRBackendType> = []
    for engine in [ASRBackendType.parakeet, .whisper] where await freshInstalled(engine) {
      installed.insert(engine)
    }
    return installed
  }

  /// The delivery facts changed: the settled answer is unknown until the new read lands.
  func invalidateParakeet() {
    parakeetInstalled = nil
    refreshParakeet()
  }

  /// Whether `job` may start on `requested` now (the `SpeechJobAdmission` rule over fresh
  /// facts). The one call every job's owner makes before it records, loads or warms.
  func admits(_ job: SpeechJobAdmission.Job, requested: ASRBackendType) async -> Bool {
    let installed: Set<ASRBackendType> = await freshInstalled(requested) ? [requested] : []
    return SpeechJobAdmission.decide(job, requested: requested, installed: installed)
      == .use(requested)
  }

  /// Starts a Parakeet read. The launch migration of a donor copy is joined first, so an
  /// install that exists only as the older shared copy is read after it has been adopted.
  func refreshParakeet() {
    parakeetReadGeneration &+= 1
    let generation = parakeetReadGeneration
    let delivery = modelDelivery
    let override = readParakeetOverride
    let startKey = currentParakeetKey
    parakeetRead = Task { [weak self] in
      let installed: Bool
      if let override {
        installed = await override()
      } else {
        await delivery.awaitLaunchMigration()
        let ultra = await delivery.parakeetHandle?.isAdmitted() ?? false
        let v3 = await delivery.parakeetRetiredV3Handle?.isAdmitted() ?? false
        installed = ultra || v3
      }
      // A newer read (an invalidation) owns the answer now; this one publishes nothing.
      guard let self, generation == self.parakeetReadGeneration else { return }
      self.parakeetRead = nil
      // The delivery facts changed while this read ran: it describes neither; publish nothing
      // (the facts observation, or a waiting reader, starts the read for the new facts).
      guard self.currentParakeetKey == startKey else { return }
      self.parakeetReadKey = startKey
      let changed = installed != self.parakeetInstalled
      self.parakeetInstalled = installed
      if changed { self.onInstallationChanged?() }
    }
  }

  // MARK: - Delivery facts

  /// Whether this engine's delivery kill switch allows a download now, read fresh.
  func isDeliveryEnabled(_ engine: ASRBackendType) -> Bool {
    switch engine {
    case .parakeet: modelDelivery.parakeetHandle?.isEnabled() ?? false
    case .whisper: modelDelivery.whisperHandle?.isEnabled() ?? false
    }
  }

  // MARK: - Commands

  /// Starts this engine's download through the same door Settings uses. Parakeet answers once
  /// the attempt ended; Whisper's task answers acceptance only.
  func requestDownload(_ engine: ASRBackendType) async -> DownloadRequest {
    switch engine {
    case .parakeet:
      guard let attempt = modelDelivery.resumeParakeetDownload() else { return .refused }
      switch await attempt.value {
      case .refused: return .refused
      case .attempted(let outcome): return .ended(outcome)
      }
    case .whisper:
      guard let setupService = whisper?.setupService else { return .refused }
      return await setupService.downloadModel().value ? .accepted : .refused
    }
  }

  func cancelDownload(_ engine: ASRBackendType) {
    switch engine {
    case .parakeet: modelDelivery.cancelParakeetDownload()
    case .whisper: whisper?.setupService.cancelDownload()
    }
  }

  /// The Whisper setup service's Remove action over `library`, held weakly. nil is success, so a
  /// gone library fails explicitly instead of through `?? .failed` (which would turn a completed
  /// removal into a failure).
  static func whisperRemoveAction(_ library: SpeechModelLibrary)
    -> @MainActor () async -> WhisperRemoveNotice?
  {
    { [weak library] in
      guard let library else { return .failed }
      return await library.removeWhisperModel()
    }
  }

  /// Remove: record the decline, stop any fetch, unload the engine, then delete. The
  /// dictation-in-flight refusal already happened in the presentation layer
  /// (`WhisperSetupService.removeModel`).
  func removeWhisperModel() async -> WhisperRemoveNotice? {
    guard let handle = modelDelivery.whisperHandle, let whisper else { return .failed }
    guard whisper.migration.decline(.dictation) == .done else { return .failed }
    await handle.cancelActiveFetch()
    await whisper.removal.unloadForRemoval()
    let removed = await handle.remove()
    await whisper.removal.finishRemoval()
    return removed ? nil : .failed
  }
}
