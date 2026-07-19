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
      // The WHOLE preflight runs off-main, not just the encode. Moving only
      // the encode left a pass that mints a candidate per word and validates
      // every word and alias running on the main actor — at the ceiling that
      // is still enough to freeze the settings window (Codex review, #1683).
      let (encoded, refusal) = try await Self.encodedAndChecked(document)
      if let refusal { return .failed(message: refusal) }
      try await write(encoded, destination)
      return .exported
    } catch {
      return .failed(message: error.localizedDescription)
    }
  }

  @concurrent private static func encodedAndChecked(
    _ document: CustomWordsTransferDocument
  ) async throws -> (Data, String?) {
    let encoded = try document.encoded()
    return (encoded, refusalIfUnimportable(document: document, encoded: encoded))
  }

  /// Asks the IMPORTER whether it can read these bytes, rather than keeping a
  /// second list of what "importable" means.
  ///
  /// Five separate review rounds found the same defect here: a constraint
  /// added to import and not to export (word ceiling, then byte ceiling, then
  /// character policy, then stored-surface ceiling). Every fix was a promise
  /// to remember the other side next time, and every next time forgot. So the
  /// preflight no longer describes importability at all — it runs the actual
  /// import path over the actual bytes. A ceiling added to the parser from now
  /// on is enforced here the moment it exists, with nothing to keep in sync.
  nonisolated static func refusalIfUnimportable(
    document: CustomWordsTransferDocument, encoded: Data
  ) -> String? {
    // The byte ceiling belongs to the READER, not the parser, so it is the one
    // check that has to be stated here. It mirrors FileImportSource.
    if encoded.count > CustomWordsImportLimits.maximumExportedFileBytes {
      return
        "Your words are too large to fit in one file EnviousWispr could read "
        + "back. Nothing was exported."
    }
    do {
      let candidates = try ExportedWordsFileParser().parse(data: encoded)
      _ = try CustomWordsImportBatch(
        sourceID: "exported-words",
        sourceDisplayName: "EnviousWispr words file",
        candidates: candidates
      ).validated()
      return nil
    } catch {
      return "\(error.localizedDescription) Nothing was exported."
    }
  }
}
