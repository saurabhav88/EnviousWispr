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

    do {
      try await write(document, destination)
      return .exported
    } catch {
      return .failed(message: error.localizedDescription)
    }
  }
}
