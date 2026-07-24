import EnviousWisprCore
import EnviousWisprPostProcessing
import Foundation
import Observation

/// The progress card's word-transform display (#1701 Chunk 2): the most
/// recently checkpointed word plus its freshly generated aliases. The
/// checkpoint batch itself never carries canonical text (only id +
/// generatedAliases, keeping persistence minimal) — `CustomWordsCoordinator`
/// synthesizes this by matching the batch's last result against the
/// just-reloaded snapshot, which does have it.
struct CustomWordEnrichmentDisplay: Sendable, Equatable {
  let canonical: String
  let generatedAliases: [String]
}

/// Manages custom word state, CRUD operations, and persistence.
@MainActor @Observable
final class CustomWordsCoordinator {
  var customWords: [CustomWord] = []
  var customWordError: String?
  /// Set when the launch-time load failed (#1646) so Your Words can show an
  /// honest banner instead of a silent empty list. `.unreadable`: the file is
  /// intact, nothing was changed. `.corrupted`: it was archived for recovery.
  private(set) var wordsLoadFailureAtLaunch: CustomWordsInitialLoadFailure?
  /// Set when a load DURING the session found the file corrupt and archived it
  /// aside. Separate from the launch flag because corruption does not only
  /// happen at startup, and the archive makes the next read look clean.
  private(set) var didDiscoverCorruptionThisSession = false
  /// Durable bulk-import-enrichment total (#1701 Chunk 2) — the progress
  /// card's denominator. `nil` = no run in progress. Initialized alongside
  /// `customWords` from ONE `loadSnapshot()` call, never loaded separately,
  /// so the two can never disagree; every checkpoint/Cancel wrapper below
  /// atomically adopts both together too.
  private(set) var pendingEnrichmentBatchTotal: Int?
  /// Progress card's word-transform display (#1701 Chunk 2). Best-effort:
  /// set from the last APPLIED result in each checkpoint batch (never the
  /// caller's raw input, which can include results that were skipped,
  /// sanitized away, or lost first-terminal-action-wins — Codex Chunk 2
  /// review finding 6), cleared on Cancel and at the start of a genuinely new
  /// run. Purely a delight/progress cue, never load-bearing for correctness.
  private(set) var mostRecentEnrichment: CustomWordEnrichmentDisplay?

  /// Live in-memory pending count (#1701 Chunk 2, Codex Chunk 2 review
  /// finding 5) — the load-bearing signal for "is a background enrichment
  /// run in progress," derived from the already-observable `customWords`.
  /// NEVER touches disk: safe to read from a SwiftUI `body` on every render,
  /// unlike `pendingEnrichmentWords()` (a real locked file read). Progress
  /// card / sidebar badge visibility and the progress numerator both read
  /// this, never `pendingEnrichmentBatchTotal`'s mere presence — the total
  /// can theoretically lag behind live state during the brief self-heal
  /// window `repairPendingEnrichmentTotalIfNeeded` exists for.
  var pendingEnrichmentCount: Int {
    customWords.reduce(into: 0) { if $1.enrichmentPending { $0 += 1 } }
  }

  let suggestionService = WordSuggestionService()
  /// The reused on-device alias generator, exposed as the narrow protocol so the
  /// composition root can wire it into the contacts-import coordinator without
  /// naming a PostProcessing type (keeps the root's import surface minimal).
  var aliasSuggester: any AliasSuggesting { suggestionService }

  /// Called after any mutation so the former root state can sync words to pipelines.
  var onWordsChanged: (([CustomWord]) -> Void)?
  /// Fires after a successful, NONEMPTY import commit (#1701 Chunk 2) —
  /// additive alongside `onWordsChanged`, never instead of it; never fires
  /// for an empty/all-Skip, stale, or failed commit. `WisprBootstrapper`
  /// wires this to `BulkImportEnrichmentCoordinator.requestDrain()` so a
  /// commit that lands while the coordinator is idle wakes it, and one that
  /// lands mid-drain still reaches it (no lost wakeup).
  var onImportCommitted: (@MainActor () -> Void)?
  /// Routes Your Words' progress-card Cancel action to
  /// `BulkImportEnrichmentCoordinator.cancel()` (#1701 Chunk 2) — a narrow
  /// closure rather than injecting that coordinator into the SwiftUI
  /// environment, since this is the only interaction the view needs with it.
  var cancelBulkImportEnrichment: (@MainActor () -> Void)?

  private let manager: CustomWordsManager

  init() {
    self.manager = CustomWordsManager()
    let snapshot = manager.loadSnapshot()
    customWords = snapshot?.words ?? []
    pendingEnrichmentBatchTotal = snapshot?.pendingEnrichmentBatchTotal
    wordsLoadFailureAtLaunch = manager.lastLoadFailure
  }

  /// Test seam (#636): inject a temp-file-backed manager so hermetic tests of
  /// the contacts-import flow never touch the production custom-words file.
  // periphery:ignore - test seam
  package init(manager: CustomWordsManager) {
    self.manager = manager
    let snapshot = manager.loadSnapshot()
    customWords = snapshot?.words ?? []
    pendingEnrichmentBatchTotal = snapshot?.pendingEnrichmentBatchTotal
    wordsLoadFailureAtLaunch = manager.lastLoadFailure
  }

  @discardableResult
  func add(_ word: CustomWord) -> String? {
    do {
      try manager.add(word: word, to: &customWords)
      onWordsChanged?(customWords)
      customWordError = nil
      return nil
    } catch {
      return note(error)
    }
  }

  /// Outcome of a reviewed Custom Words import (#1665). `.stale` is not a
  /// failure the user caused — the list changed while Review was open, so the
  /// sheet re-compares against the current list instead of writing.
  enum CustomWordsImportCommitOutcome: Sendable, Equatable {
    case committed(CustomWordsImportCommitReceipt)
    case stale
    case failed(message: String)
  }

  /// Re-read the saved words from disk and adopt them, reporting whether the
  /// list can now be trusted.
  ///
  /// One owner for "reload and adopt", used by both callers that need it: the
  /// stale-commit path (#1679) and the export guard (#1680). Reading without
  /// adopting is the trap — a readability check that discards what it read
  /// leaves the caller believing the list is good while it still holds the
  /// empty launch fallback, which is how export came to overwrite a real
  /// backup with an empty file (cloud review, #1682).
  ///
  /// Fails closed: an unreadable file returns `false` and leaves the current
  /// list untouched rather than substituting an empty one.
  /// Record a failure, latching corruption whichever operation discovered it.
  ///
  /// Corruption has SEVERAL discoverers, not one (cloud review): any mutation
  /// can hit it first, and `loadFileForMutation` archives the damaged file and
  /// throws without touching the launch flag. The next read then sees a
  /// legitimately missing file and looks perfectly healthy — so export would
  /// write an empty file over the user's real one while their words sat in
  /// the archive. Routing every failure through one place means a future
  /// mutation cannot forget to say so.
  private func note(_ error: Error) -> String {
    if let persistence = error as? CustomWordsPersistenceError,
      persistence == .corruptedExistingFile
    {
      didDiscoverCorruptionThisSession = true
    }
    customWordError = error.localizedDescription
    return error.localizedDescription
  }

  @discardableResult
  func refreshFromDiskIfPossible() -> Bool {
    // `loadSnapshot()`, never `load()` alone (Codex Chunk 2 review round 2
    // finding 4): words and `pendingEnrichmentBatchTotal` must adopt together
    // here too, the same atomic-pair guarantee every other read/write path
    // already honors — otherwise a stale-commit refresh after another app
    // instance wrote can leave the total pointing at a run that no longer
    // matches the just-refreshed words.
    guard let snapshot = manager.loadSnapshot() else {
      // Corruption found DURING the session, not at launch, is still
      // corruption — and it must be remembered (code review r3). The load
      // archives the damaged file aside, so the NEXT attempt sees a
      // legitimately missing file, adopts the built-ins, and reports success.
      // Without latching this, a retry would sail past the export guard, find
      // zero user words, and write an empty file over the user's existing one.
      if manager.lastLoadFailure == .corrupted {
        didDiscoverCorruptionThisSession = true
      }
      return false
    }
    // Codex Chunk 2 review round 3 finding 3: words and total adopt
    // together, but `onWordsChanged` fires ONLY when words actually
    // changed — a total-only change (another instance's run starting or
    // ending) must not republish unchanged words to pipelines. The same
    // nil -> non-nil new-run detection `commitImport` uses clears a stale
    // display here too, since another instance's fresh run is exactly as
    // "new" as a local one.
    let wordsChanged = snapshot.words != customWords
    let isNewRun = pendingEnrichmentBatchTotal == nil && snapshot.pendingEnrichmentBatchTotal != nil
    if wordsChanged || snapshot.pendingEnrichmentBatchTotal != pendingEnrichmentBatchTotal {
      customWords = snapshot.words
      pendingEnrichmentBatchTotal = snapshot.pendingEnrichmentBatchTotal
      if isNewRun { mostRecentEnrichment = nil }
      if wordsChanged { onWordsChanged?(customWords) }
    }

    // NOTE: the corrupted-library refusal deliberately does NOT live here.
    // An earlier version put it inside this reload and that re-created the
    // stale-import loop it was meant to prevent: the import path stopped
    // adopting the current library, so every re-comparison saw the same old
    // list and Confirm could never succeed. This method answers "can I read
    // it", and must always adopt what it reads; `canExportCurrentWords`
    // answers "is it safe to write out". Two questions, two answers.
    //
    // A rebase reintroduced the old inline refusal alongside the new one, and
    // the export test caught the contradiction immediately.
    return true
  }

  /// Whether the current list is a safe thing to WRITE OUT (cloud review, #1682).
  ///
  /// A corrupted file is ARCHIVED aside, so a reload afterwards sees a
  /// legitimately missing file and reports a clean, empty library. Exporting
  /// then would write an empty file over the one the user picked while their
  /// real words sit in the archive — destroying the copy they still had.
  ///
  /// Deliberately separate from `refreshFromDiskIfPossible`, which answers
  /// "can I read the library" and must always adopt what it reads. Once the
  /// user has authored a word since, they have visibly accepted the fresh
  /// start and the list is theirs again.
  var canExportCurrentWords: Bool {
    // Either origin of corruption counts: at launch, or discovered mid-session
    // (code review r3). Checking only the launch flag meant a file that went
    // bad while the app was open passed the guard on the second attempt and
    // exported nothing over something.
    let sawCorruption =
      wordsLoadFailureAtLaunch == .corrupted || didDiscoverCorruptionThisSession
    guard sawCorruption else { return true }
    return customWords.contains { $0.source == .user }
  }

  /// Apply a reviewed import in one atomic write. Fires `onWordsChanged`
  /// exactly once, and only when something actually changed; `onImportCommitted`
  /// fires alongside it, under the identical `!plan.isEmpty` gate (#1701
  /// Chunk 2) — an all-Skip commit touches neither `customWords` nor
  /// `pendingEnrichmentBatchTotal`, matching `manager.commitImport`'s own
  /// "writes nothing, changes no total" contract for that case.
  func commitImport(_ plan: CustomWordsImportCommitPlan) -> CustomWordsImportCommitOutcome {
    do {
      let receipt = try manager.commitImport(plan, to: &customWords)
      if !plan.isEmpty {
        // A genuinely NEW run starting (nil -> non-nil) clears any stale
        // display left over from a previous, already-completed run — an
        // EXTENDING commit (a run already active) must not reset it, since
        // that would flicker away a display mid-drain (Codex Chunk 2 review
        // finding 6).
        let isNewRun =
          pendingEnrichmentBatchTotal == nil && receipt.pendingEnrichmentBatchTotal != nil
        pendingEnrichmentBatchTotal = receipt.pendingEnrichmentBatchTotal
        if isNewRun { mostRecentEnrichment = nil }
        onWordsChanged?(customWords)
        onImportCommitted?()
      }
      customWordError = nil
      return .committed(receipt)
    } catch CustomWordsImportCommitError.staleLibrary {
      // Stale means the on-disk list no longer matches what Review was built
      // from, and the commit threw WITHOUT touching `customWords` — so the
      // in-memory list is exactly the stale copy that caused this. Refresh it
      // from disk before returning, or the sheet rebuilds its comparison from
      // the same stale data, produces identical rows, and fails stale again on
      // the next confirm: a loop the user cannot escape (cloud review, #1679).
      //
      // Fail closed on an unreadable file: keep the current list rather than
      // clobbering it with an empty one. The commit still reports `.stale`,
      // which is honest either way — nothing was written.
      refreshFromDiskIfPossible()
      customWordError = nil
      return .stale
    } catch {
      return .failed(message: note(error))
    }
  }

  /// Bulk-add for the contacts import (#636). Returns the IDs actually created
  /// (for the import log), or nil on failure (check `customWordError`).
  func addBatch(_ words: [CustomWord]) -> [UUID]? {
    do {
      let created = try manager.addBatch(words, to: &customWords)
      onWordsChanged?(customWords)
      customWordError = nil
      return created
    } catch {
      _ = note(error)
      return nil
    }
  }

  @discardableResult
  func remove(id: UUID) -> String? {
    do {
      try manager.remove(id: id, from: &customWords)
      onWordsChanged?(customWords)
      customWordError = nil
      return nil
    } catch {
      return note(error)
    }
  }

  /// Bulk-remove by ID (contacts-import pill, #636).
  @discardableResult
  func removeBatch(ids: [UUID]) -> String? {
    do {
      try manager.removeBatch(ids: ids, from: &customWords)
      onWordsChanged?(customWords)
      customWordError = nil
      return nil
    } catch {
      return note(error)
    }
  }

  @discardableResult
  func update(_ word: CustomWord) -> String? {
    do {
      try manager.update(word: word, in: &customWords)
      onWordsChanged?(customWords)
      customWordError = nil
      return nil
    } catch {
      return note(error)
    }
  }

  /// Bulk-update existing words (contacts-import alias enrichment, #636
  /// follow-up). One `onWordsChanged` for the whole batch so the corrector
  /// rebuilds once per flush, not once per word.
  @discardableResult
  func updateBatch(_ words: [CustomWord]) -> String? {
    do {
      try manager.updateBatch(words, to: &customWords)
      onWordsChanged?(customWords)
      customWordError = nil
      return nil
    } catch {
      return note(error)
    }
  }

  // MARK: - Bulk-import enrichment (#1701 Chunk 2)
  //
  // `BulkImportEnrichmentCoordinator` never reaches through to
  // `CustomWordsManager` directly — this is the sole AppKit adapter, exactly
  // as it already is for every other Custom Words mutation.

  #if DEBUG
    // periphery:ignore - test seam
    /// Forces the Nth call to `pendingEnrichmentWords()` this session to
    /// return `nil` (a read failure), letting a test deterministically target
    /// ONE specific call — e.g. the drain loop's final re-scan specifically,
    /// distinct from its earlier, successful initial scan — without racing
    /// real file-system timing. Both calls in one drain pass are fully
    /// synchronous with no suspension point between them, so no external task
    /// could otherwise intervene between "checkpoint succeeded" and "the
    /// following scan failed."
    var forcePendingEnrichmentWordsFailureOnCallForTesting: Int?
    private var pendingEnrichmentWordsCallCountForTesting = 0
  #endif

  /// Word list filtered to `enrichmentPending == true` — the durable queue
  /// itself is this scan over live state, never an in-memory job list. `nil`
  /// only on the same unrecoverable read failure `customWords` itself would
  /// report via `customWordError`.
  func pendingEnrichmentWords() -> [CustomWord]? {
    #if DEBUG
      pendingEnrichmentWordsCallCountForTesting += 1
      if forcePendingEnrichmentWordsFailureOnCallForTesting
        == pendingEnrichmentWordsCallCountForTesting
      {
        return nil
      }
    #endif
    return manager.loadPendingEnrichmentWords()
  }

  /// One-time self-heal: repairs a `nil` durable total to the current live
  /// pending count when pending words exist but no total does. Adopts the
  /// (possibly just-repaired) total either way. Called by the background
  /// coordinator before it begins draining.
  @discardableResult
  func repairPendingEnrichmentTotalIfNeeded() -> Int? {
    do {
      let total = try manager.repairPendingEnrichmentTotalIfNeeded()
      pendingEnrichmentBatchTotal = total
      customWordError = nil
      return total
    } catch {
      _ = note(error)
      return pendingEnrichmentBatchTotal
    }
  }

  /// Merge-safe, pending-gated checkpoint. Atomically adopts both the
  /// returned words and the returned total before notifying observers — never
  /// one without the other. Fires `onWordsChanged` only when something in
  /// this batch actually still needed applying (first-terminal-action-wins:
  /// a checkpoint that only contains already-resolved IDs is a no-op).
  @discardableResult
  func applyEnrichmentResults(_ results: [CustomWordEnrichmentResult]) -> String? {
    do {
      let outcome = try manager.applyEnrichmentResults(results)
      let snapshot = outcome.snapshot
      let changed =
        snapshot.words != customWords
        || snapshot.pendingEnrichmentBatchTotal != pendingEnrichmentBatchTotal
      customWords = snapshot.words
      pendingEnrichmentBatchTotal = snapshot.pendingEnrichmentBatchTotal
      // Only a result that actually applied non-empty aliases — never the
      // caller's raw input, which can include skipped/sanitized/collided
      // results (Codex Chunk 2 review finding 6).
      if let lastApplied = outcome.applied.last(where: { !$0.generatedAliases.isEmpty }),
        let word = snapshot.words.first(where: { $0.id == lastApplied.id })
      {
        mostRecentEnrichment = CustomWordEnrichmentDisplay(
          canonical: word.canonical, generatedAliases: lastApplied.generatedAliases)
      }
      customWordError = nil
      if changed { onWordsChanged?(customWords) }
      return nil
    } catch {
      return note(error)
    }
  }

  /// Durable Cancel: one locked reload-and-sweep, under the manager's own
  /// lock, clearing every word CURRENTLY pending — never this coordinator's
  /// potentially-stale in-memory idea of what was pending — and the durable
  /// total. Atomically adopts both before notifying observers.
  @discardableResult
  func cancelEnrichment() -> String? {
    do {
      let snapshot = try manager.cancelEnrichment()
      let changed =
        snapshot.words != customWords
        || snapshot.pendingEnrichmentBatchTotal != pendingEnrichmentBatchTotal
      customWords = snapshot.words
      pendingEnrichmentBatchTotal = snapshot.pendingEnrichmentBatchTotal
      mostRecentEnrichment = nil
      customWordError = nil
      if changed { onWordsChanged?(customWords) }
      return nil
    } catch {
      return note(error)
    }
  }
}
