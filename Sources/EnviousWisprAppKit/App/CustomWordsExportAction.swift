import EnviousWisprCore
import EnviousWisprPostProcessing
import Foundation

/// The export decision, lifted out of the view so it can be tested (#1680).
///
/// This exists because of a real miss: the safety guard was written as a
/// property on the coordinator and then never wired into the button, and the
/// tests could not see the difference — they exercised the property directly,
/// so they passed with the guard disconnected. Cloud review caught it.
///
/// Testing the ingredients is not testing the dish. The ORDER of these steps
/// is the whole safety property:
///   1. ask where — so cancelling touches nothing;
///   2. reload and adopt — so the snapshot is the real list, not a stale one;
///   3. refuse if the library is not safe to write out — so a corrupted-and-
///      archived library cannot export an empty file over a real one;
///   4. snapshot on the main actor, write off it.
/// Every one of those was a separately-found bug. Keeping them in a testable
/// unit means the sequence itself is covered, not just its parts.
@MainActor
enum CustomWordsExportAction {
  enum Outcome: Equatable {
    case cancelled
    case exported
    case refusedUnsafeLibrary
    case failed(message: String)
  }

  /// - Parameters:
  ///   - chooseDestination: returns nil when the user cancels.
  ///   - write: performs the actual file write.
  static func run(
    coordinator: CustomWordsCoordinator,
    chooseDestination: () -> URL?,
    write: @escaping @Sendable (CustomWordsTransferDocument, URL) async throws -> Void
  ) async -> Outcome {
    // 1. Ask first. Refreshing before this made cancelling mutate state.
    guard let destination = chooseDestination() else { return .cancelled }

    // 2 + 3. Adopt what is on disk, then judge whether it may be written out.
    guard coordinator.refreshFromDiskIfPossible(), coordinator.canExportCurrentWords
    else {
      return .refusedUnsafeLibrary
    }

    // 4. Snapshot here, synchronously, so the file reflects the moment the
    // user confirmed rather than whenever the write happened to run.
    let document = CustomWordsTransferDocument(
      words: coordinator.customWords.filter { $0.source == .user })

    // 5. Refuse to write a file our own importer would reject. The exporter
    //    and importer are one round trip, so a limit enforced on only one side
    //    is a promise the pair cannot keep: raising the IMPORT ceilings while
    //    export kept no preflight left the same "writes a file it then
    //    refuses" hole open, just from the other direction (Codex import
    //    taxonomy audit, #1683 — class C08).
    //
    //    Checked against the encoded bytes, not an estimate, because the byte
    //    ceiling is enforced on encoded bytes at read time.
    do {
      let encoded = try document.encoded()
      if let refusal = Self.refusalIfUnimportable(document: document, encoded: encoded) {
        return .failed(message: refusal)
      }
      try await write(document, destination)
      return .exported
    } catch {
      return .failed(message: error.localizedDescription)
    }
  }

  /// The one place export and import agree on what fits.
  static func refusalIfUnimportable(
    document: CustomWordsTransferDocument, encoded: Data
  ) -> String? {
    let words = document.words.count
    let wordCeiling = CustomWordsImportLimits.maximumExportedCandidates
    if words > wordCeiling {
      return
        "You have \(words) words, which is more than EnviousWispr can read back "
        + "in one file (\(wordCeiling)). Nothing was exported."
    }
    let byteCeiling = CustomWordsImportLimits.maximumExportedFileBytes
    if encoded.count > byteCeiling {
      return
        "Your words are too large to fit in one file EnviousWispr could read "
        + "back. Nothing was exported."
    }
    return nil
  }
}
