import EnviousWisprCore
import EnviousWisprPostProcessing
import Foundation

/// Background bulk-import-enrichment producer (#1701), sibling of
/// `ContactsImportCoordinator`. Shares `WordSuggestionService`'s permit lane
/// via the injected `AliasSuggesting` seam. Limb, not heart: depends only on
/// `CustomWordsCoordinator` and an injected `any AliasSuggesting`. The
/// durable queue is always a fresh scan of `enrichmentPending`, never an
/// in-memory list — a fresh or second app instance (#1747) re-scans it.
@MainActor
final class BulkImportEnrichmentCoordinator {
  private let customWords: CustomWordsCoordinator
  private let aliasSuggester: any AliasSuggesting
  /// Narrow closure into the transient-pill mechanism (`di-narrow-homes`).
  private let presentStatus: (String) -> Void
  /// Cancellable timing seam for bounded `.libraryBusy` recovery (#1701).
  /// Tests substitute a signal-recording stub, never wall-clock time.
  private let retrySleep: @Sendable (Duration) async throws -> Void

  private var drainTask: Task<Void, Never>?
  /// A superseded task whose generation no longer matches must not act.
  private var generation = 0
  /// Single-flight wake: never a lost mid-drain request, never a second walker.
  private var drainRequestedAgain = false
  /// Checked only BEFORE the next word; in-flight always finishes and checkpoints.
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
  /// Same shipped 1/2/4s schedule as `ManifestFetchTask`, not a new timing invention.
  private static let busyRetryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]

  /// `.retryable` (transient `.libraryBusy`) retries silently until
  /// exhausted. `.failed` hard-stops regardless of `drainRequestedAgain`.
  private enum DrainPassOutcome { case completedNormally, retryable, failed }
  private enum DrainStatus: String { case checkpoint, completed, cancelled, failed }

  init(
    customWords: CustomWordsCoordinator,
    aliasSuggester: any AliasSuggesting,
    presentStatus: @escaping (String) -> Void,
    retrySleep: @escaping @Sendable (Duration) async throws -> Void = {
      try await Task.sleep(for: $0)
    }
  ) {
    self.customWords = customWords
    self.aliasSuggester = aliasSuggester
    self.presentStatus = presentStatus
    self.retrySleep = retrySleep
  }

  /// Wake the drain — called at launch and after every nonempty import
  /// commit. Single-flight. Never gated on `isAvailable`: `suggestAliases`
  /// resolves to `nil` safely when unavailable, an honest "tried, got nothing".
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

  /// Never hard-cancels an in-flight call; the sweep runs once the loop exits.
  func cancel() {
    guard drainTask != nil else {
      performCancelSweep()
      return
    }
    cancelRequested = true
  }

  private func runDrainLoop(generation gen: Int) async {
    // Attempt index is local to this pass, never stored session state — a
    // fresh `requestDrain()` gets a fresh retry budget; success resets it.
    outer: repeat {
      drainRequestedAgain = false
      for attempt in 0...Self.busyRetryDelays.count {
        switch await drainOnce(generation: gen) {
        case .completedNormally: break
        case .failed: break outer
        case .retryable:
          guard attempt < Self.busyRetryDelays.count else {
            // Exhausted: same one `.failed` log a permanent failure gets,
            // then hard-stop — pending flags and the total stay intact for a
            // later explicit wake to resume this same lingering session.
            logCheckpoint(status: .failed)
            break outer
          }
          try? await retrySleep(Self.busyRetryDelays[attempt])
          continue
        }
        break
      }
    } while drainRequestedAgain && gen == generation && !cancelRequested
    guard gen == generation else { return }  // superseded — a newer generation owns cleanup
    drainTask = nil
    if cancelRequested {
      performCancelSweep()
      cancelRequested = false
    }
  }

  /// Transient `.libraryBusy` retries the same pass; everything else
  /// (unreadable/corrupted files, coordination, ordinary write failures) is
  /// an immediate hard stop, logged once here.
  private func drainFailure(_ error: Error) -> DrainPassOutcome {
    if error as? CustomWordsPersistenceError == .libraryBusy { return .retryable }
    logCheckpoint(status: .failed)
    return .failed
  }

  private func drainOnce(generation gen: Int) async -> DrainPassOutcome {
    do {
      try customWords.repairPendingEnrichmentTotalIfNeeded()
    } catch {
      return drainFailure(error)
    }
    guard let pending = customWords.pendingEnrichmentWords() else {
      logCheckpoint(status: .failed)
      return .failed
    }
    guard !pending.isEmpty else {
      // An unfinalized prior pass must finalize now, or it blocks the pill.
      finalizeLingeringSessionIfNeeded()
      return .completedNormally
    }
    guard !cancelRequested else { return .completedNormally }  // no pill on a pre-start cancel
    if !didAnnounceStart {
      presentStatus(Self.startMessage)
      didAnnounceStart = true
    }

    var buffer: [CustomWordEnrichmentResult] = []

    // Never retains a stale buffer across a retry: a busy checkpoint
    // propagates out of `drainOnce`; the next attempt starts fresh.
    func flush() throws {
      guard !buffer.isEmpty else { return }
      defer { buffer.removeAll(keepingCapacity: true) }
      try customWords.applyEnrichmentResults(buffer)
    }

    for word in pending {
      guard gen == generation, !cancelRequested else { break }
      // `word` from this pass's ONE initial scan, never a per-word re-read —
      // the checkpoint's own pending-gate makes a stale word a safe no-op.
      let raw: [String]?
      if word.category == .general {
        // Never a confirmed classification, only the type default — classify
        // first rather than force-feeding the general-word prompt.
        raw = await aliasSuggester.suggestAliases(for: word.canonical, priority: .background)
      } else {
        raw = await aliasSuggester.suggestAliases(
          for: word.canonical, category: word.category, priority: .background)
      }

      // Always recorded, even if `cancelRequested` flipped mid-call — only
      // the loop guard above, checked before the NEXT call, stops work.
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
        do {
          try flush()
        } catch {
          return drainFailure(error)
        }
        logCheckpoint(status: .checkpoint)
      }
    }

    do {
      try flush()
    } catch {
      return drainFailure(error)
    }

    // A FAILED final read is its own terminal outcome, not "still not empty".
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
    // A failed write is never logged as a clean cancel.
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
