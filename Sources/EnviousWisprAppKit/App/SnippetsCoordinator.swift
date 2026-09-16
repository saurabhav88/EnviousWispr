import EnviousWisprCore
import EnviousWisprPostProcessing
import Foundation
import Observation

/// Owns the user's snippets for the UI, and publishes each change to the pipeline (#628).
///
/// One writer, by design. Custom words are written from several places — the settings list,
/// import, auto-learn, the debounced usage counter — which is why `CustomWordsCoordinator` is
/// large. Snippets are written only from the Snippets screen, so this stays a thin observable
/// wrapper over `SnippetsManager` and gains nothing from mirroring that machinery.
@MainActor @Observable
final class SnippetsCoordinator {
  /// The live vocabulary. The single source the list, the sheet and the pipeline all read, so
  /// no two of them can disagree about what is saved.
  private(set) var vocabulary: SnippetVocabulary = .empty

  /// The last failure, in the user's words, or nil. Shown in the screen rather than logged and
  /// swallowed: these snippets are typed by hand and exist nowhere else, so a save that did not
  /// happen must say so.
  var errorMessage: String?

  /// Called after every successful change, with the new vocabulary.
  ///
  /// A closure rather than a propagator with weak boxes: snippets have exactly ONE live
  /// consumer (the expansion step on the live driver), and a registration mechanism built for
  /// four consumers would be four-fifths ceremony. The bootstrapper owns the wiring.
  var onVocabularyChanged: ((SnippetVocabulary) -> Void)?

  private let manager: SnippetsManager

  /// Test seam: runs on the main actor after an import's store write has returned and before
  /// its publication. The window it opens is the one an edit sheet's save can land in; a
  /// test stages that save here. Never set in production.
  // periphery:ignore - test seam
  var importWriteDidReturn: (@MainActor () -> Void)?

  init(manager: SnippetsManager = SnippetsManager()) {
    self.manager = manager
    // Assigned directly, not through `adopt`: nothing has registered a listener yet, and the
    // bootstrapper seeds both drivers from `vocabulary` immediately after construction. This is
    // the ONE site that may write it without publishing, and it is one line from the property.
    //
    // `loadOrSeedStarters` rather than `load`: a first launch writes the example snippets here,
    // before either driver is seeded, so the examples are live in the very first dictation
    // rather than after a restart.
    vocabulary = manager.loadOrSeedStarters()
  }

  var snippets: [Snippet] { vocabulary.snippets }
  var keyword: String { vocabulary.keyword }

  /// Snippets matching `query` against BOTH the trigger and the expansion.
  ///
  /// The expansion is searched too because that is how a user finds a snippet whose trigger
  /// they have forgotten — they remember the address, not the words they picked for it.
  func filtered(by query: String) -> [Snippet] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !needle.isEmpty else { return snippets }
    return snippets.filter {
      $0.trigger.lowercased().contains(needle) || $0.expansion.lowercased().contains(needle)
    }
  }

  // MARK: - Mutations

  @discardableResult
  func save(_ snippet: Snippet) -> Bool {
    apply { try manager.upsert(snippet) }
  }

  @discardableResult
  func delete(_ snippet: Snippet) -> Bool {
    apply { try manager.remove(id: snippet.id) }
  }

  @discardableResult
  func setKeyword(_ keyword: String) -> Bool {
    apply { try manager.setKeyword(keyword) }
  }

  /// Run a store mutation, adopt its result, publish it, and turn any failure into a sentence
  /// the user can act on. Returns whether it succeeded, so a sheet knows whether to close.
  ///
  /// Every mutation goes through here so the adopt-and-publish pair can never be done by one
  /// caller and forgotten by the next — a screen that saved without publishing would leave the
  /// user's next dictation running against the previous list.
  private func apply(_ mutation: () throws -> SnippetVocabulary) -> Bool {
    do {
      adopt(try mutation())
      errorMessage = nil
      return true
    } catch let error as SnippetValidationError {
      errorMessage = Self.message(for: error)
      return false
    } catch let error as SnippetStoreError {
      errorMessage = Self.message(for: error)
      return false
    } catch {
      errorMessage = "That could not be saved. \(error.localizedDescription)"
      return false
    }
  }

  /// One sentence per closed-set case, written for the person who typed the thing.
  static func message(for error: SnippetValidationError) -> String {
    switch error {
    case .triggerEmpty:
      return "Give the snippet something to say. A trigger of only punctuation can never match."
    case .expansionEmpty:
      return
        "Add the text this snippet should paste. An empty snippet would delete the words you said."
    case .duplicateTrigger(let existing):
      return
        "You already have a snippet for those words: \u{201C}\(existing)\u{201D}. Change one of them."
    case .keywordNotOneWord:
      return "Your keyword has to be a single word. Pick one you would not say by accident."
    }
  }

  /// The store's own failures, which are not the user's fault and must never read as one.
  ///
  /// `existingFileUnreadable` is the important sentence here. It stands between a temporary read
  /// failure and a saved empty list overwriting snippets that still exist, so it tells the user
  /// their snippets ARE still there rather than implying they are gone.
  static func message(for error: SnippetStoreError) -> String {
    switch error {
    case .existingFileUnreadable:
      return
        "Your saved snippets could not be read, so nothing was changed. They are still on disk. Restart EnviousWispr, and tell us if it keeps happening."
    case .busy:
      return "Another copy of EnviousWispr is editing snippets right now. Try that again."
    case .coordinationUnavailable:
      return "Snippets could not be saved just now. Try that again."
    case .writeFailed(let reason):
      return "That could not be saved. \(reason)"
    case .listChangedDuringReview:
      // Reached only if an import's stale refusal ever surfaces as a message; `commitImport`
      // maps it to `.stale` and the sheet recompares instead of showing this.
      return
        "Your snippets changed while you were reviewing. Nothing was imported. Review the updated list and try again."
    }
  }

  // MARK: - Import

  /// A reviewed import, ready to write (#2997): the list the review was built against and the
  /// snippets the user approved, minted with fresh ids, in review order.
  struct SnippetImportCommitPlan: Sendable, Equatable {
    let baseline: [Snippet]
    let additions: [Snippet]

    /// True when the commit would change nothing. Such a commit takes no lock and writes no
    /// file; the flow model already refuses to reach here for it.
    var isEmpty: Bool { additions.isEmpty }
  }

  /// Why a commit failed, typed so the sheet can classify it for telemetry and still render
  /// the coordinator's own sentence.
  enum SnippetImportCommitError: Sendable, Equatable {
    case validation(SnippetValidationError)
    case store(SnippetStoreError)
    case other(String)

    @MainActor var message: String {
      switch self {
      case .validation(let error): return SnippetsCoordinator.message(for: error)
      case .store(let error): return SnippetsCoordinator.message(for: error)
      case .other(let description): return "That could not be saved. \(description)"
      }
    }
  }

  /// Outcome of a reviewed import. `.stale` is not a failure the user caused: the list changed
  /// while Review was open, so the sheet recompares against the current list instead.
  enum SnippetImportCommitOutcome: Sendable, Equatable {
    case committed(SnippetImportReceipt)
    case stale
    case failed(SnippetImportCommitError)
  }

  /// Write a reviewed import in one atomic store write, then publish what is on disk.
  ///
  /// The store call runs off the main actor: the lock wait, the validation of up to 5,000
  /// snippets and the fsync would otherwise freeze the settings window. What gets PUBLISHED
  /// afterwards is the disk state, not the receipt: between the store call returning and the
  /// main actor resuming, an edit sheet can save and publish a newer list, and adopting the
  /// older receipt over it would publish stale state. The lock serialises the two writes;
  /// reading disk at publication time serialises the two publications in the same order
  /// (`apply` mutates and publishes synchronously on the main actor, so a reload-and-adopt
  /// cannot interleave with an edit).
  ///
  /// Never assigns `errorMessage`: an import failure is shown by the sheet's result screen,
  /// not in the page's save-error slot (`SnippetsView` records why the export message is kept
  /// out of that slot; the same reason applies). Once the store call has started, nothing
  /// rolls it back; the sheet's own generation only decides whether the result is shown.
  func commitImport(_ plan: SnippetImportCommitPlan) async -> SnippetImportCommitOutcome {
    // An empty plan publishes nothing: no disk re-read and no `adopt`, so the drivers are not
    // re-seeded with a list that did not change.
    guard !plan.isEmpty else {
      return .committed(SnippetImportReceipt(
        vocabulary: SnippetVocabulary(
          snippets: plan.baseline, keyword: keyword, generation: vocabulary.generation),
        addedIDs: []))
    }
    do {
      let receipt = try await Self.write(plan, to: manager)
      importWriteDidReturn?()
      publishAfterImport(receipt)
      return .committed(receipt)
    } catch SnippetStoreError.listChangedDuringReview {
      // Nothing was written. The sheet re-reads the list from disk itself (its
      // `existingSnippets` dependency is `refreshFromDisk`), so no adopt happens here.
      return .stale
    } catch let error as SnippetValidationError {
      return .failed(.validation(error))
    } catch let error as SnippetStoreError {
      return .failed(.store(error))
    } catch {
      return .failed(.other(error.localizedDescription))
    }
  }

  /// `@concurrent` is load-bearing: entering it leaves the main actor for the lock wait,
  /// validation and fsync. `SnippetsManager` is `@unchecked Sendable` by design.
  @concurrent private static func write(
    _ plan: SnippetImportCommitPlan, to manager: SnippetsManager
  ) async throws -> SnippetImportReceipt {
    try manager.importSnippets(plan.additions, reviewedAgainst: plan.baseline)
  }

  /// Publish the DISK state after an import, never `.empty`.
  ///
  /// `loadedVocabulary()` is nil when the file is unreadable right after our own write, or was
  /// archived. `load()` would answer empty there, and publishing empty would silently switch
  /// every snippet off for the session. On nil the generations decide: the same manager mints
  /// them monotonically on every save, so a published generation ABOVE the receipt's means a
  /// later edit has already been published and is kept; otherwise the receipt is adopted.
  private func publishAfterImport(_ receipt: SnippetImportReceipt) {
    if let onDisk = manager.loadedVocabulary() {
      adopt(onDisk)
    } else if vocabulary.generation <= receipt.vocabulary.generation {
      adopt(receipt.vocabulary)
    }
  }

  /// Re-read the store and adopt what is on disk.
  ///
  /// For the export, which asks the user for a destination first: another EnviousWispr process
  /// can change the store while that panel is open, and a backup written from the pre-panel
  /// snapshot would omit or resurrect snippets without saying so. And for the import's review
  /// (#2997), which compares against what another process may have written.
  ///
  /// An UNREADABLE file adopts nothing and returns the list already published: `load()` reads
  /// that file as empty, and publishing empty would switch every snippet off for the session
  /// while the snippets still sit on disk. The import then fails at the store with the
  /// unreadable sentence; the export writes the list it already had.
  @discardableResult
  func refreshFromDisk() -> SnippetVocabulary {
    guard let onDisk = manager.refreshedVocabulary() else { return vocabulary }
    return adopt(onDisk)
  }

  /// Adopt a vocabulary and publish it. THE ONLY writer of `vocabulary`.
  ///
  /// `apply` below already carried a comment saying the adopt-and-publish pair must never be
  /// done by one caller and forgotten by the next — and then `refreshFromDisk` was added and
  /// forgot the publish, leaving the settings screen showing one list while both dictation
  /// drivers still held the previous one. A comment asking callers to remember is not a
  /// mechanism; a single private writer is. Nothing else in this type assigns `vocabulary`.
  @discardableResult
  private func adopt(_ updated: SnippetVocabulary) -> SnippetVocabulary {
    vocabulary = updated
    onVocabularyChanged?(updated)
    return updated
  }

  /// True when a file exists that could not be read. The screen shows this instead of an empty
  /// list, because an empty list is a lie the user would act on by adding snippets over the top.
  var storeUnreadable: Bool { manager.unreadableExisting }
}
