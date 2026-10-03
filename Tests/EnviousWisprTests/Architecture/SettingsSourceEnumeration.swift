import Foundation

/// One test-owned population for the Settings source guards (#3385).
/// Recursive discovery keeps a file move from silently removing guard subjects.
/// Read failures are errors, never an empty source list or a partial green scan.
enum SettingsSourceEnumeration {
  static let relativeDirectory = "Sources/EnviousWisprAppKit/Views/Settings"
  static let expectedFiles: Set<String> = [
    "LanguageLockOptions.swift", "LivePreviewSettingsView.swift",
    "SettingsComponents.swift", "DictationSettingsView.swift",
    "SpeechEngineSettingsView.swift", "AudioSettingsView.swift",
    "ClipboardSettingsView.swift", "TranscribeFileView.swift",
  ]

  enum Failure: Error, Equatable {
    case missingRoot(String)
    case unreadableDirectory(String)
    case cannotEnumerate(String)
    case outsideRoot(String)
    case noSubjects
    case missingExpectedFiles([String])
  }

  /// Defaults resolve through the canonical, CWD-independent `RepoRoot`.
  /// Fixture roots use the same POSIX realpath rule so `/tmp` cannot corrupt
  /// repo-relative offender paths when Foundation enumerates `/private/tmp`.
  static func sources(
    repoRoot: URL = RepoRoot.url,
    requiredFiles: Set<String> = expectedFiles
  ) throws -> [(path: String, text: String)] {
    var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
    guard realpath(repoRoot.path, &buffer) != nil else {
      throw Failure.missingRoot(repoRoot.path)
    }
    let root = URL(fileURLWithPath: String(cString: buffer))
    let directory = root.appending(path: relativeDirectory)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { throw Failure.missingRoot(directory.path) }
    try requireReadableDirectory(directory)

    var enumerationError: Error?
    guard let enumerator = FileManager.default.enumerator(
      at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
      options: [], errorHandler: { _, error in
        enumerationError = error
        return false
      })
    else { throw Failure.cannotEnumerate(directory.path) }

    let prefix = root.path + "/"
    var files: [(path: String, text: String)] = []
    for case let url as URL in enumerator {
      let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
      if values.isDirectory == true {
        try requireReadableDirectory(url)
      } else if url.pathExtension == "swift", values.isRegularFile == true {
        guard url.path.hasPrefix(prefix) else { throw Failure.outsideRoot(url.path) }
        files.append((
          String(url.path.dropFirst(prefix.count)),
          try String(contentsOf: url, encoding: .utf8)))
      }
    }
    if let enumerationError { throw enumerationError }
    guard files.isEmpty == false else { throw Failure.noSubjects }
    let found = Set(files.map { String($0.path.dropFirst(relativeDirectory.count + 1)) })
    let missing = requiredFiles.subtracting(found).sorted()
    guard missing.isEmpty else { throw Failure.missingExpectedFiles(missing) }
    return files.sorted { $0.path < $1.path }
  }

  private static func requireReadableDirectory(_ url: URL) throws {
    guard FileManager.default.isReadableFile(atPath: url.path),
      FileManager.default.isExecutableFile(atPath: url.path)
    else { throw Failure.unreadableDirectory(url.path) }
  }
}
