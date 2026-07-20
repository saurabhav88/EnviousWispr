import Foundation

/// Writes a backup file to a destination the user chose (#1680, PR-E1).
///
/// Same guards as `CustomWordsManager.saveFile` — unique temp filename,
/// exclusive create, mode 0600, atomic publish, cleanup on failure.
///
/// This file used to claim the live `custom-words.json` "has exactly one
/// writer, so a fixed `.tmp` sibling is safe there," and that sentence is why
/// the manager kept the weaker shape. It is not true: two running instances
/// are two writers, and a shared temp name plus `O_TRUNC` let one silently
/// overwrite the other's partial bytes, publishing whichever landed last as
/// the user's whole library (#1690). Both writers now use the same guards,
/// because the reason for them was never the destination.
package enum CustomWordsExportWriter {
  /// `@concurrent` so this always runs OFF the caller's actor (code review r5).
  /// The caller is a SwiftUI button action on the main actor, and a plain
  /// `async` here would inherit that isolation — an export to a network,
  /// cloud-synced, or external destination would then block the settings
  /// window until the filesystem finished. It also makes the cancellation
  /// check below meaningful, which it could not be in a synchronous call.
  @concurrent package static func write(
    _ data: Data, to destination: URL
  ) async throws {
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
