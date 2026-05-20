import Foundation
import Testing

/// PR-C.1 of #763 — guards that `AppState` stays **receive-only**.
///
/// PR-C.1 moved all subsystem construction and every init-time wiring step out
/// of `AppState.init()` into `EnviousWisprApp.init()` (the composition root).
/// AppState's initializer must remain pure assignment: every statement is
/// `self.<name> = <name>`. This test fails if a future change reintroduces
/// construction (a `SomeType(...)` call), wiring (`.setX(...)`, `wireX(...)`,
/// closure assignment), or a `Task` into the body — the regression that would
/// re-grow AppState back toward a god object during the PR-C migration window.
///
/// Replaced by `AppStateFreezeTests` in PR-C.4, when `AppState.swift` is deleted.
@Suite struct AppStateReceiveOnlyTests {

  @Test func appStateInitIsPureAssignment() throws {
    let url = URL(fileURLWithPath: "Sources/EnviousWispr/App/AppState.swift")
    let source = try String(contentsOf: url, encoding: .utf8)
    let body = try Self.initBody(in: source)

    let offending =
      body
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { line in
        guard !line.isEmpty, !line.hasPrefix("//") else { return false }
        // The only allowed statement shape is `self.<ident> = <ident>`.
        return line.range(
          of: #"^self\.[A-Za-z_][A-Za-z0-9_]* = [A-Za-z_][A-Za-z0-9_]*$"#,
          options: .regularExpression) == nil
      }

    #expect(
      offending.isEmpty,
      """
      AppState.init must be pure assignment (receive-only — PR-C.1 of #763). \
      Construction and wiring belong in EnviousWisprApp.init(). \
      Non-assignment statements found:
      \(offending.joined(separator: "\n"))
      """)
  }

  /// Extract the body of `init(...) { ... }` — the text between the `{` that
  /// opens the init body (the first `{` after the balanced parameter list) and
  /// its matching `}`.
  private static func initBody(in source: String) throws -> String {
    guard let initRange = source.range(of: "  init(") else {
      Issue.record("AppState `init(` not found at expected shape")
      throw POSIXError(.ENOENT)
    }
    var idx = initRange.upperBound
    var parenDepth = 1
    while idx < source.endIndex, parenDepth > 0 {
      if source[idx] == "(" { parenDepth += 1 }
      if source[idx] == ")" { parenDepth -= 1 }
      idx = source.index(after: idx)
    }
    guard let openBrace = source[idx...].firstIndex(of: "{") else {
      Issue.record("AppState init body opening brace not found")
      throw POSIXError(.ENOENT)
    }
    var braceDepth = 0
    var j = openBrace
    while j < source.endIndex {
      if source[j] == "{" { braceDepth += 1 }
      if source[j] == "}" {
        braceDepth -= 1
        if braceDepth == 0 {
          return String(source[source.index(after: openBrace)..<j])
        }
      }
      j = source.index(after: j)
    }
    Issue.record("AppState init body has unbalanced braces")
    throw POSIXError(.EILSEQ)
  }
}
