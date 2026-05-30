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
  /// This file lives at `<root>/Tests/EnviousWisprTests/Architecture/RepoRoot.swift`,
  /// so four parent hops reach `<root>`.
  static let url: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // Architecture/
    .deletingLastPathComponent()  // EnviousWisprTests/
    .deletingLastPathComponent()  // Tests/
    .deletingLastPathComponent()  // <root>/

  /// Absolute URL for a repo-relative source path (e.g.
  /// `"Sources/EnviousWispr/App/AppDelegate.swift"`). An already-absolute path
  /// is returned unchanged, so callers that pass an absolute path (or this
  /// helper applied twice) resolve identically.
  static func sourceURL(_ relativePath: String) -> URL {
    relativePath.hasPrefix("/")
      ? URL(fileURLWithPath: relativePath)
      : url.appending(path: relativePath)
  }
}
