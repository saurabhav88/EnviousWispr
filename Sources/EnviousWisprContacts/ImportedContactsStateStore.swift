import Foundation

/// On-disk record of what the contacts import created.
///
/// Two jobs: (1) `importedContactIDs` lets a re-scan skip contacts already
/// imported (idempotent re-import); (2) `importedWordIDs` is the exact set the
/// bulk-remove pill deletes. **Opaque IDs only — never a name string.** That is
/// the privacy invariant the `check-contacts-data-flow.sh` hook enforces.
///
/// Net-new file: an absent file decodes as `.empty` (no prior import). Decode is
/// forward-compatible (`decodeIfPresent`); unknown future keys are ignored.
public struct ImportedContactsState: Codable, Sendable, Equatable {
  public var version: Int
  public var lastImportedAt: Date?
  public var importedContactIDs: [String]
  public var importedWordIDs: [UUID]

  public init(
    version: Int = 1,
    lastImportedAt: Date? = nil,
    importedContactIDs: [String] = [],
    importedWordIDs: [UUID] = []
  ) {
    self.version = version
    self.lastImportedAt = lastImportedAt
    self.importedContactIDs = importedContactIDs
    self.importedWordIDs = importedWordIDs
  }

  public static let empty = ImportedContactsState()

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
    self.lastImportedAt = try c.decodeIfPresent(Date.self, forKey: .lastImportedAt)
    self.importedContactIDs =
      try c.decodeIfPresent([String].self, forKey: .importedContactIDs) ?? []
    self.importedWordIDs =
      try c.decodeIfPresent([UUID].self, forKey: .importedWordIDs) ?? []
  }

  /// Merge a fresh import into this state: union new contact + word IDs
  /// (insertion-order preserving, deduped) and stamp the timestamp.
  public mutating func record(contactIDs: [String], wordIDs: [UUID], at date: Date) {
    var seenContacts = Set(importedContactIDs)
    for id in contactIDs where seenContacts.insert(id).inserted {
      importedContactIDs.append(id)
    }
    var seenWords = Set(importedWordIDs)
    for id in wordIDs where seenWords.insert(id).inserted {
      importedWordIDs.append(id)
    }
    lastImportedAt = date
  }
}

/// Loads/saves `imported-contacts-state.json` in the EnviousWispr Application
/// Support directory, mirroring `CustomWordsManager`'s file hardening (0700 dir
/// with a Spotlight-exclusion marker, 0600 atomic file write).
public struct ImportedContactsStateStore: Sendable {
  private let fileURL: URL

  public init() {
    if let baseURL = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first {
      let appSupport = baseURL.appendingPathComponent("EnviousWispr", isDirectory: true)
      Self.prepareDirectory(at: appSupport)
      self.fileURL = appSupport.appendingPathComponent("imported-contacts-state.json")
    } else {
      let fallback = FileManager.default.temporaryDirectory.appendingPathComponent(
        "EnviousWispr", isDirectory: true)
      Self.prepareDirectory(at: fallback)
      self.fileURL = fallback.appendingPathComponent("imported-contacts-state.json")
    }
    Self.tightenFileIfPresent(at: fileURL)
  }

  /// Test seam: inject an explicit file URL so unit tests hit a per-test temp
  /// file instead of the production path. Production uses the zero-arg `init()`.
  // periphery:ignore - test seam
  package init(fileURL: URL) {
    self.fileURL = fileURL
    Self.prepareDirectory(at: fileURL.deletingLastPathComponent())
    Self.tightenFileIfPresent(at: fileURL)
  }

  /// Absent or unreadable file → `.empty` (treated as no prior import).
  public func load() -> ImportedContactsState {
    guard FileManager.default.fileExists(atPath: fileURL.path),
      let data = try? Data(contentsOf: fileURL),
      let state = try? JSONDecoder().decode(ImportedContactsState.self, from: data)
    else { return .empty }
    return state
  }

  public func save(_ state: ImportedContactsState) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(state)
    let tmpURL = fileURL.deletingLastPathComponent().appendingPathComponent(
      ".imported-contacts-state.json.tmp")
    let fm = FileManager.default
    do {
      let fd = Foundation.open(tmpURL.path, O_CREAT | O_WRONLY | O_TRUNC, 0o600)
      guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
      let fh = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
      try fh.write(contentsOf: data)
      try fh.close()
      if fm.fileExists(atPath: fileURL.path) {
        _ = try fm.replaceItemAt(fileURL, withItemAt: tmpURL)
      } else {
        try fm.moveItem(at: tmpURL, to: fileURL)
      }
    } catch {
      try? fm.removeItem(at: tmpURL)
      throw error
    }
  }

  private static func prepareDirectory(at url: URL) {
    let fm = FileManager.default
    try? fm.createDirectory(at: url, withIntermediateDirectories: true)
    try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    let marker = url.appendingPathComponent(".metadata_never_index")
    if !fm.fileExists(atPath: marker.path) {
      fm.createFile(atPath: marker.path, contents: Data(), attributes: nil)
    }
  }

  private static func tightenFileIfPresent(at url: URL) {
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.path) else { return }
    try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}
