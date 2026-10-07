import Foundation
import Testing

/// Self-test for `RouterCeilingParser` (issue #808). Before #808 the parser
/// anchored on the first inner brace and returned a method body. These tests
/// assert exact results against synthetic source so that regression cannot
/// return silently; `AppDelegateCeilingsTests` is the remaining consumer.
@Suite struct RouterCeilingParserTests {

  /// Writes `source` to a temp `.swift` file and returns the parsed class body.
  private func classBody(
    of source: String, named typeName: String = "Probe"
  ) throws -> String {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("rcp-\(UUID().uuidString).swift")
    try source.write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }
    return try RouterCeilingParser.classBody(named: typeName, at: url.path)
  }

  /// #2068 (cloud review, PR #2070, on the SwiftSyntax rewrite). The retired
  /// implementation searched with a `(?<![A-Za-z0-9_])` lookbehind so a match
  /// could not begin inside a longer identifier. The rewrite's plain substring
  /// search dropped it, which let `preassertAttached()` satisfy a guard that
  /// requires `assertAttached()` — a FALSE GREEN in a safety check, which is
  /// strictly worse than a missed match.
  ///
  /// The three cases below are the whole contract: a real call is found, a
  /// longer identifier ending in the needle is not, and an occurrence inside a
  /// comment or string is not.
  @Test func rangeOfStatement_requiresAnIdentifierBoundaryAndIgnoresNonCode() throws {
    let genuine = "  assertAttached()\n"
    #expect(RouterCeilingParser.rangeOfStatement("assertAttached()", in: genuine) != nil)

    let suffixOnly = "  preassertAttached()\n"
    #expect(
      RouterCeilingParser.rangeOfStatement("assertAttached()", in: suffixOnly) == nil,
      "a longer identifier ending in the needle must not satisfy the guard")

    let commented = "  // assertAttached()\n"
    #expect(RouterCeilingParser.rangeOfStatement("assertAttached()", in: commented) == nil)

    let quoted = "  let note = \"assertAttached()\"\n"
    #expect(RouterCeilingParser.rangeOfStatement("assertAttached()", in: quoted) == nil)
  }

  @Test func classBody_returnsClassBody_notInnerMethodBody() throws {
    // The `init` body holds its own `{` and a local `let`. The pre-#808 bug
    // anchored on that inner brace and returned the init body, counting the
    // local `let` (→ 1) instead of the two real collaborators (→ 2).
    let body = try classBody(
      of: """
        final class Probe {
          let alpha: AlphaDep
          let beta: BetaDep
          init() {
            let local: LocalThing = makeThing()
            _ = local
          }
        }
        """)
    #expect(RouterCeilingParser.collaboratorCount(in: body) == 2)
  }

  @Test func classBody_handlesConformanceListDeclaration() throws {
    // `final class X: Protocol {` — the `:`-conformance shape.
    let body = try classBody(
      of: """
        final class Probe: SomeProtocol, AnotherProtocol {
          let gamma: GammaDep
          init() {}
        }
        """)
    #expect(RouterCeilingParser.collaboratorCount(in: body) == 1)
  }

  // MARK: - #826 — comment/string-aware declaration anchor + brace scan

  @Test func classBody_ignoresDeclarationTextInComment() throws {
    // A doc comment quoting the declaration must not mis-anchor the scan. Before
    // #826 the raw `range(of:)` matched the comment first and the brace scan
    // latched onto the comment's `{`, throwing "unbalanced braces".
    let body = try classBody(
      of: """
        // Example usage: `final class Probe {` is the declaration shape.
        final class Probe {
          let alpha: AlphaDep
          let beta: BetaDep
        }
        """)
    #expect(RouterCeilingParser.collaboratorCount(in: body) == 2)
  }

  @Test func classBody_ignoresDeclarationTextInStringLiteral() throws {
    // A string literal holding the declaration text (here a top-level `let`
    // before the real class) must not mis-anchor the scan.
    let body = try classBody(
      of: """
        let fake = "final class Probe {"
        final class Probe {
          let alpha: AlphaDep
        }
        """)
    #expect(RouterCeilingParser.collaboratorCount(in: body) == 1)
  }

  @Test func classBody_ignoresBraceInStringLiteralBody() throws {
    // A `}` inside a string literal must not close the class body early. Before
    // #826 the raw brace scan saw the string's `}` and truncated the body,
    // dropping the trailing collaborator.
    let body = try classBody(
      of: """
        final class Probe {
          let pattern: Matcher = makeMatcher("unbalanced } brace")
          let alpha: AlphaDep
        }
        """)
    #expect(RouterCeilingParser.collaboratorCount(in: body) == 2)
  }

  @Test func classBody_ignoresBraceInComment() throws {
    // A `}` inside a `//` comment must not close the class body early.
    let body = try classBody(
      of: """
        final class Probe {
          // a stray closing brace } sits in this comment
          let alpha: AlphaDep
        }
        """)
    #expect(RouterCeilingParser.collaboratorCount(in: body) == 1)
  }

  @Test func classBody_preservesOffsetsAcrossNonASCII() throws {
    // The code view blanks masked chars to spaces by Character, so a non-ASCII
    // char inside a string (alongside a brace) must not shift the code-view to
    // source offset mapping — the body slice stays correct (#826 / offset unit).
    let body = try classBody(
      of: """
        final class Probe {
          let note: Label = makeLabel("café ☕ }")
          let alpha: AlphaDep
        }
        """)
    #expect(RouterCeilingParser.collaboratorCount(in: body) == 2)
  }

  @Test func classBody_failsClosedOnSourceThatDoesNotParse() {
    // The property the ceilings depend on: source the parser cannot read must
    // THROW, never return a small confident number, because every ceiling is a
    // `<=` bound and a count that reads LOW passes forever without complaining.
    //
    // Asserted with a plain SYNTAX error, which is an error in every build
    // configuration. The first version of this test used a 30-level nesting
    // depth instead and passed locally while FAILING the release lane on main:
    // `Parser.defaultMaximumNestingLevel` is 20 under `#if DEBUG` but 256
    // otherwise (Parser.swift:134, pinned swift-syntax 603.0.2), so depth 30
    // throws in Debug and parses cleanly in Release. The nesting limit is a
    // property of the BUILD, so it cannot carry an assertion; the parse failure
    // itself is a property of the SOURCE, so it can.
    //
    // `withKnownIssue` rather than `#expect(throws:)`: the fail-closed path also
    // calls `Issue.record` on its way out, so the recorded issue would fail this
    // test even though throwing is the behaviour being asserted.
    withKnownIssue("parsed(_:context:) records an issue as well as throwing") {
      _ = try classBody(
        of: """
          final class Probe {
            let broken:
          }
          """)
    }
  }
}
