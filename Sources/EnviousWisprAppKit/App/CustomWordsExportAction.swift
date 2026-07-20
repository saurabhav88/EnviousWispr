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
///
/// Step 1 is why the count is passed IN rather than computed here. Grounded
/// review r2 established what a refresh actually costs: `refreshFromDiskIfPossible`
/// is not an in-memory read. It can rewrite a legacy file during migration, move
/// a corrupt file into an archive, latch session corruption state, and publish a
/// replaced library to runtime consumers. Opening Export and CANCELLING must not
/// do any of that.
///
/// #1697 read that constraint as also forbidding the count from appearing in the
/// save dialog, and put a sentence on the Your Words screen instead; #1715 moved
/// it back. The number never needed a refresh — it is derived on screen from the
/// in-memory coordinator, handed in as `proposedExportWords`, and shown in the
/// dialog the file comes out of. One filtering authority, two time-separated
/// snapshots: the proposed array owns both the number the user saw and the bytes
/// written; the refreshed array only proves nothing moved.
@MainActor
enum CustomWordsExportAction {
  enum Outcome: Equatable {
    case cancelled
    case exported
    case refusedUnsafeLibrary
    /// No words of the user's own. Not a failure — an honest empty state, and
    /// the only place a pack-only user learns why their long list is excluded.
    case nothingToExport
    /// The library changed between the count being shown and the write. Nothing
    /// was written. Neutral, not a failure: the user is told the number moved.
    case libraryChanged
    case failed(message: String)
  }

  /// The one filtering authority (#1697). Called once per snapshot, never once
  /// per consumer — a count computed by a second call is a second measurement.
  nonisolated static func exportableWords(from words: [CustomWord]) -> [CustomWord] {
    words.filter { $0.source == .user }
  }

  /// - Parameters:
  ///   - proposedExportWords: the array the visible count was rendered from.
  ///     The file is built from this exact array, so the number the user saw
  ///     and the bytes on disk cannot disagree.
  ///   - chooseDestination: returns nil when the user cancels.
  ///   - write: performs the actual file write.
  static func run(
    coordinator: CustomWordsCoordinator,
    proposedExportWords: [CustomWord],
    chooseDestination: () -> URL?,
    write: @escaping @Sendable (Data, URL) async throws -> Void
  ) async -> Outcome {
    // An empty proposal never opens a panel: a save dialog that can only make an
    // empty file is a trap. Refresh anyway — the on-screen count may be stale.
    guard !proposedExportWords.isEmpty else {
      guard coordinator.refreshFromDiskIfPossible(), coordinator.canExportCurrentWords
      else {
        return .refusedUnsafeLibrary
      }
      // Still empty after adopting disk: genuinely nothing of the user's own.
      // No longer empty: the count the user saw was wrong, so say so rather
      // than exporting a snapshot they were never shown.
      return exportableWords(from: coordinator.customWords).isEmpty
        ? .nothingToExport : .libraryChanged
    }

    // 1. Ask first. Refreshing before this made cancelling mutate state.
    guard let destination = chooseDestination() else { return .cancelled }

    // 2 + 3. Adopt what is on disk, then judge whether it may be written out.
    guard coordinator.refreshFromDiskIfPossible(), coordinator.canExportCurrentWords
    else {
      return .refusedUnsafeLibrary
    }

    // 4. Verify the list did not move while the user was picking a folder.
    //    Complete records, not just the count: a same-size edit is exactly the
    //    drift a count comparison cannot see.
    //
    //    Compare the DOCUMENTS, not the words. `CustomWord` is Hashable over
    //    every stored field including `frequencyUsed` and `lastUsed`, which the
    //    export format deliberately omits — so comparing words would refuse a
    //    perfectly valid export whenever usage counts moved. That is not a rare
    //    race: the usage counter is the app's one writer that runs with NO user
    //    action (30s debounce or 50 corrections, #1695), and the save panel sits
    //    open for exactly as long as a person takes to pick a folder. Dictating
    //    while that panel is open would eventually refuse every export.
    //
    //    The document is the export payload, so asking whether the PAYLOAD
    //    changed is the actual question, and it needs no second definition of
    //    which fields matter (Codex review r1, P2).
    let refreshedExportWords = exportableWords(from: coordinator.customWords)
    let document = CustomWordsTransferDocument(words: proposedExportWords)
    guard document == CustomWordsTransferDocument(words: refreshedExportWords) else {
      return .libraryChanged
    }

    // 6. Refuse to write a file our own importer would reject. The exporter
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
