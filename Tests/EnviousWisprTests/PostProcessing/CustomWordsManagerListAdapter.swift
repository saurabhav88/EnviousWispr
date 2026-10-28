import EnviousWisprCore
import Foundation

@testable import EnviousWisprPostProcessing

/// Test-only: drives the manager's file-worker API (#4086) the way the persistence suites
/// were written, a caller-held list the call refreshes. Each call awaits the real
/// transaction on the real worker; the list is then the library that transaction
/// returned. Production code reads the receipts directly and never uses these.
extension CustomWordsManager {
  func add(word: CustomWord, to words: inout [CustomWord]) async throws {
    if let receipt = try await add(word: word) { words = receipt.value }
  }

  func add(canonical: String, to words: inout [CustomWord]) async throws {
    try await add(word: CustomWord(canonical: canonical), to: &words)
  }

  @discardableResult
  func addBatch(_ incoming: [CustomWord], to words: inout [CustomWord]) async throws -> [UUID] {
    let receipt = try await addBatch(incoming)
    words = receipt.value.words
    return receipt.value.created
  }

  func remove(id: UUID, from words: inout [CustomWord]) async throws {
    words = try await remove(id: id).value.words
  }

  func removeBatch(ids: [UUID], from words: inout [CustomWord]) async throws {
    words = try await removeBatch(ids: ids).value.words
  }

  /// An edit the way the editor sends one: the caller's list holds the word it was shown
  /// (the base), `word` is the draft. A word missing from the list is its own base.
  func update(word: CustomWord, in words: inout [CustomWord]) async throws {
    let base = words.first { $0.id == word.id } ?? word
    words = try await edit(CustomWordEditRequest(base: base, draft: word)).value.words
  }

  func applyGeneratedAliases(
    _ proposals: [GeneratedAliasProposal], to words: inout [CustomWord]
  ) async throws {
    if let merged = try await applyGeneratedAliases(proposals).value { words = merged }
  }

  @discardableResult
  func commitImport(
    _ plan: CustomWordsImportCommitPlan, to words: inout [CustomWord]
  ) async throws -> CustomWordsImportCommitReceipt {
    let receipt = try await commitImport(plan)
    if let merged = receipt.value.words { words = merged }
    return receipt.value.receipt
  }
}
