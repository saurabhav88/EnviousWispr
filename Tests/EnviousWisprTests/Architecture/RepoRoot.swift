import Foundation

/// Resolves the repository root from this file's compile-time location
/// (`#filePath`), so source-reading freeze / ceiling tests work regardless of
/// the process working directory.
///
/// The old SwiftPM test runner executed from the repo root, so a bare
/// `URL(fileURLWithPath: "Sources/...")` resolved correctly. `xcodebuild test`
/// runs with the working directory at `/` (#913 PR3), so those CWD-relative
/// reads fail. Every source-reading test resolves its repo-relative path
/// through here instead, making the reads CWD-independent.
enum RepoRoot {
  /// Walks up from this file's directory until it finds `Package.swift`,
  /// instead of trimming a fixed number of path components. `/tmp` is a
  /// symlink to `/private/tmp` on macOS, which perturbs a fixed-depth trim's
  /// component count for a checkout there and produced 6 false freeze-test
  /// failures (#1675).
  static let url: URL = resolve()

  private static func resolve() -> URL {
    var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<32 {
      if FileManager.default.fileExists(
        atPath: candidate.appending(path: "Package.swift").path)
      {
        return candidate
      }
      let parent = candidate.deletingLastPathComponent()
      precondition(
        parent.path != candidate.path,
        "RepoRoot: reached the filesystem root without finding Package.swift, starting from \(#filePath)"
      )
      candidate = parent
    }
    preconditionFailure(
      "RepoRoot: no Package.swift found within 32 parent directories of \(#filePath)")
  }

  /// Absolute URL for a repo-relative source path (e.g.
  /// `"Sources/EnviousWisprAppKit/App/AppDelegate.swift"`). An already-absolute path
  /// is returned unchanged, so callers that pass an absolute path (or this
  /// helper applied twice) resolve identically.
  static func sourceURL(_ relativePath: String) -> URL {
    relativePath.hasPrefix("/")
      ? URL(fileURLWithPath: relativePath)
      : url.appending(path: relativePath)
  }
}
