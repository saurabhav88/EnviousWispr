import Foundation
import Testing

/// #1315 (#1276 Step 3) — the terminal guard of the text-stitch deletion.
///
/// The WhisperKit incremental worker re-decoded a padded tail in isolation and
/// string-stitched it onto its running candidate — the design that structurally
/// produced the mid-phrase-duplication and wrong-ending bugs #1276 replaced
/// with the UFAL streaming architecture (#1313). This suite blocks its return:
/// the file must not exist, and no source file may reference the deleted
/// symbols by name. Mirrors `AppStateFreezeTests` (the #763 precedent).
///
/// Scope: `Sources/**/*.swift` must contain none of the tokens; `Tests/**` may
/// contain them only in this file. `.claude/` and `docs/` are out of scope.
@Suite struct WhisperKitStitchFreezeTests {
  /// Whole-word matches so e.g. `WhisperKitIncrementalSession` (the retained
  /// seam protocol) does not false-positive.
  private static let tokenPatterns = [
    #"\bWhisperKitIncrementalWorker\b"#,
    #"\bjoinWithOverlapTrim\b"#,
    #"\bselectCandidateText\b"#,
    #"\bmakeIncrementalSession\b"#,
  ]

  @Test func workerFileDoesNotExist() {
    let url = repoRoot().appending(
      path: "Sources/EnviousWisprASR/WhisperKitIncrementalWorker.swift")
    #expect(
      !FileManager.default.fileExists(atPath: url.path),
      """
      WhisperKitIncrementalWorker.swift must stay deleted (#1315). The
      streaming session (WhisperKitStreamingSession) is the incremental path;
      the clean batch decode is the fallback.
      """)
  }

  @Test func noSourceReferencesStitchSymbols() throws {
    for pattern in Self.tokenPatterns {
      let offenders = try filesReferencing(pattern: pattern, under: "Sources", allowing: [])
      #expect(
        offenders.isEmpty,
        """
        Source files reference a deleted stitch symbol (\(pattern)):
        \(offenders.joined(separator: "\n"))
        The stitch design is gone (#1315). Stream via WhisperKitStreamingSession
        or batch via the clean decode.
        """)
    }
  }

  @Test func noTestReferencesStitchSymbols() throws {
    for pattern in Self.tokenPatterns {
      let offenders = try filesReferencing(
        pattern: pattern, under: "Tests", allowing: ["WhisperKitStitchFreezeTests.swift"])
      #expect(
        offenders.isEmpty,
        """
        Test files reference a deleted stitch symbol (\(pattern)):
        \(offenders.joined(separator: "\n"))
        The stitch design is gone (#1315). Re-point the test at the streaming
        session or the batch path.
        """)
    }
  }

  // MARK: - Helpers (shape shared with AppStateFreezeTests)

  private func filesReferencing(
    pattern: String, under directory: String, allowing allowlist: [String]
  ) throws -> [String] {
    let root = repoRoot().appending(path: directory)
    let regex = try NSRegularExpression(pattern: pattern)
    var offenders: [String] = []
    let enumerator = FileManager.default.enumerator(
      at: root, includingPropertiesForKeys: nil)
    while let url = enumerator?.nextObject() as? URL {
      guard url.pathExtension == "swift" else { continue }
      guard !allowlist.contains(url.lastPathComponent) else { continue }
      let content = try String(contentsOf: url, encoding: .utf8)
      let range = NSRange(content.startIndex..., in: content)
      if regex.firstMatch(in: content, range: range) != nil {
        offenders.append(url.lastPathComponent)
      }
    }
    return offenders.sorted()
  }

  private func repoRoot() -> URL {
    // #file = .../Tests/EnviousWisprTests/Architecture/WhisperKitStitchFreezeTests.swift
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // Architecture
      .deletingLastPathComponent()  // EnviousWisprTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // repo root
  }
}
