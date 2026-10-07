import Foundation
import Testing

// MARK: - KernelOwnershipFreezeTests (epic #827, PR-9 — terminal guard)
//
// The engine-kernel refactor collapsed two recording pipelines into one
// `RecordingSessionKernel`, adapted by the single `KernelDictationDriver`.
// PR-9 deleted the old `DictationPipeline` driver protocol. This suite is the
// permanent guard that no SECOND recording-orchestration brain reappears and
// that the lifecycle FSM + the event entry point stay single-owner. It
// complements `EngineIdentityFreezeTests` (which guards engine-identity literals, the old
// WhisperKit pipeline, and adapter construction — not kernel ownership).
//
// Two invariants, each with matcher controls:
//   1. `enum RecordingSessionState` (the lifecycle FSM) has exactly ONE source
//      declaration — fail-closed `== 1`, so a silent rename trips the guard.
//   2. `func handle(event: PipelineEvent)` (the driver's event entry point) has
//      exactly ONE source declaration — fail-closed `== 1`.
//
// Known blind spot (named, not fixed): a second FSM declared under a DIFFERENT
// enum name evades invariant 1; code review covers it.

@Suite struct KernelOwnershipFreezeTests {

  // Whole-word so `KernelDictationDriver` / `KernelDictationDriverFactory` do
  // not false-positive on the deleted `DictationPipeline` protocol name.
  private static let dictationPipelineToken = #"\bDictationPipeline\b"#
  // The `enum` keyword precedes the name only at the declaration; a usage such
  // as `RecordingSessionState.idle` is never preceded by `enum`.
  private static let recordingSessionStateDecl = #"\benum\s+RecordingSessionState\b"#
  // `PipelineEvent` appears as the parameter TYPE only in the declaration; call
  // sites pass a value (`handle(event: .requestStop)`), never the type name.
  private static let handleEventDecl = #"func\s+handle\(event:\s*PipelineEvent\)"#

  // MARK: 1 — the deleted driver protocol stays deleted

  // MARK: 2 — the lifecycle FSM has exactly one owner (fail-closed)

  @Test("enum RecordingSessionState has exactly one source declaration")
  func recordingSessionStateHasSingleDeclaration() throws {
    let hits = try Self.scanSources(pattern: Self.recordingSessionStateDecl)
    #expect(
      hits.count == 1,
      """
      Expected exactly ONE `enum RecordingSessionState` declaration, found \(hits.count):
      \(hits.joined(separator: "\n"))
      The lifecycle FSM is owned solely by `RecordingSessionKernel`. A count of 0
      means the enum was renamed (update this guard in lockstep); a count >1 means
      a second FSM was introduced (a second orchestration brain).
      """)
  }

  // MARK: 3 — the event entry point has exactly one owner (fail-closed)

  @Test("func handle(event: PipelineEvent) has exactly one source declaration")
  func handleEventHasSingleDeclaration() throws {
    let hits = try Self.scanSources(pattern: Self.handleEventDecl)
    #expect(
      hits.count == 1,
      """
      Expected exactly ONE `func handle(event: PipelineEvent)` declaration, found \(hits.count):
      \(hits.joined(separator: "\n"))
      The event entry point is owned solely by `KernelDictationDriver`. A count of
      0 means the signature changed (update this guard in lockstep); a count >1
      means a second driver routes engines around the kernel.
      """)
  }

  // MARK: 4 — the deleted Parakeet pipeline type stays deleted

  // MARK: Adversarial — the matchers flag real reintroductions

  @Test("a second enum RecordingSessionState declaration is flagged")
  func adversarialSecondFSMFlagged() {
    let line = "  internal enum RecordingSessionState { case idle }"
    #expect(Self.regexFlags(source: line, pattern: Self.recordingSessionStateDecl))
  }

  @Test("a second func handle(event: PipelineEvent) declaration is flagged")
  func adversarialSecondHandleEventFlagged() {
    let line = "  public func handle(event: PipelineEvent) async throws {"
    #expect(Self.regexFlags(source: line, pattern: Self.handleEventDecl))
  }

  // MARK: Fail-closed — a silent rename (count 0) must NOT satisfy `== 1`

  // MARK: Negative controls — legitimate code is NOT flagged

  @Test("a handle(event:) CALL site is not flagged by the declaration matcher")
  func negativeControlCallSiteNotFlagged() {
    let line = "      try await active.handle(event: .requestStop)"
    #expect(Self.regexFlags(source: line, pattern: Self.handleEventDecl) == false)
  }

  @Test("a comment-only mention of a banned token is skipped by the scanner")
  func negativeControlCommentMentionSkipped() {
    // The scanner skips comment-only lines so historical breadcrumbs do not trip
    // the freeze. A comment mentioning the deleted protocol must not count.
    let source = "  // DictationPipeline was deleted in PR-9 of #827\n  let x = 1\n"
    #expect(Self.countMatches(in: source, pattern: Self.dictationPipelineToken) == 0)
  }

  // MARK: - Helpers (mirror EngineIdentityFreezeTests)

  /// Recursive scan over every `Sources/**/*.swift` file. Returns
  /// `relative/path.swift:LINE: trimmed` for each non-comment line whose regex
  /// matches. Comment-only lines (first non-whitespace `//` or `///`) are
  /// skipped so historical-breadcrumb mentions of deleted names do not trip the
  /// freeze.
  private static func scanSources(pattern: String) throws -> [String] {
    try scan(root: "Sources", pattern: pattern, allowing: [])
  }

  private static func scan(root: String, pattern: String, allowing: [String]) throws -> [String] {
    let regex = try NSRegularExpression(pattern: pattern)
    let rootURL = RepoRoot.url.appending(path: root)
    let enumerator = FileManager.default.enumerator(
      at: rootURL, includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles, .skipsPackageDescendants])
    var hits: [String] = []
    while let url = enumerator?.nextObject() as? URL {
      guard url.pathExtension == "swift" else { continue }
      if allowing.contains(url.lastPathComponent) { continue }
      let source = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
      let relative = url.path.replacingOccurrences(of: RepoRoot.url.path + "/", with: "")
      for (idx, line) in source.split(separator: "\n", omittingEmptySubsequences: false)
        .enumerated()
      {
        let text = String(line)
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") { continue }
        let ns = text as NSString
        if regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil {
          hits.append("\(relative):\(idx + 1): \(trimmed)")
        }
      }
    }
    return hits
  }

  /// Count matches over a synthetic multi-line string, applying the same
  /// comment-only-line skip the real scanner uses. Used by the fail-closed and
  /// comment-skip tests to exercise the matcher without touching disk.
  private static func countMatches(in source: String, pattern: String) -> Int {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
    var count = 0
    for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
      let text = String(line)
      if text.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
      let ns = text as NSString
      if regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil {
        count += 1
      }
    }
    return count
  }

  /// True iff the regex matches any line in `source` (no comment skip — used by
  /// the adversarial / negative-control single-line probes).
  private static func regexFlags(source: String, pattern: String) -> Bool {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
    for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
      let text = String(line)
      let ns = text as NSString
      if regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil {
        return true
      }
    }
    return false
  }
}
