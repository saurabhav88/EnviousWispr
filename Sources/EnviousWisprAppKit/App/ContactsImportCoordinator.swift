import EnviousWisprContacts
import EnviousWisprCore
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
/// yields a full-name canonical plus any distinctive lone tokens (1-3 terms),
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
    let newWords: [CustomWord]  // terms to add (full names + distinctive tokens)
    let newContactIDs: [String]  // distinct contacts contributing those terms
    let newContactCount: Int  // = newContactIDs.count, the "N names" shown
    let alreadyPresentCount: Int  // contacts already in the list / already imported
  }

  private(set) var phase: ImportPhase = .idle
  /// Distinct contacts imported so far — drives the persistent "N imported" pill.
  private(set) var importedCount: Int
  /// Non-nil while the confirm sheet should be shown.
  private(set) var pendingPreview: ImportPreview?

  private let provider: any ContactNameProvider
  private let customWords: CustomWordsCoordinator
  private let stateStore: ImportedContactsStateStore

  /// Priority for imported names: sorts AFTER user-typed terms (priority 0) in
  /// the 50-term polish cap, so a large import never crowds out hand-typed
  /// vocabulary (§3.5). `WordCorrector` ignores priority, so this is a
  /// polish-prompt quality lever only, never a correction lever.
  private let importedPriority = 10

  init(
    provider: any ContactNameProvider = CNContactStoreProvider(),
    customWords: CustomWordsCoordinator,
    stateStore: ImportedContactsStateStore = ImportedContactsStateStore()
  ) {
    self.provider = provider
    self.customWords = customWords
    self.stateStore = stateStore
    self.importedCount = stateStore.load().importedContactIDs.count
  }

  var authorizationStatus: ContactsAuthorization { provider.authorizationStatus() }

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
      phase = .idle
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
  }

  /// User dismisses the confirm sheet without importing.
  func cancelImport() {
    pendingPreview = nil
    phase = .idle
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
}
