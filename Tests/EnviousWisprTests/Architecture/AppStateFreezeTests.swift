import Foundation
import Testing

/// PR-C.4 of #763 — the terminal guard of the AppState deletion epic.
///
/// `AppState` was the original god object. The epic carved its responsibilities
/// into named homes across 13 PRs and deleted the file outright. This suite
/// blocks its return: the file must not exist, and no source or test file may
/// reference the type by name. A future contributor cannot re-add a stored
/// property or re-inject `@Environment(...)` without this suite failing first.
///
/// Scope (Codex grounded review G-7, issue #777): `Sources/**/*.swift` must
/// contain no whole-word `AppState`; `Tests/**/*.swift` may contain it only in
/// this file. Documentation under `.claude/` and `docs/` is out of scope —
/// historical references there are corrected separately.
@Suite struct AppStateFreezeTests {
  /// Whole-word match so `WhisperKitPipelineState` / `EnviousWisprApp` etc. do
  /// not false-positive.
  private static let tokenPattern = #"\bAppState\b"#

  /// #919: the app-shell code moved from the app target into EnviousWisprAppKit,
  /// so guard BOTH the old shell location and the new kit location — AppState
  /// must not reappear in either.
  private static let appStateRelativePaths = [
    "Sources/EnviousWispr/App/AppState.swift",
    "Sources/EnviousWisprAppKit/App/AppState.swift",
  ]

  @Test func appStateFileDoesNotExist() {
    for relativePath in Self.appStateRelativePaths {
      let url = repoRoot().appending(path: relativePath)
      #expect(
        !FileManager.default.fileExists(atPath: url.path),
        """
        AppState.swift must stay deleted (epic #763), checked at \(relativePath). \
        State belongs in the named domain home.
        """)
    }
  }

  @Test func noSourceReferencesAppState() throws {
    let offenders = try referencingFiles(under: "Sources", allowing: [])
    #expect(
      offenders.isEmpty,
      """
      Source files reference the deleted `AppState` type:
      \(offenders.joined(separator: "\n"))
      AppState is gone (epic #763). Reference the specific named home instead.
      """)
  }

  @Test func noTestReferencesAppState() throws {
    let offenders = try referencingFiles(
      under: "Tests", allowing: ["AppStateFreezeTests.swift"])
    #expect(
      offenders.isEmpty,
      """
      Test files reference the deleted `AppState` type:
      \(offenders.joined(separator: "\n"))
      AppState is gone (epic #763). Re-point the test at the real source.
      """)
  }

  // MARK: - Helpers

  /// Repo root, anchored off `#filePath` (cwd-independent in CI).
  /// This file lives at `Tests/EnviousWisprTests/Architecture/` — three levels
  /// below the root.
  private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  /// Returns `"path:line: text"` for every line under `directory` that contains
  /// a whole-word `AppState`, skipping files whose name is in `allowing`.
  private func referencingFiles(
    under directory: String, allowing: Set<String>
  ) throws -> [String] {
    let regex = try NSRegularExpression(pattern: Self.tokenPattern)
    let root = repoRoot().appending(path: directory)
    guard
      let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: nil)
    else { return [] }

    var offenders: [String] = []
    for case let url as URL in enumerator {
      guard url.pathExtension == "swift" else { continue }
      guard !allowing.contains(url.lastPathComponent) else { continue }
      let source = try String(contentsOf: url, encoding: .utf8)
      for (idx, line) in source.split(
        separator: "\n", omittingEmptySubsequences: false
      ).enumerated() {
        let text = String(line)
        let ns = text as NSString
        if regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))
          != nil
        {
          offenders.append(
            "\(directory)/\(url.lastPathComponent):\(idx + 1): "
              + text.trimmingCharacters(in: .whitespaces))
        }
      }
    }
    return offenders.sorted()
  }
}
