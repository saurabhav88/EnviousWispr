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
    write: @escaping @Sendable (Data, URL) async throws -> Void
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
    //    is a promise the pair cannot keep.
    //
    //    Encoding happens OFF the main actor: at the 64 MB ceiling doing it
    //    here froze the settings window, and the writer then encoded the same
    //    document a second time. One encode, off-main, and the same bytes are
    //    both measured and written.
    do {
      let encoded = try await Self.encoded(document)
      if let refusal = Self.refusalIfUnimportable(document: document, encoded: encoded) {
        return .failed(message: refusal)
      }
      try await write(encoded, destination)
      return .exported
    } catch {
      return .failed(message: error.localizedDescription)
    }
  }

  @concurrent private static func encoded(
    _ document: CustomWordsTransferDocument
  ) async throws -> Data {
    try document.encoded()
  }

  /// The one place export and import agree on what fits — and on what is
  /// storable at all.
  ///
  /// Size was not the only way to write an unimportable file: a word or alias
  /// authored in the editor can hold a scalar the import policy refuses, so a
  /// count-and-bytes preflight still produced a file that import rejected
  /// wholesale (Codex review, #1683). It therefore runs the importer's OWN
  /// validation rather than a second description of it, which is what stops
  /// the two from drifting apart again.
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
    do {
      _ = try CustomWordsImportBatch(
        sourceID: "exported-words",
        sourceDisplayName: "EnviousWispr words file",
        candidates: try document.candidatesForImport()
      ).validated()
    } catch {
      return
        "One of your words can't be written to a file EnviousWispr could read "
        + "back (\(error.localizedDescription)) Nothing was exported."
    }
    return nil
  }
}
