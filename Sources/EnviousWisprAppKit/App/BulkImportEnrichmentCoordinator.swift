import EnviousWisprCore
import EnviousWisprPostProcessing
import Foundation

/// Background bulk-import-enrichment producer (#1701 Chunk 2), sibling of
/// `ContactsImportCoordinator`. Shares `WordSuggestionService`'s permit lane
/// via the injected `AliasSuggesting` seam. Limb, not heart: depends only on
/// `CustomWordsCoordinator` and an injected `any AliasSuggesting`. The
/// durable queue is always a fresh scan of `enrichmentPending`, never an
/// in-memory job list — a fresh instance, or a second app instance (#1747),
/// finds the same work by re-scanning.
@MainActor
final class BulkImportEnrichmentCoordinator {
  private let customWords: CustomWordsCoordinator
  private let aliasSuggester: any AliasSuggesting
  /// Narrow closure into the transient-pill mechanism (`di-narrow-homes`).
  private let presentStatus: (String) -> Void

  private var drainTask: Task<Void, Never>?
  /// A superseded task whose generation no longer matches must not act.
  private var generation = 0
  /// Single-flight wake: consumed by the loop so a mid-drain request is
  /// never lost, never a second concurrent walker.
  private var drainRequestedAgain = false
  /// Checked only BEFORE starting the next word's call; in-flight always
  /// finishes and checkpoints normally.
  private var cancelRequested = false
  /// Whether the "started" pill has fired for the CURRENT session.
  private var didAnnounceStart = false
  /// Local `AppLogger` diagnostics only; reset at every terminal boundary.
  private var succeededWithAliases = 0
  private var attemptedWithNothingUseful = 0
  private var timedOutOrUnavailable = 0
  private var processedThisSession = 0

  private static let checkpointChunkSize = 25
  private static let startMessage =
    "Importing your words now. Check progress in the Your Words menu."
  private static let finishMessage = "Finished importing your words."

  /// `.failed` hard-stops the loop regardless of `drainRequestedAgain` —
  /// never retry a broken repair/read/write in a tight loop.
  private enum DrainPassOutcome { case completedNormally, failed }
  private enum DrainStatus: String { case checkpoint, completed, cancelled, failed }

  init(
    customWords: CustomWordsCoordinator,
    aliasSuggester: any AliasSuggesting,
    presentStatus: @escaping (String) -> Void
  ) {
    self.customWords = customWords
    self.aliasSuggester = aliasSuggester
    self.presentStatus = presentStatus
  }

  /// Wake the drain — called at launch and after every nonempty import
  /// commit. Single-flight. Never gated on `isAvailable`: `suggestAliases`
  /// resolves to `nil` safely when unavailable, an honest "tried, got
  /// nothing" (D16 fail-open).
  func requestDrain() {
    guard drainTask == nil else {
      drainRequestedAgain = true
      return
    }
    generation += 1
    let gen = generation
    cancelRequested = false
    drainTask = Task { [weak self] in
      await self?.runDrainLoop(generation: gen)
    }
  }

  // periphery:ignore - test seam
  /// Deterministically waits for the whole loop, called right after
  /// `requestDrain()` assigns `drainTask` synchronously.
  func awaitDrainForTesting() async {
    await drainTask?.value
  }

  /// Never hard-cancels an in-flight call; the sweep runs only once the loop
  /// observes this and exits.
  func cancel() {
    guard drainTask != nil else {
      performCancelSweep()
      return
    }
    cancelRequested = true
  }

  private func runDrainLoop(generation gen: Int) async {
    repeat {
      drainRequestedAgain = false
      if case .failed = await drainOnce(generation: gen) { break }
    } while drainRequestedAgain && gen == generation && !cancelRequested
    guard gen == generation else { return }  // superseded — a newer generation owns cleanup
    drainTask = nil
    if cancelRequested {
      performCancelSweep()
      cancelRequested = false
    }
  }

  private func drainOnce(generation gen: Int) async -> DrainPassOutcome {
    customWords.repairPendingEnrichmentTotalIfNeeded()
    if customWords.customWordError != nil {
      logCheckpoint(status: .failed)
      return .failed
    }
    guard let pending = customWords.pendingEnrichmentWords() else {
      logCheckpoint(status: .failed)
      return .failed
    }
    guard !pending.isEmpty else {
      // An unfinalized prior pass (its final scan failed after checkpointing
      // everything) must finalize now, or it blocks the next session's pill.
      finalizeLingeringSessionIfNeeded()
      return .completedNormally
    }
    guard !cancelRequested else { return .completedNormally }  // no pill on a pre-start cancel
    if !didAnnounceStart {
      presentStatus(Self.startMessage)
      didAnnounceStart = true
    }

    var buffer: [CustomWordEnrichmentResult] = []

    @discardableResult
    func flush() -> Bool {
      guard !buffer.isEmpty else { return true }
      let error = customWords.applyEnrichmentResults(buffer)
      buffer.removeAll(keepingCapacity: true)
      return error == nil
    }

    for word in pending {
      guard gen == generation, !cancelRequested else { break }
      // `word` from this pass's ONE initial scan, never a per-word re-read
      // (an O(n²) main-thread path) — the checkpoint's own pending-gate
      // already makes a stale word a safe no-op.
      let raw = await aliasSuggester.suggestAliases(
        for: word.canonical, category: word.category, priority: .background)

      // Always recorded, even if `cancelRequested` flipped true mid-call —
      // "allow it to finish and checkpoint normally." Only the loop guard
      // above, checked before STARTING the next call, stops further work.
      processedThisSession += 1
      if let raw, !raw.isEmpty {
        succeededWithAliases += 1
      } else if raw == nil {
        timedOutOrUnavailable += 1
      } else {
        attemptedWithNothingUseful += 1
      }
      buffer.append(CustomWordEnrichmentResult(id: word.id, generatedAliases: raw ?? []))

      if buffer.count >= Self.checkpointChunkSize {
        guard flush() else {
          logCheckpoint(status: .failed)
          return .failed
        }
        logCheckpoint(status: .checkpoint)
      }
    }

    guard flush() else {
      logCheckpoint(status: .failed)
      return .failed
    }

    // A FAILED final read is its own terminal outcome, never folded into
    // "read fine, still not empty."
    guard let stillPendingAfter = customWords.pendingEnrichmentWords() else {
      logCheckpoint(status: .failed)
      return .failed
    }
    if gen == generation, !cancelRequested, stillPendingAfter.isEmpty {
      finalizeLingeringSessionIfNeeded()
    } else {
      logCheckpoint(status: .checkpoint)
    }
    return .completedNormally
  }

  private func finalizeLingeringSessionIfNeeded() {
    guard didAnnounceStart || processedThisSession > 0 else { return }
    logCheckpoint(status: .completed)
    presentStatus(Self.finishMessage)
    didAnnounceStart = false
    resetSessionCounters()
  }

  private func performCancelSweep() {
    // Report .cancelled and reset state ONLY once the sweep succeeds — a
    // failed write is never logged as a clean cancel.
    guard customWords.cancelEnrichment() == nil else {
      logCheckpoint(status: .failed)
      return
    }
    didAnnounceStart = false
    logCheckpoint(status: .cancelled)
    resetSessionCounters()
  }

  private func resetSessionCounters() {
    succeededWithAliases = 0
    attemptedWithNothingUseful = 0
    timedOutOrUnavailable = 0
    processedThisSession = 0
  }

  private func logCheckpoint(status: DrainStatus) {
    let succeeded = succeededWithAliases
    let nothingUseful = attemptedWithNothingUseful
    let timedOut = timedOutOrUnavailable
    let processed = processedThisSession
    Task {
      await AppLogger.shared.log(
        "\(status.rawValue): succeeded=\(succeeded) nothingUseful=\(nothingUseful) "
          + "timedOutOrUnavailable=\(timedOut) processedThisSession=\(processed)",
        level: .info, category: "CustomWordsEnrichment"
      )
    }
  }
}
