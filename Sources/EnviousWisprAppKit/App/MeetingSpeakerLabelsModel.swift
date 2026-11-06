import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprModelDelivery
import EnviousWisprServices
import Foundation
import Observation
import os

/// #4355 PR C: what the speaker labels load check found.
enum LiveSpeakerLoadCheckOutcome: Sendable, Equatable {
  case loaded
  case failed
  /// Stopped before an answer (a meeting started, or Remove).
  case cancelled
}

/// #4355 PR C: loads the admitted speaker model once in a short-lived `LiveSpeakerSession` (its
/// production loader and compute policy, off the main actor), then closes it.
///
/// Returns only after the session reported the model physically released, so a removal that
/// awaits this never deletes files under a loading model. Cancellation closes the session at
/// once; a load already running finishes on the session's own queue and is dropped unused.
enum LiveSpeakerLoadCheck {
  static func runFinal(directory: URL) async -> LiveSpeakerLoadCheckOutcome {
    do {
      try await MeetingNeuralSpeakerAnalyzer.checkLoad(directory: directory, preset: .offline)
      return Task.isCancelled ? .cancelled : .loaded
    } catch is CancellationError {
      return .cancelled
    } catch {
      return .failed
    }
  }

  static func run(
    directory: URL,
    loader: @escaping LiveSpeakerRuntimeLoader = Nemotron3LiveSpeakerRuntime.nemotron3Low
  ) async -> LiveSpeakerLoadCheckOutcome {
    let box = Box()
    let session = LiveSpeakerSession(
      directory: directory, admit: { false }, backlogLimitSamples: 0, loader: loader,
      publish: { update in
        // Short and non-blocking: the session calls this on its own queue.
        switch update {
        case .ready: box.decide(.loaded)
        case .unavailable: box.decide(.failed)
        case .activity, .reset: break
        }
      },
      onReleased: { box.markReleased() })
    // Plain continuations, never a cancellation-aware stream: a cancelled check must still wait
    // for the release before it returns.
    return await withTaskCancellationHandler {
      session.start()
      let found = await box.decision()
      session.end()
      await box.release()
      return Task.isCancelled ? .cancelled : found
    } onCancel: {
      box.decide(.cancelled)
      session.end()
    }
  }

  /// The first answer and the release, each awaited once.
  private final class Box: Sendable {
    private struct State: Sendable {
      var found: LiveSpeakerLoadCheckOutcome?
      var released = false
      var decisionWaiter: CheckedContinuation<LiveSpeakerLoadCheckOutcome, Never>?
      var releaseWaiter: CheckedContinuation<Void, Never>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func decide(_ outcome: LiveSpeakerLoadCheckOutcome) {
      let waiter = state.withLock { s -> CheckedContinuation<LiveSpeakerLoadCheckOutcome, Never>? in
        guard s.found == nil else { return nil }
        s.found = outcome
        defer { s.decisionWaiter = nil }
        return s.decisionWaiter
      }
      waiter?.resume(returning: outcome)
    }

    /// A release with no answer (closed before the load finished) answers cancelled.
    func markReleased() {
      decide(.cancelled)
      let waiter = state.withLock { s -> CheckedContinuation<Void, Never>? in
        s.released = true
        defer { s.releaseWaiter = nil }
        return s.releaseWaiter
      }
      waiter?.resume()
    }

    func decision() async -> LiveSpeakerLoadCheckOutcome {
      await withCheckedContinuation { continuation in
        let now = state.withLock { s -> LiveSpeakerLoadCheckOutcome? in
          if let found = s.found { return found }
          s.decisionWaiter = continuation
          return nil
        }
        if let now { continuation.resume(returning: now) }
      }
    }

    func release() async {
      await withCheckedContinuation { continuation in
        let now = state.withLock { s -> Bool in
          if s.released { return true }
          s.releaseWaiter = continuation
          return false
        }
        if now { continuation.resume() }
      }
    }
  }
}

/// #4355 PR C: the Speaker labels card's model (EnviousMeet > Models). Downloads go through the
/// one door, `ModelDeliveryHome.requestLiveSpeakerModel(meetingActive:)`; this model adds only
/// what the delivery layer cannot know: whether the admitted model actually loads on this Mac.
///
/// App-owned (like `MeetingLiveWordsRowModel`), so closing Settings never cancels or orphans a
/// check. Ready is shown only after a check of the admitted bytes succeeded and released the
/// model; nothing stays resident for the badge. Checks run when the card asks (it appears, or the
/// download finishes while it is shown), never at launch.
@Observable @MainActor
final class MeetingSpeakerLabelsModel {
  struct Environment {
    /// Nil when the model is not in this build.
    let deliveryState: @MainActor () -> DeliveryState?
    let downloadBytes: @MainActor () -> Int64?
    let downloadQueued: @MainActor () -> Bool
    let downloadRefused: @MainActor () -> Bool
    let request:
      @MainActor (_ meetingActive: Bool) -> ModelDeliveryHome.LiveSpeakerModelRequestOutcome
    let cancel: @MainActor () -> Void
    let remove: @MainActor () -> ModelDeliveryHome.LiveSpeakerModelRemovalOutcome
    let admittedDirectory: @MainActor () async -> URL?
    /// A meeting records or processes (`MeetingCoordinator.isMeetingActive`).
    let isMeetingActive: @MainActor () -> Bool
    let check: @Sendable (URL) async -> LiveSpeakerLoadCheckOutcome
    /// Called once per completed check with its real result (loaded or failed); a stopped check
    /// is not a result and is never reported (`speaker_labels.load_check`).
    var report: @MainActor (_ loaded: Bool) -> Void = { _ in }
    var finalDeliveryState: @MainActor () -> DeliveryState? = { nil }
    var finalAdmittedDirectory: @MainActor () async -> URL? = { nil }
    var finalCheck: @Sendable (URL) async -> LiveSpeakerLoadCheckOutcome = { directory in
      await LiveSpeakerLoadCheck.runFinal(directory: directory)
    }
    var includesFinalModel = false

    static func live(
      home: ModelDeliveryHome, isMeetingActive: @escaping @MainActor () -> Bool
    ) -> Environment {
      Environment(
        deliveryState: { [home] in home.speakerLiveHandle == nil ? nil : home.speakerLiveState },
        downloadBytes: { [home] in home.speakerModelsDownloadBytes },
        downloadQueued: { [home] in home.speakerLiveDownloadQueued },
        downloadRefused: { [home] in home.speakerLiveDownloadRefused },
        request: { [home] in home.requestLiveSpeakerModel(meetingActive: $0) },
        cancel: { [home] in home.cancelLiveSpeakerModelDownload() },
        remove: { [home] in home.removeLiveSpeakerModel() },
        admittedDirectory: { [home] in await home.admittedLiveSpeakerModelDirectory() },
        isMeetingActive: isMeetingActive,
        check: { [home] directory in
          do {
            return try await home.withSpeakerModelUse(finished: false) { admitted -> LiveSpeakerLoadCheckOutcome in
              guard directory == admitted else { return .cancelled }
              return await LiveSpeakerLoadCheck.run(directory: admitted)
            } ?? .cancelled
          } catch { return .cancelled }
        },
        report: { [home] loaded in
          TelemetryService.shared.trackSpeakerLabelsLoadCheck(
            loaded: loaded, modelRevision: home.speakerLiveRegistration?.manifest.identity.revision)
        },
        finalDeliveryState: { [home] in
          home.speakerFinalHandle == nil ? nil : home.speakerFinalState
        },
        finalAdmittedDirectory: { [home] in await home.admittedFinalSpeakerModelDirectory() },
        finalCheck: { [home] directory in
          do {
            return try await home.withSpeakerModelUse(finished: true) { admitted -> LiveSpeakerLoadCheckOutcome in
              guard directory == admitted else { return .cancelled }
              return await LiveSpeakerLoadCheck.runFinal(directory: admitted)
            } ?? .cancelled
          } catch { return .cancelled }
        }, includesFinalModel: true)
    }
  }

  /// Whether the admitted model loads on this Mac. In memory only: a new launch checks again
  /// the first time the card asks.
  enum Readiness: Equatable {
    case unchecked
    case checking
    /// A check was due while a meeting was active; it runs when the meeting ends.
    case waitingForMeeting
    case ready
    case failed
  }

  /// What the card shows, exhaustive over delivery state and readiness.
  enum Status: Equatable {
    case unavailableInThisBuild
    case notDownloaded
    case queuedForMeeting
    /// Bytes so far and total; nil while preparing or verifying (no honest figure).
    case downloading(bytesWritten: Int64?, totalBytes: Int64?)
    case downloadFailed(DeliveryFailure)
    case checking
    case waitingForMeeting
    case ready
    case loadFailed
  }

  private let environment: Environment
  private(set) var readiness: Readiness = .unchecked
  private(set) var finalReadiness: Readiness = .unchecked
  /// Bumped by every new check and every invalidation; a check whose generation moved publishes
  /// nothing.
  private var generation = 0
  /// The latest check. Kept after it is cancelled so the next check (or a removal) waits until it
  /// released the model.
  private var checkTask: Task<Void, Never>?
  /// The latest check, so a test can wait for it to end.
  package var checkTaskForTests: Task<Void, Never>? { checkTask }
  /// Set by the bootstrapper (`MeetingLiveSpeakers.waitForRelease`): a check waits until the last
  /// meeting's speaker model physically released, because `MeetingLiveSpeakers.stop()` returns
  /// before that release and two loaded copies would double the memory use.
  var waitForMeetingRelease: @MainActor () async -> Void = {}

  init(environment: Environment) {
    self.environment = environment
  }

  #if DEBUG
    /// UX-review seam (#4355 PR C): `EW_UAT_SPEAKER_LABELS_STAGE=<state>` at launch shows one
    /// card state with every action inert, so each state can be photographed in the real app
    /// without touching the delivery controller, caches or telemetry. Logged when used; compiled
    /// out of Release.
    private let stagedStatus: Status? = MeetingSpeakerLabelsModel.stagedStatusFromEnvironment()

    private static func stagedStatusFromEnvironment() -> Status? {
      guard let raw = ProcessInfo.processInfo.environment["EW_UAT_SPEAKER_LABELS_STAGE"] else {
        return nil
      }
      let staged: Status? =
        switch raw {
        case "notDownloaded": .notDownloaded
        case "queued": .queuedForMeeting
        case "downloading": .downloading(bytesWritten: 83_886_080, totalBytes: 199_124_357)
        case "checking": .checking
        case "waiting": .waitingForMeeting
        case "ready": .ready
        case "downloadFailed": .downloadFailed(DeliveryFailure(reason: .sourceUnreachable))
        case "loadFailed": .loadFailed
        default: nil
        }
      Task {
        await AppLogger.shared.log(
          "UAT seam: speaker labels card staged as \(raw) (recognised=\(staged != nil))",
          level: .info, category: "Delivery")
      }
      return staged
    }

    private var isStaged: Bool { stagedStatus != nil }
  #else
    private var isStaged: Bool { false }
  #endif

  var status: Status {
    #if DEBUG
      if let stagedStatus { return stagedStatus }
    #endif
    return status(for: environment.deliveryState(), readiness: readiness)
  }

  var finalStatus: Status? {
    if isStaged { return nil }
    guard environment.includesFinalModel || environment.finalDeliveryState() != nil else { return nil }
    return status(for: environment.finalDeliveryState(), readiness: finalReadiness)
  }

  /// One action owner for the pair, without hiding a working live component.
  var actionStatus: Status {
    let live = status
    guard let final = finalStatus else { return live }
    for component in [live, final] {
      switch component {
      case .queuedForMeeting, .downloading: return component
      case .unavailableInThisBuild, .notDownloaded, .downloadFailed, .checking,
        .waitingForMeeting, .ready, .loadFailed: break
      }
    }
    for component in [live, final] {
      switch component {
      case .notDownloaded, .downloadFailed: return component
      case .unavailableInThisBuild, .queuedForMeeting, .downloading, .checking,
        .waitingForMeeting, .ready, .loadFailed: break
      }
    }
    return live == .ready ? final : live
  }

  private func status(for state: DeliveryState?, readiness: Readiness) -> Status {
    guard let state else { return .unavailableInThisBuild }
    if environment.downloadQueued(), state != .admitted { return .queuedForMeeting }
    switch state {
    case .notReady, .cancelled:
      return .notDownloaded
    case .preparing(let validatingExistingCache):
      return validatingExistingCache ? .checking : .downloading(bytesWritten: nil, totalBytes: nil)
    case .downloading(_, let written, let total):
      return .downloading(bytesWritten: written, totalBytes: total)
    case .verifying:
      return .downloading(bytesWritten: nil, totalBytes: nil)
    case .failed(let failure):
      return failure.reason == .cancelled ? .notDownloaded : .downloadFailed(failure)
    case .admitted:
      switch readiness {
      case .unchecked, .checking: return .checking
      case .waitingForMeeting: return .waitingForMeeting
      case .ready: return .ready
      case .failed: return .loadFailed
      }
    }
  }

  var downloadBytes: Int64? { environment.downloadBytes() }
  var downloadRefused: Bool { environment.downloadRefused() }
  var isInstalled: Bool { environment.deliveryState() == .admitted }
  var isFinalInstalled: Bool { environment.finalDeliveryState() == .admitted }
  /// Remove waits for the meeting to end (the delivery home refuses it too).
  var removeWaitsForMeeting: Bool { environment.isMeetingActive() }

  /// The card appeared or the delivery state changed: check an admitted model that has not been
  /// checked; forget readiness once the model is no longer admitted.
  func checkIfNeeded() {
    guard !isStaged else { return }
    if environment.deliveryState() != .admitted {
      if readiness == .checking { invalidate(resetAll: false) }
      readiness = .unchecked
    }
    if environment.finalDeliveryState() != .admitted {
      if finalReadiness == .checking { invalidate(resetAll: false) }
      finalReadiness = .unchecked
    }
    guard readiness != .checking, finalReadiness != .checking else { return }
    if isInstalled, readiness == .unchecked {
      startCheck()
    } else if isFinalInstalled, finalReadiness == .unchecked {
      startCheck(finished: true)
    }
  }

  /// Download, or Try Again after a failed download.
  func download() {
    guard !isStaged else { return }
    _ = environment.request(environment.isMeetingActive())
  }

  func cancel() {
    guard !isStaged else { return }
    environment.cancel()
  }

  func remove() {
    guard !isStaged else { return }
    _ = environment.remove()
  }

  /// Try Again after a failed load check.
  func retryCheck() {
    guard !isStaged else { return }
    if readiness == .failed, isInstalled {
      startCheck()
    } else if finalReadiness == .failed, isFinalInstalled {
      startCheck(finished: true)
    }
  }

  /// A meeting started: a check in progress stops (its load finishes on the session's queue and
  /// is dropped) and runs again when the meeting ends. Recording never waits for it.
  func meetingBecameActive() {
    let liveChecking = readiness == .checking
    let finalChecking = finalReadiness == .checking
    guard liveChecking || finalChecking else { return }
    invalidate(resetAll: false)
    if liveChecking { readiness = .waitingForMeeting }
    if finalChecking { finalReadiness = .waitingForMeeting }
  }

  func meetingBecameIdle() {
    if readiness == .waitingForMeeting { readiness = .unchecked }
    if finalReadiness == .waitingForMeeting { finalReadiness = .unchecked }
    checkIfNeeded()
  }

  /// A meeting's live speakers wait here before loading their own copy: a check stopped by the
  /// meeting start may still be releasing its model.
  func waitForCheckRelease() async {
    await checkTask?.value
  }

  /// `ModelDeliveryHome.drainLiveSpeakerHoldersBeforeRemoval`: invalidate any check and wait
  /// until it released the model, so the files are never deleted under it.
  func releaseForRemoval() async {
    let task = invalidate()
    await task?.value
  }

  private func startCheck(finished: Bool = false) {
    guard !environment.isMeetingActive() else {
      if finished { finalReadiness = .waitingForMeeting } else { readiness = .waitingForMeeting }
      return
    }
    generation += 1
    let current = generation
    let previous = checkTask
    let environment = environment
    if finished { finalReadiness = .checking } else { readiness = .checking }
    checkTask = Task { [weak self] in
      // An earlier check, and the last meeting's speaker model, release before this check loads
      // another copy. The generation guard comes first: a meeting that started meanwhile moved it,
      // so this check never waits on that meeting's model.
      await previous?.value
      guard let waitForMeetingRelease = self?.waitForMeetingRelease, self?.generation == current
      else { return }
      await waitForMeetingRelease()
      guard self?.generation == current else { return }
      let directory = await (finished ? environment.finalAdmittedDirectory() : environment.admittedDirectory())
      guard let directory else {
        self?.finish(current, .cancelled, finished: finished)
        return
      }
      guard self?.generation == current else { return }
      let outcome = await (finished ? environment.finalCheck(directory) : environment.check(directory))
      // The probe's own terminal answer, whatever the card does with it next.
      if !finished {
        // Preserve the existing live-check telemetry meaning; final readiness is local state.
        switch outcome {
        case .loaded: environment.report(true)
        case .failed: environment.report(false)
        case .cancelled: break
        }
      }
      self?.finish(current, outcome, finished: finished)
    }
  }

  private func finish(_ current: Int, _ outcome: LiveSpeakerLoadCheckOutcome, finished: Bool) {
    guard current == generation else { return }
    let next: Readiness
    switch outcome {
    case .loaded:
      let admitted = finished ? isFinalInstalled : isInstalled
      next = admitted ? .ready : .unchecked
    case .failed:
      next = .failed
    case .cancelled:
      next = .unchecked
    }
    if finished { finalReadiness = next } else { readiness = next }
    // A successful live check may have deferred an already admitted final model. The next
    // check waits for this task to return; the two native models are never resident together.
    if outcome != .cancelled { checkIfNeeded() }
  }

  @discardableResult
  private func invalidate(resetAll: Bool = true) -> Task<Void, Never>? {
    generation += 1
    if resetAll || readiness == .checking { readiness = .unchecked }
    if resetAll || finalReadiness == .checking { finalReadiness = .unchecked }
    checkTask?.cancel()
    return checkTask
  }
}
