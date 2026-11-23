import EnviousWisprCore
import EnviousWisprLocalPolish
import Foundation
import Observation

/// What the presenter needs from one bundled model's runtime (#4845 LIFE-5). `LocalPolishRuntime`
/// is the live source; tests supply their own.
@MainActor
protocol PolishDownloadNoticeSource: AnyObject {
  var modelID: LocalPolishModelID { get }
  var pendingDownloadNotice: PolishDownloadNotice? { get }
  /// Moves each time the shared server is free again (a summary's or the last lease's release).
  var sharedServerReleases: Int { get }
  /// Every fact, including the shared server's (async).
  func isCurrent(_ notice: PolishDownloadNotice) async -> Bool
  /// The runtime's facts plus the coordinator's admission mirror (sync), for the overlay's
  /// pre-render question.
  func isLive(_ notice: PolishDownloadNotice) -> Bool
  func acknowledgeDownloadNotice(_ id: UUID)
}

extension LocalPolishRuntime: PolishDownloadNoticeSource {}

/// #4845 LIFE-5 / D-G: the one "AI polish download complete" pill.
///
/// The runtime earns the notice (a download completed in this process, then a passed probe on the
/// server running exactly that artifact for the current selection). This presenter only decides
/// WHEN: never before Setup is complete, only into an idle overlay slot, and only after the
/// notice is still current. The overlay asks again (`isLive`, no summary holding the server) just
/// before the first render; a stale request is rolled back unrendered. The notice is spent only
/// when the overlay reports `.presented`. A refused attempt (the slot was busy) keeps it and tries
/// again later. In memory only. A limb: when it fails, a pill is missing and dictation is
/// unaffected.
@MainActor
final class PolishDownloadPillPresenter {
  struct Inputs {
    /// Every bundled model's runtime.
    var sources: @MainActor () -> [any PolishDownloadNoticeSource]
    /// First-run Setup is complete (the pill never shows during Setup).
    var setupComplete: @MainActor () -> Bool
    /// An EnviousMeet summary holds the shared server (`LocalPolishRuntimeSet.summaryHeldModel`).
    var summaryHoldsServer: @MainActor () -> Bool
    /// The model's display name ("EG-1 Mini").
    var modelName: @MainActor (LocalPolishModelID) -> String
    /// Runs `work` after `delay` (production: a main-actor task; tests: a manual clock).
    var schedule: @MainActor (Duration, @escaping @MainActor () -> Void) -> Void
    var log: @MainActor (String) -> Void = PolishDownloadPillPresenter.appLog
  }

  /// How long a refused attempt waits before the next try (the slot held another pill).
  static let retryDelay: Duration = .seconds(10)

  private let overlay: any OverlayPresenting
  private let inputs: Inputs
  /// The notice an attempt is working on (from the async check to the overlay's result).
  private var inFlight: UUID?
  private var retryScheduled = false
  /// The latest attempt's check-and-request, for tests to await.
  private var attemptTask: Task<Void, Never>?
  private var stopped = false

  init(overlay: any OverlayPresenting, inputs: Inputs) {
    self.overlay = overlay
    self.inputs = inputs
  }

  /// Watches every runtime's notice; a new one tries at once.
  func start() {
    observeNotices()
    attempt()
  }

  func stop() { stopped = true }

  /// Setup finished, or something else freed the overlay: try now.
  func attempt() {
    guard !stopped, inFlight == nil, inputs.setupComplete(),
      let (source, notice) = currentNotice()
    else { return }
    inFlight = notice.id
    attemptTask = Task { [weak self] in await self?.present(notice, from: source) }
  }

  /// Tests: waits for the latest attempt's check and overlay request.
  func awaitAttemptForTesting() async { await attemptTask?.value }

  private func currentNotice() -> (any PolishDownloadNoticeSource, PolishDownloadNotice)? {
    for source in inputs.sources() {
      if let notice = source.pendingDownloadNotice { return (source, notice) }
    }
    return nil
  }

  private func present(_ notice: PolishDownloadNotice, from source: any PolishDownloadNoticeSource)
    async
  {
    let current = await source.isCurrent(notice)
    // Read again after the hop: Setup, the notice, the runtime's facts and admission.
    guard !stopped, current, stillWanted(notice, from: source) else {
      inFlight = nil
      inputs.log("pill not requested yet: the notice is not current now")
      // Kept while it is pending: a release of the server, a new notice or the timer tries again.
      scheduleRetry()
      attemptNewerNotice(than: notice)
      return
    }
    var settled = false
    overlay.present(
      .polishDownloadComplete(
        PolishDownloadPillModel(modelName: inputs.modelName(notice.model)),
        isStillWanted: { [weak self, weak source] in
          guard let self, let source else { return false }
          return self.stillWanted(notice, from: source)
        }),
      onResult: { [weak self, weak source] result in
        guard !settled else { return }
        settled = true
        self?.settle(result, notice: notice, source: source)
      })
  }

  /// Every synchronous fact, read by the request and again by the director just before the first
  /// render: Setup complete, still this notice, the runtime's live server with its passed verdict,
  /// the coordinator's dictation admission open, and no summary holding the server.
  private func stillWanted(
    _ notice: PolishDownloadNotice, from source: any PolishDownloadNoticeSource
  ) -> Bool {
    !stopped && inputs.setupComplete() && source.pendingDownloadNotice == notice
      && source.isLive(notice) && !inputs.summaryHoldsServer()
  }

  /// A newer notice that arrived while an attempt was busy is considered once it settles.
  private func attemptNewerNotice(than notice: PolishDownloadNotice) {
    guard let (_, next) = currentNotice(), next != notice else { return }
    attempt()
  }

  private func settle(
    _ result: PillPresentationResult, notice: PolishDownloadNotice,
    source: (any PolishDownloadNoticeSource)?
  ) {
    inFlight = nil
    guard case .presented = result else {
      inputs.log("pill not shown; the notice is kept")
      scheduleRetry()
      attemptNewerNotice(than: notice)
      return
    }
    source?.acknowledgeDownloadNotice(notice.id)
    inputs.log("pill shown")
    attemptNewerNotice(than: notice)
  }

  /// One retry at a time, only while a notice is still waiting.
  private func scheduleRetry() {
    guard !stopped, !retryScheduled, currentNotice() != nil else { return }
    retryScheduled = true
    inputs.schedule(Self.retryDelay) { [weak self] in
      guard let self else { return }
      self.retryScheduled = false
      self.attempt()
    }
  }

  /// Re-arming observation over every runtime's `pendingDownloadNotice` and
  /// `sharedServerReleases` (the runtimes are `@Observable`): a new notice, or the server becoming
  /// free again with the same notice, tries again.
  private func observeNotices() {
    guard !stopped else { return }
    withObservationTracking {
      for source in inputs.sources() {
        _ = source.pendingDownloadNotice
        _ = source.sharedServerReleases
      }
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, !self.stopped else { return }
        self.observeNotices()
        self.attempt()
      }
    }
  }

  static func appLog(_ message: String) {
    Task {
      await AppLogger.shared.log(
        "AI polish download pill: \(message)", level: .info, category: "LLM")
    }
  }

  /// Production scheduling: a main-actor task that sleeps.
  static let mainActorSchedule: @MainActor (Duration, @escaping @MainActor () -> Void) -> Void = {
    delay, work in
    Task { @MainActor in
      try? await Task.sleep(for: delay)
      work()
    }
  }
}
