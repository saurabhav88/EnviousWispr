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

  init(manager: SnippetsManager = SnippetsManager()) {
    self.manager = manager
    vocabulary = manager.load()
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
      let updated = try mutation()
      vocabulary = updated
      errorMessage = nil
      onVocabularyChanged?(updated)
      return true
    } catch let error as SnippetValidationError {
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
    }
  }
}
