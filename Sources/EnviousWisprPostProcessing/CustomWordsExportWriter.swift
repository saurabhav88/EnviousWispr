import Foundation

/// Writes a backup file to a destination the user chose (#1680, PR-E1).
///
/// Same guards as `CustomWordsManager.saveFile` — exclusive create, mode 0600,
/// atomic publish, cleanup on failure — with one deliberate difference: the
/// temp filename is **unique**, not fixed. The live `custom-words.json` has
/// exactly one writer, so a fixed `.tmp` sibling is safe there. An export
/// destination is a folder the user picked, and two exports can target it at
/// once; a shared temp name would let them overwrite each other's partial
/// bytes and produce one corrupt file.
package enum CustomWordsExportWriter {
  /// Refusing to write onto EnviousWispr's own storage (#1686).
  package enum ExportDestinationError: LocalizedError, Sendable, Equatable {
    case wouldOverwriteLiveWords

    package var errorDescription: String? {
      "That's EnviousWispr's own words file. Choose a different name or folder, "
        + "so your saved words aren't replaced by the export."
    }
  }

  /// Whether this destination is the app's live word list.
  ///
  /// Selecting it would atomically replace the app's storage with the transfer
  /// format; the next launch would find a file it cannot parse, archive it as
  /// corrupt, and the user would have destroyed their dictionary by exporting
  /// it. Compared on resolved paths so a symlink or `..` cannot walk around it.
  package static func wouldOverwriteLiveWords(_ destination: URL) -> Bool {
    guard let live = CustomWordsManager.liveFileURL else { return false }
    return destination.resolvingSymlinksInPath().standardizedFileURL
      == live.resolvingSymlinksInPath().standardizedFileURL
  }

  /// `@concurrent` so this always runs OFF the caller's actor (code review r5).
  /// The caller is a SwiftUI button action on the main actor, and a plain
  /// `async` here would inherit that isolation — an export to a network,
  /// cloud-synced, or external destination would then block the settings
  /// window until the filesystem finished. It also makes the cancellation
  /// check below meaningful, which it could not be in a synchronous call.
  @concurrent package static func write(
    _ data: Data, to destination: URL
  ) async throws {
    // Refuse before touching anything: exporting must never be the action that
    // destroys the thing being exported (#1686).
    guard !Self.wouldOverwriteLiveWords(destination) else {
      throw ExportDestinationError.wouldOverwriteLiveWords
    }

    let fm = FileManager.default
    let tmpURL =
      destination
      .deletingLastPathComponent()
      .appendingPathComponent(".ew-export-\(UUID().uuidString).tmp")

    do {
      // Cancellation is checked before the temp file exists, so an abandoned
      // export leaves nothing behind to clean up.
      try Task.checkCancellation()

      // O_EXCL: refuse to write through an existing file at the temp path
      // rather than truncating whatever happens to be there.
      let fd = Foundation.open(tmpURL.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
      guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
      let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
      try handle.write(contentsOf: data)
      try handle.close()

      // Publish with a single `rename(2)`, which does in ONE atomic step what
      // three earlier revisions of this function each got partly wrong
      // (code reviews r1-r6):
      //
      //  - Atomic replace of an existing regular file — no check-then-act
      //    window where a second export sees "no file" and both try to move.
      //  - Refuses a directory outright (EISDIR), by the kernel, with no
      //    gap between deciding and acting. The previous fileExists-then-
      //    replace guard was correct but not atomic: a cloud-sync client that
      //    swapped the path to a directory in between could still have had it
      //    deleted along with its contents.
      //  - Keeps the temp file's own 0600 rather than inheriting a
      //    world-readable destination's mode, so a backup full of personal
      //    names cannot be published readable by everything on the machine.
      //
      // Same-directory temp file means same filesystem, which is what makes
      // rename legal here.
      guard Foundation.rename(tmpURL.path, destination.path) == 0 else {
        throw NSError(
          domain: NSPOSIXErrorDomain, code: Int(errno),
          userInfo: [
            NSLocalizedDescriptionKey: String(cString: strerror(errno)),
            NSFilePathErrorKey: destination.path,
          ])
      }
    } catch {
      // Best-effort cleanup. An existing destination is untouched unless the
      // rename succeeded, and a failed rename changes nothing at all.
      try? fm.removeItem(at: tmpURL)
      throw error
    }
  }
}
