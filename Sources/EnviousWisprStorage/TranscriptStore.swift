import EnviousWisprCore
import Foundation

/// Persists transcripts as JSON files in Application Support.
///
/// Privacy posture (V3 audit #561 / #562):
/// - Directory created at 0700 (owner-only access). Re-enforced at every init
///   in case a backup restore or user action loosened permissions.
/// - Each file written at 0600 by setting POSIX permissions immediately after
///   the atomic write succeeds.
/// - `.metadata_never_index` marker dropped at directory creation so Spotlight
///   does not index transcript text.
@MainActor
public final class TranscriptStore {
  private let directory: URL

  public init() {
    directory = AppConstants.appSupportURL
      .appendingPathComponent(AppConstants.transcriptsDir, isDirectory: true)
    Self.prepareDirectory(at: directory)
    Self.scheduleMigration(in: directory)
  }

  // Tests only. Reached via `@testable import EnviousWisprStorage`.
  // Production uses the default `init()` so the store always points at
  // `AppConstants.appSupportURL/transcripts`. Keeping this `internal`
  // means a production call site cannot mis-point the store. Periphery
  // scans `--exclude-tests` so this init appears unused from production;
  // the annotation suppresses that false positive.
  // periphery:ignore
  internal init(directory: URL) {
    self.directory = directory
    Self.prepareDirectory(at: directory)
    Self.scheduleMigration(in: directory)
  }

  /// Save a transcript to disk at 0600.
  ///
  /// Writes to a temp file at 0600 first via `Foundation.open(... 0o600)`
  /// then renames into place. Mirrors the pattern in `KeychainManager.store`
  /// and avoids the brief world-readable window that `Data.write(.atomic)`
  /// + post-write chmod creates.
  public func save(_ transcript: Transcript) throws {
    let filename = "\(transcript.id.uuidString).json"
    let url = directory.appendingPathComponent(filename)
    let data = try JSONEncoder().encode(transcript)
    let tmpURL = directory.appendingPathComponent(".\(transcript.id.uuidString).tmp")
    let fm = FileManager.default
    do {
      let fd = Foundation.open(tmpURL.path, O_CREAT | O_WRONLY | O_TRUNC, 0o600)
      guard fd >= 0 else {
        throw CocoaError(.fileWriteUnknown)
      }
      let fh = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
      try fh.write(contentsOf: data)
      try fh.close()
      if fm.fileExists(atPath: url.path) {
        _ = try fm.replaceItemAt(url, withItemAt: tmpURL)
      } else {
        try fm.moveItem(at: tmpURL, to: url)
      }
    } catch {
      try? fm.removeItem(at: tmpURL)
      throw error
    }
  }

  /// Create the directory at 0700, drop a `.metadata_never_index` Spotlight
  /// marker, and re-enforce permissions on every call. Soft-fails on any
  /// filesystem operation — better to lose a privacy guarantee than crash.
  private static func prepareDirectory(at directory: URL) {
    let fm = FileManager.default
    try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    try? fm.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: directory.path
    )
    let marker = directory.appendingPathComponent(".metadata_never_index")
    if !fm.fileExists(atPath: marker.path) {
      fm.createFile(atPath: marker.path, contents: Data(), attributes: nil)
    }
  }

  /// Walk existing files and force them to 0600. Migrates installs that
  /// pre-date this hardening so a user with months of old transcripts is
  /// not left with world-readable files until each is rewritten.
  ///
  /// Dispatched off the main actor so an install with thousands of
  /// transcripts (founder's machine has 6,300+) does not stutter the UI
  /// at app launch. Each setAttributes call is fast individually, but the
  /// loop adds up.
  private static func scheduleMigration(in directory: URL) {
    Task.detached(priority: .utility) {
      let fm = FileManager.default
      guard let entries = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
      for entry in entries where entry.hasSuffix(".json") {
        let path = directory.appendingPathComponent(entry).path
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
      }
    }
  }

  /// Load all transcripts, sorted by creation date (newest first).
  /// Heavy file IO is performed on a background thread to keep UI responsive.
  public func loadAll() async throws -> [Transcript] {
    let dir = directory
    guard FileManager.default.fileExists(atPath: dir.path) else { return [] }

    // Move heavy IO to background thread
    let transcripts: [Transcript] = try await Task.detached(priority: .userInitiated) {
      let files = try FileManager.default.contentsOfDirectory(
        at: dir,
        includingPropertiesForKeys: nil
      )

      let decoder = JSONDecoder()
      var result: [Transcript] = []
      for url in files where url.pathExtension == "json" {
        do {
          let data = try Data(contentsOf: url)
          let transcript = try decoder.decode(Transcript.self, from: data)
          result.append(transcript)
        } catch {
          // Log errors but don't block — corrupt files are skipped
          await AppLogger.shared.log(
            "Skipping corrupt transcript \(url.lastPathComponent): \(error)",
            level: .info, category: "TranscriptStore"
          )
        }
      }
      return result.sorted { $0.createdAt > $1.createdAt }
    }.value

    return transcripts
  }

  /// Delete a transcript by ID.
  public func delete(id: UUID) throws {
    let url = directory.appendingPathComponent("\(id.uuidString).json")
    do {
      try FileManager.default.removeItem(at: url)
    } catch let error as CocoaError where error.code == .fileNoSuchFile {
      return
    }
  }

  /// Delete all transcripts from disk atomically.
  /// Removes and recreates the directory with the same hardened permissions
  /// + Spotlight marker established at init.
  public func deleteAll() throws {
    guard FileManager.default.fileExists(atPath: directory.path) else { return }
    try FileManager.default.removeItem(at: directory)
    Self.prepareDirectory(at: directory)
  }
}
