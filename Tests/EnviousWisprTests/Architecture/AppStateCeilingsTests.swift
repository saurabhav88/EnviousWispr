import Foundation
import Testing

/// Architecture regression tests for AppState.
///
/// Locks post-Phase-F (#501) state so AppState does not silently re-accrete
/// toward a god-object. Tests parse the source file directly rather than
/// constructing an AppState instance — AppState's init pulls in real audio
/// capture, ASR, pipelines, and Tasks that should not run inside a unit test.
///
/// Ceilings: concrete-collaborator count ≤ 18, total line count ≤ 1115.
/// Raising a ceiling requires a Bible changelog entry, not a silent bump.
@Suite struct AppStateCeilingsTests {

  /// Concrete-collaborator count ceiling. Locked at post-PR3 (#769) baseline = 18.
  /// Counts top-level `let` declarations on AppState whose type is non-primitive.
  /// Existentials (`any X`) count as collaborators.
  ///
  /// Ratcheted 19 → 18 in PR3 of epic #763 (2026-05-18, #769) after extracting
  /// BenchmarkSuite into DiagnosticsCoordinator. PR4 of epic #763 (#770) ships
  /// `var languageSuggestionPresenter` which is intentionally a `var` (setter-
  /// injected post-init) and is therefore NOT counted by this parser — the
  /// ceiling stays at 18. Per Codex code-diff r4 [P3]: keeping the ceiling at
  /// 18 preserves the parser-aligned guard rather than weakening it to 19 for
  /// a collaborator the parser would not count anyway.
  @Test func appStateConcreteCollaboratorCeilingHolds() throws {
    let body = try classBodyOfAppState()
    let count = countTopLevelLetCollaborators(in: body)
    #expect(
      count <= 18,
      """
      AppState concrete-collaborator ceiling exceeded: \(count) > 18. \
      Raising the ceiling requires a Bible changelog entry, not a silent bump.
      """)
  }

  /// File line-count ceiling. Locked at post-PR4 (#770) baseline = 1115.
  /// Soft backstop against scope creep.
  ///
  /// Ratcheted history:
  /// - 1050 → 1049 in PR3 of epic #763 (2026-05-18, #769) after removing the
  ///   `let benchmark = BenchmarkSuite()` line.
  /// - 1049 → 1115 in PR4 of epic #763 (2026-05-18, #770) after adding the
  ///   transient `languageSuggestionPresenter` var + setter, the chip-handler
  ///   ChipWiringDiagnostics dispatch, the pipeline state-change chip dispatches
  ///   (parakeet `.complete`/`.error`, whisperKit `.complete`/`.ready`/`.error`,
  ///   plus polish-error race guards from Codex code-diff r2+r3), and the
  ///   cancelRecording chip clear. All sunset in PR9 / PR10 / PR11.
  ///   Bible-changelog entry present. 1107 actual + 8-line margin.
  @Test func appStateLineCountCeilingHolds() throws {
    let url = appStateURL()
    let source = try String(contentsOf: url, encoding: .utf8)
    let lineCount = source.split(separator: "\n", omittingEmptySubsequences: false).count
    #expect(
      lineCount <= 1115,
      """
      AppState line count exceeded: \(lineCount) > 1115. \
      Raising the ceiling requires a Bible changelog entry, not a silent bump.
      """)
  }
}

private func appStateURL() -> URL {
  // SPM tests run with cwd = package root.
  URL(fileURLWithPath: "Sources/EnviousWispr/App/AppState.swift")
}

private func classBodyOfAppState() throws -> String {
  let source = try String(contentsOf: appStateURL(), encoding: .utf8)
  guard let openRange = source.range(of: "final class AppState {") else {
    Issue.record("AppState declaration not found at expected path/shape")
    throw POSIXError(.ENOENT)
  }
  let openIdx = source.index(before: openRange.upperBound)  // points at '{'
  var depth = 0
  var idx = openIdx
  while idx < source.endIndex {
    let c = source[idx]
    if c == "{" { depth += 1 }
    if c == "}" {
      depth -= 1
      if depth == 0 { return String(source[source.index(after: openIdx)..<idx]) }
    }
    idx = source.index(after: idx)
  }
  Issue.record("AppState class body has unbalanced braces")
  throw POSIXError(.EILSEQ)
}

private func countTopLevelLetCollaborators(in body: String) -> Int {
  // Top-level = brace-depth 0 within the class body.
  // Match `let <ident>` declarations preceded by any combination of:
  //   - Swift attributes (e.g. `@ObservationIgnored`, `@Published`)
  //   - One access modifier (public/internal/private/fileprivate/package/open)
  // Skip primitives (Bool/Int/String/closures/Tasks).
  var depth = 0
  var collaborators = 0
  for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
    let opens = line.filter { $0 == "{" }.count
    let closes = line.filter { $0 == "}" }.count
    let depthForThisLine = depth - max(0, closes - opens)
    if depthForThisLine == 0 {
      let s = String(line)
      if isCollaboratorLetDeclaration(s) && !isPrimitiveTyped(s) {
        collaborators += 1
      }
    }
    depth += opens - closes
  }
  return collaborators
}

private let collaboratorLetPattern: String = {
  // Attribute can have a parenthesized argument list (`@available(macOS 14, *)`,
  // `@Injected(...)`); the optional `(\([^)]*\))?` matches that. Multiple
  // attributes in series allowed via `*` repetition.
  let attrs = #"(@[A-Za-z_][A-Za-z0-9_]*(\([^)]*\))?[[:space:]]+)*"#
  let access = #"(public|internal|private|fileprivate|package|open)?"#
  return "^[[:space:]]*\(attrs)\(access)[[:space:]]*let[[:space:]]+[A-Za-z_]"
}()

private func isCollaboratorLetDeclaration(_ line: String) -> Bool {
  return line.range(of: collaboratorLetPattern, options: .regularExpression) != nil
}

private func isPrimitiveTyped(_ line: String) -> Bool {
  // Architectural collaborators are concrete app/library types and protocol
  // existentials. Plain values are not collaborators.
  let primitives = [
    ": Bool", ": Int", ": String", ": Double", ": Float",
    "Task<", ": ((", "= false", "= true",
  ]
  return primitives.contains { line.contains($0) }
}
