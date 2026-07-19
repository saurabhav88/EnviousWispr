import Foundation

/// Writes a backup file to a destination the user chose (#1680, PR-E1).
///
/// Mirrors `CustomWordsManager.saveFile`'s guards — exclusive create, mode
/// 0600, atomic replace, cleanup on failure — with one deliberate difference:
/// the temp filename is **unique**, not fixed. The live `custom-words.json`
/// has exactly one writer, so a fixed `.tmp` sibling is safe there. An export
/// destination is a folder the user picked, and two exports can target it at
/// once; a shared temp name would let them overwrite each other's partial
/// bytes and produce one corrupt file.
package enum CustomWordsExportWriter {
  package static func write(_ document: CustomWordsTransferDocument, to destination: URL)
    throws
  {
    let data = try document.encoded()
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

      if fm.fileExists(atPath: destination.path) {
        _ = try fm.replaceItemAt(destination, withItemAt: tmpURL)
      } else {
        try fm.moveItem(at: tmpURL, to: destination)
      }
    } catch {
      // Best-effort cleanup. An existing destination is left untouched: the
      // replace either happened completely or not at all.
      try? fm.removeItem(at: tmpURL)
      throw error
    }
  }
}
