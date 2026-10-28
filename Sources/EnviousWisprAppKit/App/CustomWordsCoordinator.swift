import EnviousWisprCore
import EnviousWisprPostProcessing
import EnviousWisprServices
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
  var customWords: [CustomWord] = [] {
    didSet { customWordsRevision &+= 1 }
  }
  /// Bumped on every write to `customWords`, including in-place `inout` mutation
  /// (#4086). The Your Words list keys its prepared result on this instead of
  /// comparing the whole word array on every read.
  private(set) var customWordsRevision = 0
  var customWordError: String?
  /// Optional per-instance timing sink; ordinary application wiring leaves it nil.
  package var probe: CustomWordsProbe?
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
  /// #3975: a user "no" the learning memory committed, for
  /// `learn_refused_by_user`. `LearnFromEditsWiring` sets it to its telemetry sink.
  var onLearnRefusedByUser:
    (
      @MainActor (
        TelemetryService.LearnFromEditsTelemetry.RefusalSource,
        TelemetryService.LearnFromEditsTelemetry.UndoMemory
      ) -> Void
    )?

  private let manager: CustomWordsManager
  /// The one per-pair learning memory (#3975), beside the dictionary file.
  /// The learn wiring reads it from here so every user "no" lands in one store.
  let learnMemory: LearnMemory

  init() {
    self.manager = CustomWordsManager()
    self.learnMemory = LearnMemory(
      fileURL: manager.learnMemoryURL, report: LearnMemoryDiagnostics.forward)
    let snapshot = manager.loadSnapshot()
    observeLearnMemory()
    customWords = snapshot?.words ?? []
    pendingEnrichmentBatchTotal = snapshot?.pendingEnrichmentBatchTotal
    wordsLoadFailureAtLaunch = manager.lastLoadFailure
    admitUsageFlushes()
  }

  /// Test seam (#636): inject a temp-file-backed manager so hermetic tests of
  /// the contacts-import flow never touch the production custom-words file.
  // periphery:ignore - test seam
  package init(manager: CustomWordsManager) {
    self.manager = manager
    self.learnMemory = LearnMemory(
      fileURL: manager.learnMemoryURL, report: LearnMemoryDiagnostics.forward)
    let snapshot = manager.loadSnapshot()
    observeLearnMemory()
    customWords = snapshot?.words ?? []
    pendingEnrichmentBatchTotal = snapshot?.pendingEnrichmentBatchTotal
    wordsLoadFailureAtLaunch = manager.lastLoadFailure
    admitUsageFlushes()
  }

  // MARK: - Command queue (#4086)

  /// Usage counts are a dictionary change like any other (#4086): their flush queues as a
  /// command and Quit waits for it.
  private func admitUsageFlushes() {
    manager.admitUsageFlush = { [weak self] write in
      guard let self else { return false }
      return await command(.usageFlush, closing: false) { _ in
        await write()
        return true
      }
    }
  }

  /// Every dictionary command runs through this FIFO, one at a time, in the order it was
  /// asked for. A command covers its whole action: storage on the manager's file worker,
  /// adopting the saved library, telling consumers, and any learning-memory effect. The
  /// next command starts only after that, so it always prepares against the library the
  /// previous one left. Mechanism and reasons: `SerialCommandDrain`.
  private let commands = SerialCommandDrain()
  /// Numbers each admitted command, so its probe events can be matched up.
  private var lastCommandNumber = 0

  /// The command now running, and the task running it. Only that task (the drain, and
  /// whatever it awaits) may join the command. A task started while the command runs is a
  /// different task, so it queues like any other caller and Quit waits for it. A marker a
  /// task could inherit (a task-local) would let such a task skip the queue and Quit.
  private var running: (number: Int, task: Int)?

  /// Identity of the current task, compared only for equality while it is running.
  private static func currentTaskID() -> Int? {
    withUnsafeCurrentTask { $0?.hashValue }
  }

  /// The running command the caller may join, or nil when it must queue.
  private var joinableCommand: Int? {
    guard let running, let task = Self.currentTaskID(), task == running.task else { return nil }
    return running.number
  }

  /// Admits one complete command and returns its result when it has fully finished.
  ///
  /// Called from inside a running command (a `performAction` step), `body` runs at once
  /// as part of that command instead of queuing behind it, which would wait on itself.
  /// While Quit waits for admitted commands, a new one is not admitted: it returns
  /// `closing` at once, so it can never keep the app from quitting.
  private func command<Value: Sendable>(
    _ operation: CustomWordsProbe.Operation,
    closing: @autoclosure () -> Value,
    _ body: @escaping @MainActor (_ number: Int) async -> Value
  ) async -> Value {
    if let number = joinableCommand { return await body(number) }
    guard quitReply == nil else { return closing() }
    lastCommandNumber += 1
    let number = lastCommandNumber
    probe?.emit(.admitted(command: number, operation: operation))
    return await commands.admit { [self] in
      running = (number, Self.currentTaskID() ?? 0)
      let value = await body(number)
      running = nil
      probe?.emit(.completed(command: number, operation: operation))
      return value
    }
  }

  /// Runs several dictionary steps as ONE command (#4086): for example a learn or its Undo
  /// checks the learning memory, chooses its target, writes and proves the result, and no
  /// other command runs in between. Each public method `action` calls joins this command.
  /// A task `action` starts does not belong to the command: it queues behind it.
  /// While Quit waits, `action` does not run and the result is `closing`.
  func performAction<Value: Sendable>(
    closing: @autoclosure () -> Value, _ action: @escaping @MainActor () async -> Value
  ) async -> Value {
    await command(.action, closing: closing()) { _ in await action() }
  }

  // MARK: - Quit (#4086)

  /// What a dictionary change asked for while Quit waits says. Nothing was changed, and
  /// the sentence already says so.
  static var quittingMessage: String {
    CustomWordsPersistenceError.coordinationUnavailable.localizedDescription
  }
  static let quittingError = CustomWordsPersistenceError.coordinationUnavailable

  /// The one answer AppKit is owed while Quit waits for admitted commands; nil otherwise.
  private var quitReply: (@MainActor (Bool) -> Void)?
  /// An admitted command failed while Quit waited: that save was not made, so Quit stops
  /// and the person sees the error where they made the change.
  private var failedWhileQuitting = false

  /// Asked once per Quit (`applicationShouldTerminate`). Returns true when nothing is
  /// queued, and the app may quit now. Otherwise stops admitting new commands, lets every
  /// admitted one finish, then calls `reply` once: true when all of them were saved,
  /// false when one failed. After a false reply the dictionary takes commands again, and
  /// a later Quit asks again. A second Quit while one waits joins it and is answered by
  /// the same reply. Never blocks the main actor.
  func requestQuit(reply: @escaping @MainActor (Bool) -> Void) -> Bool {
    guard quitReply == nil else { return false }
    guard commands.isBusy else { return true }
    quitReply = reply
    failedWhileQuitting = false
    Task { @MainActor [self] in
      await commands.untilIdle()
      let proceed = !failedWhileQuitting
      let answer = quitReply
      quitReply = nil
      failedWhileQuitting = false
      answer?(proceed)
    }
    return false
  }

  /// The storage step of a command, between its probe events. `storageReturned` is sent
  /// only after the file worker finished the transaction, and says whether it wrote.
  private func storage<T: Sendable>(
    _ number: Int, _ operation: CustomWordsProbe.Operation,
    _ work: () async throws -> CustomWordsStoreReceipt<T>
  ) async throws -> CustomWordsStoreReceipt<T> {
    probe?.emit(.storageStarted(command: number, operation: operation))
    do {
      let receipt = try await work()
      probe?.emit(
        .storageReturned(
          command: number, operation: operation,
          outcome: receipt.committed ? .committed : .unchanged))
      return receipt
    } catch {
      probe?.emit(.storageReturned(command: number, operation: operation, outcome: .failed))
      throw error
    }
  }

  /// Adopts the saved library and tells consumers, once. A transaction that wrote nothing
  /// and returned the same library publishes nothing, so consumers do not rebuild for it.
  private func publish(
    _ words: [CustomWord], committed: Bool, _ number: Int,
    _ operation: CustomWordsProbe.Operation
  ) {
    guard committed || words != customWords else { return }
    customWords = words
    onWordsChanged?(customWords)
    probe?.emit(.published(command: number, operation: operation))
  }

  @discardableResult
  func add(_ word: CustomWord) async -> String? {
    await command(.add, closing: Self.quittingMessage) { [self] number in
      do {
        try await addWithinCommand(word, number)
        return nil
      } catch {
        return note(error)
      }
    }
  }

  /// The add step shared by `add` and `saveConfirmingSpelling`.
  @discardableResult
  private func addWithinCommand(_ word: CustomWord, _ number: Int) async throws
    -> CustomWordsStoreReceipt<[CustomWord]>?
  {
    probe?.emit(.storageStarted(command: number, operation: .add))
    let receipt: CustomWordsStoreReceipt<[CustomWord]>?
    do {
      receipt = try await manager.add(word: word)
    } catch {
      probe?.emit(.storageReturned(command: number, operation: .add, outcome: .failed))
      throw error
    }
    probe?.emit(
      .storageReturned(
        command: number, operation: .add,
        outcome: receipt?.committed == true ? .committed : .unchanged))
    if let receipt { publish(receipt.value, committed: receipt.committed, number, .add) }
    customWordError = nil
    return receipt
  }

  /// What a learn's save really did (#4086), from its own transaction. Only `.saved` makes
  /// the learn this action's change; a save that wrote nothing gives it no Undo.
  enum LearnedSave: Sendable, Equatable {
    /// This save wrote `after`. `before` is the word as the transaction found it under the
    /// lock, or nil when the save created the word.
    case saved(before: CustomWord?, after: CustomWord)
    /// The save wrote nothing: the word changed or vanished meanwhile, or the add was a
    /// duplicate.
    case notApplied
    case refused(String)
  }

  /// The learn path's one write, as one command: an edit of a word the user has (only
  /// while it still equals `expecting`), otherwise an add. The answer comes from the
  /// transaction, never from the list afterwards, which another writer may have changed.
  func saveLearned(_ word: CustomWord, expecting: CustomWord?) async -> LearnedSave {
    await command(
      customWords.contains { $0.id == word.id } ? .update : .add,
      closing: .refused(Self.quittingMessage)
    ) { [self] number in
      do {
        if customWords.contains(where: { $0.id == word.id }) {
          let edit = try await updateWithinCommand(word, number, expecting: expecting)
          guard let after = edit.after else { return .notApplied }
          return .saved(before: edit.before, after: after)
        }
        guard let receipt = try await addWithinCommand(word, number), receipt.committed,
          let after = receipt.value.first(where: { $0.id == word.id })
        else { return .notApplied }
        return .saved(before: nil, after: after)
      } catch {
        return .refused(note(error))
      }
    }
  }

  /// Write a word and PROVE the spelling is on it afterwards (Quick Add), as ONE command (#4086): the add-or-edit choice, the write and
  /// the check all see the same library, and no other command runs in between.
  ///
  /// **A normal return from a write is not evidence the write happened**, and this is
  /// the third distinct way that has been true in this feature. `add` writes nothing for
  /// a duplicate canonical and for a deleted-built-in restore; `update` writes nothing
  /// for a word another instance removed while this panel was open. The panel would then
  /// close on a spelling that was never stored.
  ///
  /// Every one of those has one observable: is the spelling on the word now. So that is
  /// what this asks, instead of asking three questions about how the write was routed.
  ///
  /// `add` when the word is new to the user library, `update` when it is already there.
  /// A converted pack term is NEW here even though its id is the pack's, which is why the
  /// decision is by membership rather than by `source`.
  func saveConfirmingSpelling(_ word: CustomWord, carrying spelling: String) async -> String? {
    await command(
      customWords.contains { $0.id == word.id } ? .update : .add, closing: Self.quittingMessage
    ) { [self] number in
      do {
        if customWords.contains(where: { $0.id == word.id }) {
          _ = try await updateWithinCommand(word, number)
        } else {
          try await addWithinCommand(word, number)
        }
      } catch {
        return note(error)
      }
      let wanted = spelling.trimmingCharacters(in: .whitespacesAndNewlines)
      let landed = customWords.contains { stored in
        stored.canonical.caseInsensitiveCompare(word.canonical) == .orderedSame
          && stored.aliases.contains { $0.caseInsensitiveCompare(wanted) == .orderedSame }
      }
      return landed ? nil : QuickAddPanelCopy.newWordNotSaved
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
    if quitReply != nil { failedWhileQuitting = true }
    if let persistence = error as? CustomWordsPersistenceError,
      persistence == .corruptedExistingFile
    {
      didDiscoverCorruptionThisSession = true
    }
    customWordError = error.localizedDescription
    return error.localizedDescription
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
  ///
  /// Two refreshes asked for while the same one is still waiting in the queue
  /// share it (#4086): a burst of Quick Add opens reads the file once.
  @discardableResult
  func refreshFromDiskIfPossible() async -> Bool {
    // Inside a running command, never join a queued refresh: it waits behind this command.
    if let number = joinableCommand { return await refreshWithinCommand(number) }
    if let waiting = queuedRefresh { return await waiting.result() }
    let receipt = SerialCommandDrain.Receipt<Bool>()
    queuedRefresh = receipt
    let result = await command(.refresh, closing: false) { [self] number in
      // Taken when this refresh STARTS, not when it ends: a refresh asked for after
      // this point must read the file again, because a write may land in between.
      queuedRefresh = nil
      return await refreshWithinCommand(number)
    }
    receipt.complete(result)
    return result
  }

  /// The refresh still waiting to start, which a new request joins instead of queuing
  /// another read.
  private var queuedRefresh: SerialCommandDrain.Receipt<Bool>?

  /// `refreshFromDiskIfPossible` for code already running inside a command.
  private func refreshWithinCommand(_ number: Int) async -> Bool {
    // `readSnapshot()`, never a words-only read (Codex Chunk 2 review round 2
    // finding 4): words and `pendingEnrichmentBatchTotal` must adopt together
    // here too, the same atomic-pair guarantee every other read/write path
    // already honors — otherwise a stale-commit refresh after another app
    // instance wrote can leave the total pointing at a run that no longer
    // matches the just-refreshed words.
    probe?.emit(.storageStarted(command: number, operation: .refresh))
    let read = await manager.readSnapshot()
    let snapshot: CustomWordsLibrarySnapshot
    switch read {
    case .loaded(let loaded):
      probe?.emit(.storageReturned(command: number, operation: .refresh, outcome: .unchanged))
      snapshot = loaded
    case .failed(let failure):
      probe?.emit(.storageReturned(command: number, operation: .refresh, outcome: .failed))
      // Corruption found DURING the session, not at launch, is still
      // corruption — and it must be remembered (code review r3). The load
      // archives the damaged file aside, so the NEXT attempt sees a
      // legitimately missing file, adopts the built-ins, and reports success.
      // Without latching this, a retry would sail past the export guard, find
      // zero user words, and write an empty file over the user's existing one.
      if failure == .corrupted {
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
      if wordsChanged {
        onWordsChanged?(customWords)
        probe?.emit(.published(command: number, operation: .refresh))
      }
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
  func commitImport(_ plan: CustomWordsImportCommitPlan) async -> CustomWordsImportCommitOutcome {
    await command(.importCommit, closing: .failed(message: Self.quittingMessage)) { [self] number in
      do {
        let stored = try await storage(number, .importCommit) {
          try await manager.commitImport(plan)
        }
        let receipt = stored.value.receipt
        if !plan.isEmpty {
          // A genuinely NEW run starting (nil -> non-nil) clears any stale
          // display left over from a previous, already-completed run — an
          // EXTENDING commit (a run already active) must not reset it, since
          // that would flicker away a display mid-drain (Codex Chunk 2 review
          // finding 6).
          let isNewRun =
            pendingEnrichmentBatchTotal == nil && receipt.pendingEnrichmentBatchTotal != nil
          // The total and the display first, then the words: a consumer told about the
          // new words reads the total that belongs with them (the atomic pair, #1701).
          pendingEnrichmentBatchTotal = receipt.pendingEnrichmentBatchTotal
          if isNewRun { mostRecentEnrichment = nil }
          if let words = stored.value.words {
            publish(words, committed: stored.committed, number, .importCommit)
          }
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
        // which is honest either way — nothing was written. Inside this same
        // command (#4086): the sheet re-compares against the refreshed list.
        _ = await refreshWithinCommand(number)
        customWordError = nil
        return .stale
      } catch {
        return .failed(message: note(error))
      }
    }
  }

  /// Bulk-add for the contacts import (#636). Returns the IDs actually created
  /// (for the import log), or nil on failure (check `customWordError`).
  func addBatch(_ words: [CustomWord]) async -> [UUID]? {
    await command(.addBatch, closing: nil) { [self] number in
      do {
        let stored = try await storage(number, .addBatch) { try await manager.addBatch(words) }
        publish(stored.value.words, committed: stored.committed, number, .addBatch)
        customWordError = nil
        return stored.value.created
      } catch {
        _ = note(error)
        return nil
      }
    }
  }

  /// A plain delete: no learned pair becomes a refusal. Undo, imports and cleanup use it.
  /// With `expecting`, only while the word still equals it (learning's Undo).
  @discardableResult
  func remove(id: UUID, expecting: CustomWord? = nil) async -> String? {
    await command(.remove, closing: Self.quittingMessage) { [self] number in
      do {
        _ = try await removeWithinCommand(
          [id], number, .remove, expecting: expecting.map { [$0] })
        return nil
      } catch {
        return note(error)
      }
    }
  }

  /// The delete step shared by the plain and the user's doors.
  private func removeWithinCommand(
    _ ids: [UUID], _ number: Int, _ operation: CustomWordsProbe.Operation,
    expecting: [CustomWord]? = nil
  ) async throws -> CustomWordsRemoval {
    let stored = try await storage(number, operation) {
      try await manager.removeBatch(ids: ids, expecting: expecting)
    }
    publish(stored.value.words, committed: stored.committed, number, operation)
    customWordError = nil
    return stored.value
  }

  // MARK: - Auto-learn (#996, 2026-09-21 plan): the learn path's writes

  /// What `restoreBuiltinAndLearn` answered, for the learn coordinator's seam.
  enum BuiltinRestoreOutcome: Sendable {
    case restored(RestoredBuiltinLearnOutcome)
    /// No tombstoned built-in carries that canonical.
    case notFound
    case failed
  }

  /// Bring a deleted built-in back as a user override carrying `alias` as a
  /// learned sound-alike, in one manager transaction; publishes the merged
  /// list like every other write here.
  func restoreBuiltinAndLearn(canonical: String, alias: String) async -> BuiltinRestoreOutcome {
    await command(.restoreBuiltin, closing: .failed) { [self] number in
      do {
        let stored = try await storage(number, .restoreBuiltin) {
          try await manager.restoreBuiltinAndLearn(canonical: canonical, alias: alias)
        }
        publish(stored.value.words, committed: stored.committed, number, .restoreBuiltin)
        customWordError = nil
        return .restored(stored.value)
      } catch CustomWordsPersistenceError.noRestorableBuiltin {
        return .notFound
      } catch {
        _ = note(error)
        return .failed
      }
    }
  }

  /// Exact undo of `restoreBuiltinAndLearn`: the override goes, the tombstone
  /// comes back.
  @discardableResult
  func redeleteRestoredBuiltin(id: UUID, expecting: CustomWord? = nil) async -> String? {
    await command(.redeleteBuiltin, closing: Self.quittingMessage) { [self] number in
      do {
        let stored = try await storage(number, .redeleteBuiltin) {
          try await manager.redeleteRestoredBuiltin(id: id, expecting: expecting)
        }
        publish(stored.value, committed: stored.committed, number, .redeleteBuiltin)
        customWordError = nil
        return nil
      } catch {
        return note(error)
      }
    }
  }

  /// Remove a user override of a built-in WITHOUT tombstoning the built-in
  /// (the learn path's Undo of a live built-in that gained a sound-alike).
  @discardableResult
  func removeUserOverride(id: UUID, expecting: CustomWord? = nil) async -> String? {
    await command(.removeOverride, closing: Self.quittingMessage) { [self] number in
      do {
        let stored = try await storage(number, .removeOverride) {
          try await manager.removeUserOverride(id: id, expecting: expecting)
        }
        publish(stored.value, committed: stored.committed, number, .removeOverride)
        customWordError = nil
        return nil
      } catch {
        return note(error)
      }
    }
  }

  /// Bulk-remove by ID (contacts-import pill, #636).
  @discardableResult
  func removeBatch(ids: [UUID]) async -> String? {
    await command(.removeBatch, closing: Self.quittingMessage) { [self] number in
      do {
        _ = try await removeWithinCommand(ids, number, .removeBatch)
        return nil
      } catch {
        return note(error)
      }
    }
  }

  /// A plain edit: no removed learned sound-alike becomes a refusal.
  /// With `expecting`, only while the word still equals it (learning's Undo).
  @discardableResult
  func update(_ word: CustomWord, expecting: CustomWord? = nil) async -> String? {
    await command(.update, closing: Self.quittingMessage) { [self] number in
      do {
        _ = try await updateWithinCommand(word, number, expecting: expecting)
        return nil
      } catch {
        return note(error)
      }
    }
  }

  /// The edit step shared by the plain and the user's doors.
  private func updateWithinCommand(
    _ word: CustomWord, _ number: Int, expecting: CustomWord? = nil
  ) async throws -> CustomWordsEdit {
    let stored = try await storage(number, .update) {
      try await manager.update(word: word, expecting: expecting)
    }
    publish(stored.value.words, committed: stored.committed, number, .update)
    customWordError = nil
    return stored.value
  }

  // MARK: - Learning memory in Settings (#3975 §3.4)

  /// What the Learning memory row shows; read by `refreshLearnMemorySummary`.
  private(set) var learnMemoryStored = false
  private(set) var learnMemoryBlockedCount = 0
  /// The last Forget did not delete everything; the row says so.
  private(set) var learnMemoryForgetFailed = false

  /// Every committed change (the watcher's refusals, Undo, a Settings delete,
  /// Forget) updates the row, so an open Settings tab is never stale.
  private func observeLearnMemory() {
    learnMemory.onChange = { [weak self] in self?.refreshLearnMemorySummary() }
  }

  func refreshLearnMemorySummary() {
    learnMemoryStored = learnMemory.hasStoredMemory
    learnMemoryBlockedCount = learnMemory.blockedCount
  }

  /// Deletes the memory file and every corrupt copy; the row reads the result.
  func forgetLearnMemory() {
    learnMemoryForgetFailed = !learnMemory.forgetAll()
  }

  // MARK: - User refusals (#3975)
  //
  // The ONLY doors that turn a removal into the user's "no" for a learned
  // pair. Undo, imports, enrichment, cleanup and sanitising go through the
  // plain doors above and record nothing, so one Undo is one no, never two.
  //
  // Each is ONE command (#4086): the delete or edit, then its refusals, before
  // the next command starts. The refusals come from what the transaction really
  // removed, read under the file lock, never from this list's idea of it. The
  // learning memory is a separate file: a refusal it could not remember leaves
  // the saved delete or edit in place, as before.

  /// The user deleted a word in Settings: each pair it learned gets one "no",
  /// after the delete landed.
  @discardableResult
  func deleteByUser(id: UUID) async -> String? {
    await deleteByUser(ids: [id], operation: .remove)
  }

  /// Bulk delete from Settings (or the deliberate Contacts "remove imported").
  @discardableResult
  func deleteByUser(ids: [UUID]) async -> String? {
    await deleteByUser(ids: ids, operation: .removeBatch)
  }

  private func deleteByUser(ids: [UUID], operation: CustomWordsProbe.Operation) async -> String? {
    await command(operation, closing: Self.quittingMessage) { [self] number in
      do {
        let removal = try await removeWithinCommand(ids, number, operation)
        recordUserNo(learnedPairs(of: removal.removed), source: .deleteWord)
        return nil
      } catch {
        return note(error)
      }
    }
  }

  /// The user saved an edit: each learned sound-alike the edit removed gets
  /// one "no", after the save landed.
  @discardableResult
  func updateByUser(_ word: CustomWord) async -> String? {
    await command(.update, closing: Self.quittingMessage) { [self] number in
      do {
        let edit = try await updateWithinCommand(word, number)
        guard let before = edit.before, let after = edit.after else { return nil }
        let kept = Set(after.aliases.map(CorrectionPairKey.normalise))
        let removed = before.learnedAliases
          .filter { !kept.contains(CorrectionPairKey.normalise($0)) }
          .map { CorrectionPairKey.make(original: $0, corrected: before.canonical) }
        recordUserNo(removed, source: .removeSoundAlike)
        return nil
      } catch {
        return note(error)
      }
    }
  }

  private func learnedPairs(of words: [CustomWord]) -> [String] {
    words.flatMap { word in
      word.learnedAliases.map { CorrectionPairKey.make(original: $0, corrected: word.canonical) }
    }
  }

  private func recordUserNo(
    _ pairKeys: [String], source: TelemetryService.LearnFromEditsTelemetry.RefusalSource
  ) {
    for key in Set(pairKeys) {
      switch learnMemory.recordUndo(key) {
      case .committed(.watching): onLearnRefusedByUser?(source, .watching)
      case .committed(.blocked): onLearnRefusedByUser?(source, .blocked)
      case .notRemembered: break
      }
    }
  }

  /// Generated aliases for imported contact names (#636 follow-up). One
  /// `onWordsChanged` for the whole batch so the corrector rebuilds once per flush,
  /// not once per word. A stale proposal is skipped under the file lock.
  @discardableResult
  func applyGeneratedAliases(_ proposals: [GeneratedAliasProposal]) async -> String? {
    await command(.generatedAliases, closing: Self.quittingMessage) { [self] number in
      do {
        let stored = try await storage(number, .generatedAliases) {
          try await manager.applyGeneratedAliases(proposals)
        }
        if let merged = stored.value {
          publish(merged, committed: stored.committed, number, .generatedAliases)
        }
        customWordError = nil
        return nil
      } catch {
        return note(error)
      }
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
    /// real file-system timing.
    var forcePendingEnrichmentWordsFailureOnCallForTesting: Int?
    private var pendingEnrichmentWordsCallCountForTesting = 0
  #endif

  /// Word list filtered to `enrichmentPending == true` — the durable queue
  /// itself is this scan over live state, never an in-memory job list. `nil`
  /// only on the same unrecoverable read failure `customWords` itself would
  /// report via `customWordError`.
  func pendingEnrichmentWords() async -> [CustomWord]? {
    #if DEBUG
      pendingEnrichmentWordsCallCountForTesting += 1
      if forcePendingEnrichmentWordsFailureOnCallForTesting
        == pendingEnrichmentWordsCallCountForTesting
      {
        return nil
      }
    #endif
    return await command(.enrichmentRead, closing: nil) { [self] number in
      probe?.emit(.storageStarted(command: number, operation: .enrichmentRead))
      let words = await manager.loadPendingEnrichmentWords()
      probe?.emit(
        .storageReturned(
          command: number, operation: .enrichmentRead,
          outcome: words == nil ? .failed : .unchanged))
      return words
    }
  }

  /// One-time self-heal: repairs a `nil` durable total to the current live
  /// pending count when pending words exist but no total does. Adopts the
  /// (possibly just-repaired) total either way. Called by the background
  /// coordinator before it begins draining. Throws (Phase 3 review finding
  /// B, #1701) rather than silently falling back to the stale total, so a
  /// caller can distinguish a transient `.libraryBusy` from a permanent
  /// failure and retry accordingly.
  @discardableResult
  func repairPendingEnrichmentTotalIfNeeded() async throws -> Int? {
    try await command(.enrichmentRepair, closing: .failure(Self.quittingError)) {
      [self] number -> Result<Int?, any Error> in
      do {
        let stored = try await storage(number, .enrichmentRepair) {
          try await manager.repairPendingEnrichmentTotalIfNeeded()
        }
        pendingEnrichmentBatchTotal = stored.value
        customWordError = nil
        return .success(stored.value)
      } catch {
        _ = note(error)
        return .failure(error)
      }
    }.get()
  }

  /// Merge-safe, pending-gated checkpoint. Atomically adopts both the
  /// returned words and the returned total before notifying observers — never
  /// one without the other. Fires `onWordsChanged` only when something in
  /// this batch actually still needed applying (first-terminal-action-wins:
  /// a checkpoint that only contains already-resolved IDs is a no-op).
  /// Throws (Phase 3 review finding B, #1701) so a caller can distinguish a
  /// transient `.libraryBusy` from a permanent failure and retry accordingly.
  func applyEnrichmentResults(_ results: [CustomWordEnrichmentResult]) async throws {
    try await command(.enrichmentApply, closing: .failure(Self.quittingError)) {
      [self] number -> Result<Void, any Error> in
      do {
        let stored = try await storage(number, .enrichmentApply) {
          try await manager.applyEnrichmentResults(results)
        }
        let outcome = stored.value
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
        if changed {
          onWordsChanged?(customWords)
          probe?.emit(.published(command: number, operation: .enrichmentApply))
        }
        return .success(())
      } catch {
        _ = note(error)
        return .failure(error)
      }
    }.get()
  }

  /// Durable Cancel: one locked reload-and-sweep, under the manager's own
  /// lock, clearing every word CURRENTLY pending — never this coordinator's
  /// potentially-stale in-memory idea of what was pending — and the durable
  /// total. Atomically adopts both before notifying observers.
  @discardableResult
  func cancelEnrichment() async -> String? {
    await command(.enrichmentCancel, closing: Self.quittingMessage) { [self] number in
      do {
        let stored = try await storage(number, .enrichmentCancel) {
          try await manager.cancelEnrichment()
        }
        let snapshot = stored.value
        let changed =
          snapshot.words != customWords
          || snapshot.pendingEnrichmentBatchTotal != pendingEnrichmentBatchTotal
        customWords = snapshot.words
        pendingEnrichmentBatchTotal = snapshot.pendingEnrichmentBatchTotal
        mostRecentEnrichment = nil
        customWordError = nil
        if changed {
          onWordsChanged?(customWords)
          probe?.emit(.published(command: number, operation: .enrichmentCancel))
        }
        return nil
      } catch {
        return note(error)
      }
    }
  }
}

/// #3975: the learning memory's text-free signals in production. A reset
/// (corrupt file set aside) is a breadcrumb; an event not remembered is a
/// Debug log line only (plan §7).
enum LearnMemoryDiagnostics {
  @MainActor
  static func forward(_ diagnostic: LearnMemoryDiagnostic) {
    if diagnostic == .memoryReset {
      SentryBreadcrumb.add(stage: "learn_memory", message: "learn_memory_reset", level: .warning)
    }
    #if DEBUG
      Task { await AppLogger.shared.log("learn_memory \(diagnostic)", category: "LearnFromEdits") }
    #endif
  }
}
