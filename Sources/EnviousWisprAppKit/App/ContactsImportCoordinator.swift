import EnviousWisprContacts
import EnviousWisprCore
import EnviousWisprPostProcessing
import EnviousWisprServices
import Foundation
import Observation

/// Orchestrates a user-initiated import of contact names into the custom-word
/// list, and tracks what was imported (#636).
///
/// Limb, not heart: raw dictation never depends on this. It cross-cuts the
/// Contacts framework (via `ContactNameProvider`), the import log
/// (`ImportedContactsStateStore`), and custom-word mutation (via
/// `CustomWordsCoordinator`) — genuine top-level orchestration, so it lives at
/// the App layer and is injected by `WisprBootstrapper`.
///
/// Counts shown to the user are in PEOPLE, not correction terms: one contact
/// yields its distinctive first and/or last name as separate tokens (0-2 terms),
/// but the confirm sheet and the pill speak in contacts ("42 names").
@MainActor @Observable
final class ContactsImportCoordinator {
  enum ImportPhase: Equatable {
    case idle
    case requesting
    case importing
    case imported(count: Int)  // contacts added this round (transient green-check feedback)
    case denied
    case failed(String)
  }

  /// Honest preview surfaced to the confirm sheet before any write.
  struct ImportPreview: Equatable {
    let newWords: [CustomWord]  // distinctive first/last tokens to add
    let newContactIDs: [String]  // distinct contacts contributing those terms
    let newContactCount: Int  // = newContactIDs.count, the "N names" shown
    let alreadyPresentCount: Int  // contacts already in the list / already imported
  }

  /// Background alias-generation progress. `done` counts words attempted (some
  /// yield no usable aliases), `total` the words targeted at job start. UI-only.
  struct EnrichmentProgress: Equatable {
    var done: Int
    var total: Int
  }

  private(set) var phase: ImportPhase = .idle
  /// Distinct contacts imported so far — drives the persistent "N imported" pill.
  private(set) var importedCount: Int
  /// Non-nil while the confirm sheet should be shown.
  private(set) var pendingPreview: ImportPreview?
  /// Live background alias-generation progress (nil when idle). Drives the
  /// "Finding spoken variants…" line. UI-only, never persisted.
  private(set) var enrichmentProgress: EnrichmentProgress?

  private let provider: any ContactNameProvider
  private let customWords: CustomWordsCoordinator
  private let stateStore: ImportedContactsStateStore
  /// On-device alias generator, reused from the custom-words coordinator at the
  /// composition root. nil in tests that don't exercise enrichment; production
  /// always injects it. nil here means enrichment is disabled (clean no-op).
  private let aliasSuggester: (any AliasSuggesting)?
  private var enrichmentTask: Task<Void, Never>?
  /// Identity token: a superseded task whose generation no longer matches must
  /// not clear a newer task's state. Bumped by every start and every cancel.
  private var enrichmentGeneration = 0

  /// Priority for imported names: sorts AFTER user-typed terms (priority 0) in
  /// the 50-term polish cap, so a large import never crowds out hand-typed
  /// vocabulary (§3.5). `WordCorrector` ignores priority, so this is a
  /// polish-prompt quality lever only, never a correction lever.
  private let importedPriority = 10

  /// Flush generated aliases to disk every N words so the corrector rebuilds at
  /// most ceil(count/N) times rather than once per word (heart-path mitigation).
  private static let enrichmentFlushChunk = 25

  init(
    provider: any ContactNameProvider = CNContactStoreProvider(),
    customWords: CustomWordsCoordinator,
    stateStore: ImportedContactsStateStore = ImportedContactsStateStore(),
    aliasSuggester: (any AliasSuggesting)? = nil
  ) {
    self.provider = provider
    self.customWords = customWords
    self.stateStore = stateStore
    self.aliasSuggester = aliasSuggester
    self.importedCount = stateStore.load().importedContactIDs.count
  }

  /// Step 1 (user taps Import): request access if needed, fetch, shape, dedupe,
  /// and stage a preview for the confirm sheet. Writes nothing.
  func prepareImport() async {
    guard phase != .requesting, phase != .importing, pendingPreview == nil else { return }
    phase = .requesting

    switch provider.authorizationStatus() {
    case .denied, .restricted:
      phase = .denied
      return
    case .notDetermined:
      guard await provider.requestAccess() else {
        phase = .denied
        return
      }
    case .authorized:
      break
    }

    do {
      let candidates = try await provider.fetchCandidateNames()
      pendingPreview = buildPreview(ContactNameShaper.shape(candidates))
      phase = .idle  // sheet shows off `pendingPreview`; phase tracks async/terminal only
    } catch {
      phase = .failed(error.localizedDescription)
    }
  }

  /// Step 2 (user confirms): commit the staged preview — batch-add + log.
  func confirmImport() {
    guard let preview = pendingPreview else { return }
    pendingPreview = nil
    guard !preview.newWords.isEmpty else {
      // Nothing new to add, but a re-scan should still recover: clean up dead
      // combined entries from earlier builds and fill in any missing aliases on
      // names already imported.
      phase = .idle
      cleanupLegacyCombinedEntries()
      startEnrichment()
      return
    }
    phase = .importing
    guard let createdIDs = customWords.addBatch(preview.newWords) else {
      phase = .failed(customWords.customWordError ?? "Couldn't save, try again")
      return
    }
    do {
      try persistLog(contactIDs: preview.newContactIDs, wordIDs: createdIDs)
    } catch {
      // Words were added but the import log didn't save. Surface it: the words
      // persist (removable by hand) but the pill can't track them. Telemetry
      // fires only on full success.
      phase = .failed("Couldn't finish the import, try again")
      return
    }
    TelemetryService.shared.contactsImported(count: preview.newContactCount, trigger: "manual")
    phase = .imported(count: preview.newContactCount)
    cleanupLegacyCombinedEntries()
    startEnrichment()
  }

  /// User dismisses the confirm sheet without importing. Also stops any running
  /// enrichment (the user backed out of this import action); a later confirm or
  /// re-scan re-runs it over the import-logged words that still need aliases.
  func cancelImport() {
    pendingPreview = nil
    phase = .idle
    cancelEnrichment()
  }

  /// Opt-in launch sync: add-only, no UI, safe off the launch path. Adds only
  /// contacts not already imported; never updates or deletes.
  func syncNewContacts() async {
    guard provider.authorizationStatus() == .authorized else { return }
    do {
      let candidates = try await provider.fetchCandidateNames()
      let preview = buildPreview(ContactNameShaper.shape(candidates))
      guard !preview.newWords.isEmpty,
        let createdIDs = customWords.addBatch(preview.newWords), !createdIDs.isEmpty
      else { return }
      try persistLog(contactIDs: preview.newContactIDs, wordIDs: createdIDs)
      TelemetryService.shared.contactsImported(
        count: preview.newContactCount, trigger: "launch_sync")
      cleanupLegacyCombinedEntries()
      startEnrichment()
    } catch {
      // Limb: stay silent on failure (incl. a log-save failure from persistLog);
      // the existing word list is untouched and telemetry does not fire.
    }
  }

  /// Bulk-remove exactly the import-created words still present, then clear the
  /// log. Manually-deleted words are already absent and skipped silently.
  func bulkRemoveImported() {
    let state = stateStore.load()
    guard !state.importedWordIDs.isEmpty else { return }
    // Stop enriching words we are about to delete; the canceller owns the clear.
    cancelEnrichment()
    // Only erase ownership if BOTH the removal and the log reset succeed —
    // otherwise words could remain while the pill loses track of them.
    if let error = customWords.removeBatch(ids: state.importedWordIDs) {
      phase = .failed(error)
      return
    }
    do {
      try stateStore.save(.empty)
    } catch {
      phase = .failed("Couldn't update the import list, try again")
      return
    }
    importedCount = 0
    phase = .idle
  }

  // MARK: - Private

  private func buildPreview(_ shaped: [ShapedName]) -> ImportPreview {
    let state = stateStore.load()
    let alreadyImportedContacts = Set(state.importedContactIDs)
    let existingCanonicals = Set(customWords.customWords.map { $0.canonical.lowercased() })

    var newWords: [CustomWord] = []
    var newContactIDs = Set<String>()
    var seenCanonical = Set<String>()

    for item in shaped {
      // Idempotent re-scan: a contact we already imported is skipped wholesale.
      if alreadyImportedContacts.contains(item.contactID) { continue }
      let key = item.canonical.lowercased()
      // Canonical already in the list (user-typed, built-in, or another contact).
      if existingCanonicals.contains(key) || seenCanonical.contains(key) { continue }
      seenCanonical.insert(key)
      newWords.append(
        CustomWord(
          canonical: item.canonical,
          category: .person,
          priority: importedPriority,
          source: .user))
      newContactIDs.insert(item.contactID)
    }

    // Contacts present in the address book but contributing no new term (already
    // imported, or every canonical already exists) are "already in your list".
    let allContactIDs = Set(shaped.map { $0.contactID })
    let alreadyPresent = allContactIDs.subtracting(newContactIDs).count

    return ImportPreview(
      newWords: newWords,
      newContactIDs: Array(newContactIDs),
      newContactCount: newContactIDs.count,
      alreadyPresentCount: alreadyPresent)
  }

  private func persistLog(contactIDs: [String], wordIDs: [UUID]) throws {
    var state = stateStore.load()
    state.record(contactIDs: contactIDs, wordIDs: wordIDs, at: Date())
    try stateStore.save(state)
    importedCount = state.importedContactIDs.count
  }

  // MARK: - Alias enrichment (#636 follow-up)

  /// Remove the dead combined "First Last" entries earlier builds wrote. Strictly
  /// ID-scoped: only import-logged word IDs whose current canonical contains a
  /// space are touched, so a user's hand-typed multi-word term is never removed.
  /// Removed IDs are dropped from the log so enrichment never re-targets them.
  /// The contact stays imported (its per-name tokens remain), so `importedCount`
  /// is unchanged. Best-effort: a removal/log-save failure leaves state as-is.
  private func cleanupLegacyCombinedEntries() {
    var state = stateStore.load()
    guard !state.importedWordIDs.isEmpty else { return }
    let loggedIDs = Set(state.importedWordIDs)
    let staleIDs =
      customWords.customWords
      .filter { loggedIDs.contains($0.id) && $0.canonical.contains(" ") }
      .map(\.id)
    guard !staleIDs.isEmpty else { return }
    guard customWords.removeBatch(ids: staleIDs) == nil else { return }
    let removed = Set(staleIDs)
    state.importedWordIDs.removeAll { removed.contains($0) }
    try? stateStore.save(state)
  }

  /// Start background alias generation for import-logged person names that still
  /// have no aliases (recovers mid-job-quit / model-unavailable stragglers on a
  /// re-scan, not just freshly added words). Low priority, never blocks the heart
  /// path; persists in batches so the corrector rebuilds at most ceil(count/25)
  /// times. Cancels and supersedes any prior run via the generation token.
  private func startEnrichment() {
    enrichmentTask?.cancel()
    enrichmentGeneration += 1
    let gen = enrichmentGeneration
    guard let suggester = aliasSuggester, suggester.isAvailable else {
      enrichmentProgress = nil
      enrichmentTask = nil
      return
    }
    let loggedIDs = Set(stateStore.load().importedWordIDs)
    let targetIDs =
      customWords.customWords
      .filter { loggedIDs.contains($0.id) && $0.category == .person && $0.aliases.isEmpty }
      .map(\.id)
    guard !targetIDs.isEmpty else {
      enrichmentProgress = nil
      enrichmentTask = nil
      return
    }
    enrichmentProgress = EnrichmentProgress(done: 0, total: targetIDs.count)
    enrichmentTask = Task(priority: .utility) { [weak self] in
      await self?.runEnrichment(targetIDs: targetIDs, suggester: suggester, generation: gen)
    }
  }

  /// The enrichment loop. Runs on the main actor (the coordinator is
  /// `@MainActor`); each on-device call hops off and resumes here, so all
  /// custom-word reads/writes stay serialized. Honors cancellation before AND
  /// after every await, and re-reads each word after the await (actor
  /// reentrancy) so a word the user removed or edited mid-job is never clobbered.
  private func runEnrichment(
    targetIDs: [UUID], suggester: any AliasSuggesting, generation gen: Int
  ) async {
    var buffer: [CustomWord] = []
    var attempted = 0

    func flush() {
      guard !buffer.isEmpty else { return }
      _ = customWords.updateBatch(buffer)
      buffer.removeAll(keepingCapacity: true)
    }

    defer {
      // Only the current generation clears shared state. A superseded task (a
      // newer start replaced it, or a canceller already cleared) must not null
      // the newer/cleared state.
      if gen == enrichmentGeneration {
        enrichmentProgress = nil
        enrichmentTask = nil
      }
    }

    for id in targetIDs {
      if Task.isCancelled { return }
      // Skip a word that vanished or already gained aliases since job start.
      guard
        let current = customWords.customWords.first(where: { $0.id == id }),
        current.aliases.isEmpty
      else {
        attempted += 1
        enrichmentProgress?.done = attempted
        continue
      }
      let raw = await suggester.suggestAliases(for: current.canonical, category: .person)
      if Task.isCancelled { return }  // post-await: never write for a cancelled job
      attempted += 1
      enrichmentProgress?.done = attempted
      // Re-read after the await: the user may have removed or edited the word.
      guard
        let fresh = customWords.customWords.first(where: { $0.id == id }),
        fresh.aliases.isEmpty
      else { continue }
      // Drop any generated alias that is itself a common word — an alias enters
      // WordCorrector's unconditional single-alias self-map, so a common-word
      // alias would rewrite ordinary speech.
      let safe = (raw ?? []).filter { !ContactNameShaper.isCommonWord($0) }
      guard !safe.isEmpty else { continue }
      var updated = fresh
      updated.aliases = safe
      buffer.append(updated)
      if buffer.count >= Self.enrichmentFlushChunk { flush() }
    }
    flush()
  }

  /// Stop any running enrichment and clear its UI state. The canceller owns the
  /// clear: the in-task generation guard blocks a superseded task from nulling
  /// state, so on an explicit cancel (no successor task) the progress line would
  /// otherwise stick. Bumping the generation also makes the cancelled task's own
  /// end-of-run clear a no-op (gen mismatch).
  private func cancelEnrichment() {
    enrichmentTask?.cancel()
    enrichmentGeneration += 1
    enrichmentTask = nil
    enrichmentProgress = nil
  }

  /// Test seam: await the current enrichment task to completion (no sleeps).
  /// Returns immediately when no job is running.
  // periphery:ignore - test seam
  package func awaitEnrichmentForTesting() async {
    await enrichmentTask?.value
  }
}
