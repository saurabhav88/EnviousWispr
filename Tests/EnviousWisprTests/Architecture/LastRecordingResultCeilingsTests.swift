import Foundation
import Testing

/// Architecture ceiling for `LastRecordingResult` (PR7 of epic #763).
///
/// Locks the home as the canonical "post-recording polish error" surface:
/// - 1 observable stored `var` (`polishError: String?`)
/// - 0 non-private `func` methods
/// - ≤70 lines
/// - imports ⊆ {EnviousWisprCore, Foundation, Observation}
///
/// **Parser limitation note.** `CeilingsTestSupport.countTopLevelLetCollaborators`
/// counts only `let` declarations and filters out primitive types
/// (`String?` is primitive-filtered). The single `var polishError: String?`
/// is therefore invisible to that counter — both the `let` count and the
/// non-private-method count are 0. To still enforce "no growth," this test
/// adds a custom regex that counts top-level `var` declarations in the
/// class body; the cap is exactly 1.
///
/// Lowering any cap is free; raising requires a Bible §30 changelog entry.
@Suite struct LastRecordingResultCeilingsTests {
  private static let sourcePath =
    "Sources/EnviousWispr/App/LastRecordingResult.swift"

  @Test func storedLetCollaboratorCeiling() throws {
    let source = try CeilingsTestSupport.source(at: Self.sourcePath)
    let bodies = try CeilingsTestSupport.typeBodies(
      named: "LastRecordingResult", in: source)
    let total = bodies.reduce(0) { $0 + CeilingsTestSupport.countTopLevelLetCollaborators(in: $1) }
    #expect(
      total == 0,
      """
      LastRecordingResult should have 0 `let` collaborators (the home owns \
      a single observable `var polishError: String?`). Found \(total). \
      Adding a `let` collaborator would change the home's shape from \
      observable storage to derivation surface — requires a Bible §30 entry.
      """)
  }

  @Test func storedVarCeiling() throws {
    let source = try CeilingsTestSupport.source(at: Self.sourcePath)
    let bodies = try CeilingsTestSupport.typeBodies(
      named: "LastRecordingResult", in: source)
    // Custom counter: top-level `var <ident>:` declarations. Avoids matching
    // computed `var <ident>: T {` properties by excluding lines whose `var`
    // declaration is followed (on the same line) by an opening brace `{`.
    let pattern =
      #"^[[:space:]]*(public|internal|private|fileprivate|package|open)?[[:space:]]*var[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*:"#
    let total = bodies.reduce(0) { acc, body -> Int in
      var depth = 0
      var count = 0
      for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
        let opens = line.filter { $0 == "{" }.count
        let closes = line.filter { $0 == "}" }.count
        let depthForThisLine = depth - max(0, closes - opens)
        if depthForThisLine == 0 {
          let s = String(line)
          if s.range(of: pattern, options: .regularExpression) != nil,
            !s.contains("{")  // exclude computed property `var x: T {`
          {
            count += 1
          }
        }
        depth += opens - closes
      }
      return acc + count
    }
    #expect(
      total == 1,
      """
      LastRecordingResult stored `var` count mismatch: expected exactly 1 \
      (`polishError`), found \(total). Adding a stored `var` requires a \
      Bible §30 entry — this home is single-fact observable storage; \
      multi-fact state belongs on a different home or a new home.
      """)
  }

  @Test func nonPrivateMethodCeiling() throws {
    let source = try CeilingsTestSupport.source(at: Self.sourcePath)
    let bodies = try CeilingsTestSupport.typeBodies(
      named: "LastRecordingResult", in: source)
    let total = bodies.reduce(0) { $0 + CeilingsTestSupport.countNonPrivateMethods(in: $1) }
    #expect(
      total == 0,
      """
      LastRecordingResult non-private method count mismatch: expected \
      exactly 0 (`func` declarations only), found \(total). Adding a \
      `func` method requires a Bible §30 entry.
      """)
  }

  @Test func lineCountCeiling() throws {
    let source = try CeilingsTestSupport.source(at: Self.sourcePath)
    let count = CeilingsTestSupport.lineCount(in: source)
    #expect(
      count <= 70,
      """
      LastRecordingResult line count exceeded: \(count) > 70. \
      Ratchet down if implementation came in lower; raise only via Bible §30.
      """)
  }

  @Test func allowedImports() throws {
    let source = try CeilingsTestSupport.source(at: Self.sourcePath)
    let actual = CeilingsTestSupport.imports(in: source)
    let allowed: Set<String> = ["EnviousWisprCore", "Foundation", "Observation"]
    let extras = actual.subtracting(allowed)
    #expect(
      extras.isEmpty,
      """
      LastRecordingResult imports outside the allowed set: \(extras.sorted()). \
      Allowed: \(allowed.sorted()). New imports require a Bible §30 entry.
      """)
  }
}
