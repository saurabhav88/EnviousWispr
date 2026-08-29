import EnviousWisprCore
import Foundation
import os

/// A per-word change from a pack's shipped default (#2495): the word turned
/// off, its aliases edited, or both. `nil` fields mean "unchanged from
/// shipped" — a word nobody has touched has no entry in the file at all, so
/// this store only ever holds what a person actually changed.
package struct VocabularyPackWordOverride: Codable, Sendable, Equatable {
  /// `false` = the word is turned off. Absent (`nil`) = enabled, the shipped
  /// default. Never `true` explicitly — an enabled, otherwise-untouched word
  /// has no reason to carry an override at all.
  package var isEnabled: Bool?
  /// The full replacement alias list, or `nil` if aliases are unchanged from
  /// the shipped pack. A full replacement (not an add/remove delta) because
  /// the editor already works with the complete list, and a delta would need
  /// its own conflict rules if the shipped pack's aliases ever change under it.
  package var aliases: [String]?

  package init(isEnabled: Bool? = nil, aliases: [String]? = nil) {
    self.isEnabled = isEnabled
    self.aliases = aliases
  }

  /// True once either field has a real value — an override that reduces to
  /// "isEnabled: nil, aliases: nil" carries no information and should have
  /// been removed instead of kept.
  package var isEmpty: Bool { isEnabled == nil && aliases == nil }
}

/// Sparse per-pack, per-word overrides, keyed by pack id then the word's
/// lowercased canonical spelling (stable across relaunches; a pack's terms
/// are keyed the same way pack term identity already works in
/// `VocabularyPackStore.deterministicID`, so this file and that seed use the
/// same two-part key without needing to share a type).
package struct VocabularyPackOverridesFile: Codable, Sendable {
  package var version: Int
  package var packs: [String: [String: VocabularyPackWordOverride]]

  package init(version: Int, packs: [String: [String: VocabularyPackWordOverride]]) {
    self.version = version
    self.packs = packs
  }

  package static let empty = VocabularyPackOverridesFile(version: 1, packs: [:])
}

/// Persists per-word edits to vocabulary packs (#2495): turning a pack word
/// off, editing its aliases, and restoring it to the shipped default.
///
/// **Every running EnviousWispr app process constructs its own
/// `VocabularyPackManager`, and every process resolves the same Application
/// Support file** (dev and production builds can run side by side, and even
/// two dev worktrees share it) — so this is NOT single-writer the way an
/// earlier version of this file claimed. What it does NOT need is
/// `CustomWordsManager`'s corruption-recovery machinery, which exists for a
/// different reason (that file survives a damaged/undecodable disk copy by
/// archiving it aside); this store's fail-open-to-empty on a bad read already
/// covers that case just as safely, because losing an override is recoverable
/// (re-edit the word) in a way losing the user's own word list is not.
///
/// What contention DOES require: every mutation goes through `update(_:)`,
/// which takes an exclusive `flock` on a companion lock file, then performs
/// ONE load-transform-save transaction — never a bare `save()` built from a
/// snapshot some other process could have already invalidated. `flock` is
/// process-exclusive but not currently reentrant-safe within one process;
/// `VocabularyPackManager` only ever calls it from the main actor, so that
/// does not arise here. The ASR XPC service does not read or write this file.
package final class VocabularyPackOverridesStore: Sendable {
  private let fileURL: URL
  private static let logger = Logger(
    subsystem: "com.enviouswispr", category: "VocabularyPackOverridesStore")

  nonisolated package static var liveFileURL: URL? {
    FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appendingPathComponent("EnviousWispr", isDirectory: true)
      .appendingPathComponent("vocabulary-pack-overrides.json")
  }

  package init() {
    guard let url = Self.liveFileURL else {
      // Application Support is always available on macOS; fall back defensively.
      let fallback = FileManager.default.temporaryDirectory
        .appendingPathComponent("EnviousWispr", isDirectory: true)
        .appendingPathComponent("vocabulary-pack-overrides.json")
      Self.prepareDirectory(at: fallback.deletingLastPathComponent())
      self.fileURL = fallback
      return
    }
    Self.prepareDirectory(at: url.deletingLastPathComponent())
    self.fileURL = url
  }

  /// Test seam: inject an explicit file URL so unit tests hit a per-test temp
  /// file instead of the production Application Support path.
  package init(fileURL: URL) {
    self.fileURL = fileURL
    Self.prepareDirectory(at: fileURL.deletingLastPathComponent())
  }

  private static func prepareDirectory(at url: URL) {
    let fm = FileManager.default
    try? fm.createDirectory(at: url, withIntermediateDirectories: true)
    try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
  }

  /// The full override set. Fail-open: a missing file (the common case — no
  /// pack word has ever been edited) or an unreadable/corrupt one both read
  /// as empty, never thrown. Safe to call without the lock — a mutation
  /// always re-reads under `update(_:)`, so a caller reading here for
  /// DISPLAY only ever sees a slightly-stale snapshot, never a torn one
  /// (`save` replaces atomically).
  package func load() -> VocabularyPackOverridesFile {
    guard let data = try? Data(contentsOf: fileURL) else { return .empty }
    guard let file = try? JSONDecoder().decode(VocabularyPackOverridesFile.self, from: data)
    else {
      Self.logger.error("Vocabulary pack overrides file was unreadable; treating as empty")
      return .empty
    }
    return file
  }

  /// Locked load-transform-save: the only way this store is ever mutated.
  /// `transform` reads the CURRENT on-disk file (not a caller-held snapshot
  /// from before the lock), mutates it in place, and returns whether
  /// anything actually changed — `false` skips the write entirely, so a
  /// no-op mutation (e.g. restoring a word that was never edited) never
  /// touches disk. Returns the saved file on success, `nil` if the lock
  /// could not be taken or the write failed — the caller must treat `nil` as
  /// "nothing changed," never as "the old value is still correct," since a
  /// concurrent writer may have changed the file just before this call.
  package func update(
    _ transform: (inout VocabularyPackOverridesFile) -> Bool
  ) -> VocabularyPackOverridesFile? {
    let lockURL = fileURL.appendingPathExtension("lock")
    let fd = lockURL.path.withCString { open($0, O_RDWR | O_CREAT | O_CLOEXEC, 0o600) }
    guard fd >= 0 else {
      Self.logger.error("Vocabulary pack overrides lock file could not be opened")
      return nil
    }
    defer { close(fd) }
    guard flock(fd, LOCK_EX) == 0 else {
      Self.logger.error("Vocabulary pack overrides file lock failed")
      return nil
    }
    defer { _ = flock(fd, LOCK_UN) }

    var file = load()
    guard transform(&file) else { return file }
    guard saveWhileLocked(file) else { return nil }
    return file
  }

  /// Atomic replace: write to a sibling temp file, then rename over the live
  /// one. A crash mid-write leaves the OLD file intact rather than a
  /// half-written one. Callers MUST already hold the lock from `update(_:)`
  /// — this is not exposed on its own, so a mutation can never bypass the
  /// load-transform-save transaction.
  private func saveWhileLocked(_ file: VocabularyPackOverridesFile) -> Bool {
    guard let data = try? JSONEncoder().encode(file) else { return false }
    let tempURL = fileURL.appendingPathExtension("tmp-\(UUID().uuidString)")
    do {
      try data.write(to: tempURL, options: .atomic)
      // `replaceItemAt` requires an existing destination — the FIRST word
      // anyone ever edits hits this while `fileURL` has never been created,
      // and every subsequent edit would silently fail the same way (cloud
      // review, PR #2501). `moveItem` covers that first-write case; every
      // write after it takes the atomic-replace path.
      if FileManager.default.fileExists(atPath: fileURL.path) {
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
      } else {
        try FileManager.default.moveItem(at: tempURL, to: fileURL)
      }
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
      return true
    } catch {
      Self.logger.error(
        "Vocabulary pack overrides save failed: \(error.localizedDescription, privacy: .public)")
      try? FileManager.default.removeItem(at: tempURL)
      return false
    }
  }
}
