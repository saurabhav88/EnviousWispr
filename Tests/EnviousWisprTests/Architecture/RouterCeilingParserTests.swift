import Foundation
import Testing

/// Self-test for `RouterCeilingParser` (issue #808). The parser feeds nine
/// architecture-ceiling suites; before #808 it anchored on the first inner
/// brace and returned a method body, so every `count <= N` consumer assertion
/// passed on `0`. These tests assert exact counts against synthetic source so
/// that regression — and the `let`-only / multi-line-fold behavior — cannot
/// return silently.
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

  @Test func collaboratorCount_excludesVarStoredProperty() throws {
    // `var` is owned mutable state, not a collaborator (architecture-rules.md).
    let body = try classBody(
      of: """
        final class Probe {
          let alpha: AlphaDep
          var mutableState: SomeState
        }
        """)
    #expect(RouterCeilingParser.collaboratorCount(in: body) == 1)
  }

  @Test func collaboratorCount_excludesVarComputedProperty() throws {
    let body = try classBody(
      of: """
        final class Probe {
          let alpha: AlphaDep
          var computed: AlphaDep { alpha }
        }
        """)
    #expect(RouterCeilingParser.collaboratorCount(in: body) == 1)
  }

  @Test func collaboratorCount_excludesPrimitiveLet() throws {
    let body = try classBody(
      of: """
        final class Probe {
          let alpha: AlphaDep
          let flag: Bool
          let count: Int
          let name: String
        }
        """)
    #expect(RouterCeilingParser.collaboratorCount(in: body) == 1)
  }

  @Test func closureCount_countsSingleLineClosure() throws {
    let body = try classBody(
      of: """
        final class Probe {
          let alpha: AlphaDep
          let onEvent: @MainActor (Int) -> Bool
        }
        """)
    #expect(RouterCeilingParser.collaboratorCount(in: body) == 1)
    #expect(RouterCeilingParser.closureInjectedCount(in: body) == 1)
  }

  @Test func closureCount_countsMultiLineClosureDeclaration() throws {
    // A closure-typed `let` whose signature wraps onto a second physical line
    // (the `AudioEventRouter.resolveActiveCaptureBackend` shape). Without the
    // continuation fold, line 1 (`let resolve:`) misclassifies as a
    // collaborator and the closure is missed.
    let body = try classBody(
      of: """
        final class Probe {
          let alpha: AlphaDep
          let resolve:
            @MainActor () -> SomeNamespace.SomeResult?
        }
        """)
    #expect(RouterCeilingParser.collaboratorCount(in: body) == 1)
    #expect(RouterCeilingParser.closureInjectedCount(in: body) == 1)
  }

  @Test func nonPrivateMethodCount_countsNonPrivateExcludesPrivateAndInit() throws {
    let body = try classBody(
      of: """
        final class Probe {
          let alpha: AlphaDep
          init() {}
          func publicWork() {}
          private func hidden() {}
          func moreWork() -> Bool { true }
        }
        """)
    #expect(RouterCeilingParser.nonPrivateMethodCount(in: body) == 2)
  }

  @Test func collaboratorCount_stringLiteralPunctuationDoesNotTriggerFold() throws {
    // A `//` and brackets inside a string literal must not be read as a
    // comment or unbalanced bracket. If they were, `endpoint` would look
    // unterminated, fold in the next line, and `realDep` would silently
    // vanish from the count — a false-green ceiling.
    let body = try classBody(
      of: """
        final class Probe {
          let endpoint: String = "https://example.com/[v1]"
          let realDep: AlphaDep
        }
        """)
    #expect(RouterCeilingParser.collaboratorCount(in: body) == 1)
  }
}
