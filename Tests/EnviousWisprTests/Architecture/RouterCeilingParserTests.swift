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

  /// #2068 (cloud review, PR #2070, round eighteen). `nonisolated let` is how a
  /// `@MainActor` class exposes a Sendable seam, and `RecordingStarter` — whose
  /// ceilings this parser freezes — is `@MainActor`. The stored-property pattern
  /// allowed attributes and access control but not `nonisolated`, so such a
  /// property was invisible to BOTH counters: not a collaborator, not a closure,
  /// simply absent.
  ///
  /// Reachable, unlike the generic-spelling findings recorded as limits:
  /// `nonisolated` appears at top level in 27 files here. The tell that it was an
  /// oversight rather than a decision is the twin — `nonPrivateMethodPattern` has
  /// always carried `nonisolated`, so the method side already knew.
  ///
  /// All four orderings verified with `swiftc -swift-version 6 -typecheck`.
  @Test func collaboratorCount_countsNonisolatedStoredProperties() throws {
    let body = try classBody(
      of: """
        final class Probe {
          nonisolated let alpha: AlphaDep
          private nonisolated let beta: BetaDep
          nonisolated private let gamma: GammaDep
          nonisolated(unsafe) let delta: DeltaDep
          nonisolated let onEvent: @Sendable (Int) -> Bool
        }
        """)
    #expect(RouterCeilingParser.collaboratorCount(in: body) == 4)
    #expect(RouterCeilingParser.closureInjectedCount(in: body) == 1)
  }

  /// The control for that widening: `static let` is a TYPE property, not an
  /// injected instance collaborator, and must stay excluded. Admitting
  /// `nonisolated` to the modifier alternation is exactly the edit that could
  /// let `static` in alongside it.
  @Test func collaboratorCount_stillExcludesStaticTypeProperties() throws {
    let body = try classBody(
      of: """
        final class Probe {
          let alpha: AlphaDep
          static let shared: Registry
          private static let table: Lookup
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

  /// #2068: an `async` closure used to match neither `isClosureTyped` nor
  /// `isPrimitiveTyped`, so it counted as a COLLABORATOR — it evaded the closure
  /// ceiling entirely while consuming a collaborator slot. Both counters were
  /// wrong about the same property, in opposite directions.
  ///
  /// Measured on the real file: `RecordingStarter.closureInjectedCount` read 8
  /// against 10 closure-typed `let`s, the two missing being
  /// `makeRecoveryDirective` and `ensureSelectedReadyForPress` — both `async`,
  /// and both dependencies of exactly the shape the closure ceiling exists to
  /// bound.
  @Test func closureCount_countsEffectfulClosures() throws {
    let body = try classBody(
      of: """
        final class Probe {
          let alpha: AlphaDep
          let load: @MainActor () async -> SomeResult
          let fetch: @MainActor (Int) throws -> Bool
          let both: @MainActor () async throws -> SomeResult
          let wrapped:
            @MainActor (Settings, Backend, Bool) async -> (id: String, payload: Data)?
        }
        """)
    #expect(RouterCeilingParser.closureInjectedCount(in: body) == 4)
    // The two-way half: the effectful closures left the collaborator count, they
    // did not merely join the closure count. `alpha` is the only collaborator.
    #expect(RouterCeilingParser.collaboratorCount(in: body) == 1)
  }

  /// #2068 (cloud review, PR #2070): the effect specifier can START the next
  /// physical line, leaving line one with balanced parens and no trailing
  /// continuation operator — so it reads as a finished declaration and the
  /// closure is missed entirely.
  @Test func closureCount_foldsWhenTheEffectSpecifierStartsTheNextLine() throws {
    let body = try classBody(
      of: """
        final class Probe {
          let alpha: AlphaDep
          let dependency: ()
            async -> Void
          let other: (Int)
            throws -> Bool
          let arrowOnly: (String)
            -> Int
        }
        """)
    #expect(RouterCeilingParser.closureInjectedCount(in: body) == 3)
    #expect(RouterCeilingParser.collaboratorCount(in: body) == 1)
  }

  /// Typed throws (cloud review, PR #2070). `() throws(MyError) -> Void` is a
  /// valid stored closure on this Swift 6 target, and the error type sits
  /// between `throws` and `->` — so a pattern expecting the arrow immediately
  /// after the specifier counts it as a COLLABORATOR instead. Same silent
  /// miscount as the plain `async` case, one syntax feature further out.
  @Test func closureCount_countsTypedThrows() throws {
    let body = try classBody(
      of: """
        final class Probe {
          let alpha: AlphaDep
          let strict: @MainActor () throws(DomainError) -> Void
          let both: @MainActor (Int) async throws(DomainError) -> Bool
          let wrapped: (String)
            throws(DomainError) -> Int
        }
        """)
    #expect(RouterCeilingParser.closureInjectedCount(in: body) == 3)
    #expect(RouterCeilingParser.collaboratorCount(in: body) == 1)
  }

  /// #2068, the CLASS rather than another instance. Three review rounds each
  /// found one more permitted-but-unhandled placement in the same predicate
  /// (`async`, then the specifier on the next line, then typed throws), which is
  /// the signal to stop patching shapes: Swift's function-type grammar admits
  /// arbitrary trivia between every token, so any matcher keyed to
  /// physically-adjacent text has an unbounded tail of these.
  ///
  /// Closed structurally instead — the predicate matches the CODE VIEW (comments
  /// and string contents blanked to spaces) and the fold looks PAST trivia — so
  /// these cases pass by construction rather than by enumeration. This is the
  /// exhaustive sweep of the class, not the next entry in it.
  @Test func closureCount_toleratesTriviaAnywhereInTheSignature() throws {
    let body = try classBody(
      of: """
        final class Probe {
          let alpha: AlphaDep
          let commented: ()
            // why this one is async
            async -> Void
          let blankLine: (Int)

            throws -> Bool
          let inlineComment: (String)  // a trailing note
            -> Int
          let both: ()
            // documented
            async throws(DomainError) -> Void
        }
        """)
    #expect(RouterCeilingParser.closureInjectedCount(in: body) == 4)
    #expect(RouterCeilingParser.collaboratorCount(in: body) == 1)
  }

  /// #2068 (cloud review, PR #2070, the finding after the structural fix): the
  /// trivia the fold looks past can be a `/* ... */` that SPANS lines. The
  /// lookahead used to call `codeView` on each candidate line separately, and
  /// block-comment depth is per-call state — so it reset at every line boundary
  /// and the comment's INTERIOR lines came back as code. The lookahead stopped
  /// on the first of them, found no effect specifier, and gave up.
  ///
  /// The fix blanks the whole body ONCE and splits after, which is why the
  /// fixture's comment body is three lines rather than one: a single-line block
  /// comment is blanked correctly either way and would prove nothing.
  ///
  /// `(Renderer)`, not `(Int)` — a primitive `let` is excluded from BOTH
  /// counters, so a fixture using one holds every number still whether the fold
  /// works or not. Here the miscount moves both: unfolded, `spanning` leaves the
  /// closure count and lands in the collaborator count.
  @Test func closureCount_foldsPastAMultiLineBlockComment() throws {
    let body = try classBody(
      of: """
        final class Probe {
          let alpha: AlphaDep
          let spanning: (Renderer)
            /* the daemon can answer late,
               so this dependency is
               deliberately deferred */
            async -> Void
          let beta: BetaDep
        }
        """)
    #expect(RouterCeilingParser.closureInjectedCount(in: body) == 1)
    #expect(RouterCeilingParser.collaboratorCount(in: body) == 2)
  }

  /// The same class, one layer down and load-bearing: BRACE DEPTH. `braceCounts`
  /// deliberately ran without block-comment blanking, and `codeView`'s own doc
  /// recorded why — a per-LINE call resets the depth, so blanking there would
  /// mis-track braces inside a multi-line comment. The cost of leaving it off was
  /// never written down: a `}` inside a block comment is counted as real, drives
  /// brace depth NEGATIVE, and every following declaration is then judged
  /// non-top-level and skipped.
  ///
  /// That is an UNDERCOUNT of a ceiling — the one direction
  /// `closureCount_doesNotFoldACompleteParenthesizedType` already says a ceiling
  /// must never fail in. Blanking once over the whole body is what makes it safe
  /// to close, which is why this arrives with the lookahead fix and not later.
  ///
  /// No ceiling was mis-read when this landed: `Sources/` held exactly one block
  /// comment, inline and brace-free. The fixture below is therefore the only
  /// place the bug can be observed, which is precisely why it is worth pinning —
  /// the failure needs no unusual code to appear, just an ordinary `/* ... */`
  /// that happens to contain a brace, and it would then read LOW and pass.
  @Test func braceDepth_ignoresBracesInsideABlockComment() throws {
    let body = try classBody(
      of: """
        final class Probe {
          let alpha: AlphaDep
          /* a note containing a stray } brace
             and a second line with { too */
          let beta: BetaDep
          let gamma: GammaDep
        }
        """)
    // Without blanking, the stray `}` drops depth to -1 and `beta`/`gamma` are
    // never seen as top-level: the count reads 1 instead of 3.
    #expect(RouterCeilingParser.collaboratorCount(in: body) == 3)
  }

  /// The control: real braces must still move depth, or the fix above could pass
  /// by blanking too much. A nested type's members are NOT top-level properties
  /// of the outer class and must stay excluded.
  @Test func braceDepth_stillExcludesMembersOfANestedType() throws {
    let body = try classBody(
      of: """
        final class Probe {
          let alpha: AlphaDep
          struct Inner {
            let notCounted: BetaDep
            let alsoNotCounted: GammaDep
          }
          let beta: BetaDep
        }
        """)
    #expect(RouterCeilingParser.collaboratorCount(in: body) == 2)
  }

  /// #2068 (cloud review, PR #2070, round six). The parameter list was matched
  /// with `\([^)]*\)`, which stops at the FIRST `)` — so any parenthesis nested
  /// inside the parameter type ends the match early and the outer `->` is never
  /// reached. A regex cannot balance brackets; five rounds of widening the
  /// character classes could not have fixed this, because it is not a missing
  /// syntax shape but a missing capability.
  ///
  /// Fails toward COLLABORATOR, so the closure ceiling silently stops counting
  /// the dependency it exists to bound.
  @Test func closureCount_balancesParenthesesNestedInTheParameterType() throws {
    let body = try classBody(
      of: """
        final class Probe {
          let alpha: AlphaDep
          let handler: (Result<(Int, String), DomainError>) -> Void
          let deep: @MainActor (Outcome<(A, (B, C)), Failure>) async -> Bool
        }
        """)
    #expect(RouterCeilingParser.closureInjectedCount(in: body) == 2)
    #expect(RouterCeilingParser.collaboratorCount(in: body) == 1)
  }

  /// Swift requires no whitespace around effect specifiers or the arrow, but the
  /// pattern demanded at least one space before each. `()async->Void` is a valid
  /// stored closure and read as a collaborator.
  @Test func closureCount_acceptsEffectSpecifiersWithNoSurroundingWhitespace() throws {
    let body = try classBody(
      of: """
        final class Probe {
          let alpha: AlphaDep
          let tight: ()async->Void
          let strict: ()throws(DomainError)->Bool
          let plain: (Int)->String
        }
        """)
    #expect(RouterCeilingParser.closureInjectedCount(in: body) == 3)
    #expect(RouterCeilingParser.collaboratorCount(in: body) == 1)
  }

  /// #2068 (cloud review, PR #2070, round seven). An OPTIONAL function type
  /// parenthesises the whole type — `(() -> Void)?` — so the scanner read the
  /// outer group as the parameter list, found `?` where it wanted `->`, and gave
  /// up. Optional callbacks are the single most ordinary closure-dependency
  /// shape in this codebase, and they fell to COLLABORATOR.
  @Test func closureCount_countsOptionalAndParenthesisedFunctionTypes() throws {
    let body = try classBody(
      of: """
        final class Probe {
          let alpha: AlphaDep
          let onFinish: (() -> Void)?
          let onFail: ((Error) -> Void)?
          let wrapped: (@MainActor (Int) async -> Bool)
        }
        """)
    #expect(RouterCeilingParser.closureInjectedCount(in: body) == 3)
    #expect(RouterCeilingParser.collaboratorCount(in: body) == 1)
  }

  /// #2068 (cloud review, PR #2070, round seven). An attribute may sit alone on
  /// the line before the parameter list. The fold looked for an effect specifier
  /// or an arrow, and `()` is neither, so line one was emitted as a finished
  /// declaration.
  ///
  /// Closed by termination rather than by lookahead: a buffer whose last token is
  /// `@MainActor` cannot be a complete declaration, whereas "the next line starts
  /// with `(`" is also true of an ordinary following declaration and would
  /// over-fold into an undercount.
  @Test func closureCount_foldsWhenAnAttributeEndsTheLine() throws {
    let body = try classBody(
      of: """
        final class Probe {
          let alpha: AlphaDep
          let deferred: @MainActor
            () -> Void
          let beta: BetaDep
        }
        """)
    #expect(RouterCeilingParser.closureInjectedCount(in: body) == 1)
    #expect(RouterCeilingParser.collaboratorCount(in: body) == 2)
  }

  /// #2068 (cloud review, PR #2070, round eight). The attribute-termination rule
  /// landed handling only the BARE form, so a PARAMETERISED attribute ending the
  /// line — `@isolated(any)`, `@convention(c)` — left the buffer ending in `)`
  /// and looking complete. Swift allows exactly two attribute forms, so covering
  /// both closes the case instead of adding its next instance.
  @Test func closureCount_foldsWhenAParameterisedAttributeEndsTheLine() throws {
    let body = try classBody(
      of: """
        final class Probe {
          let alpha: AlphaDep
          let isolated: @isolated(any)
            () -> Void
          let cFunc: @convention(c)
            (Int) -> Void
          let beta: BetaDep
        }
        """)
    #expect(RouterCeilingParser.closureInjectedCount(in: body) == 2)
    #expect(RouterCeilingParser.collaboratorCount(in: body) == 2)
  }

  /// #2068 (cloud review, PR #2070, round nine). The round-seven recursion into
  /// a parenthesised group matched a TUPLE whose first element is a closure —
  /// `(() -> Void, AlphaDep)` — because the scan succeeded on that element and
  /// never checked it spanned the whole group. The tuple is a collaborator, not
  /// a closure, so this over-counted closures and under-counted collaborators:
  /// a defect the recursion itself introduced.
  ///
  /// A top-level comma is the structural separator: a tuple has one; a wrapped
  /// function type does not, since `((A, B) -> C)?`'s comma is one level down
  /// inside the parameter list.
  @Test func closureCount_aTupleContainingAClosureIsNotAClosure() throws {
    let body = try classBody(
      of: """
        final class Probe {
          let bundle: (() -> Void, AlphaDep)
          let reversed: (AlphaDep, () -> Void)
          let real: (() -> Void)?
        }
        """)
    #expect(RouterCeilingParser.closureInjectedCount(in: body) == 1)
    #expect(RouterCeilingParser.collaboratorCount(in: body) == 2)
  }

  /// #2068 (cloud review, PR #2070, round ten). The `:` opening a type
  /// annotation may itself start the continuation line. Line one is then a bare
  /// `let dependency`, which the fold read as a finished declaration.
  ///
  /// Confirmed against the compiler before fixing — `swiftc -swift-version 6
  /// -typecheck` accepts the form — rather than taken from the report, because
  /// the sibling finding in the same round asserted a syntax Swift rejects.
  @Test func closureCount_foldsWhenTheColonStartsTheNextLine() throws {
    let body = try classBody(
      of: """
        final class Probe {
          let alpha: AlphaDep
          let deferred
            : () -> Void
          let beta: BetaDep
        }
        """)
    #expect(RouterCeilingParser.closureInjectedCount(in: body) == 1)
    #expect(RouterCeilingParser.collaboratorCount(in: body) == 2)
  }

  /// #2068 (cloud review, PR #2070, round eleven). `isClosureTyped` retried the
  /// closure parse after EVERY colon, so a non-closure type holding a closure
  /// matched on an inner one: `let handlers: [String: () -> Void]` is a
  /// dictionary — a collaborator — but its value-type colon parses as a closure
  /// signature. Now only the declaration's own annotation colon (bracket depth 0)
  /// is tried.
  ///
  /// Pre-existing rather than introduced by the scanner: the regex this replaced
  /// matched the same inner colon. Earlier in this PR I noted the behaviour and
  /// called it "no regression", which was true and beside the point — it was
  /// still a miscount.
  @Test func closureCount_aDictionaryOfClosuresIsACollaborator() throws {
    let body = try classBody(
      of: """
        final class Probe {
          let handlers: [String: () -> Void]
          let lookup: [Int: (String) -> Bool]
          let real: (Int) -> Bool
        }
        """)
    #expect(RouterCeilingParser.closureInjectedCount(in: body) == 1)
    #expect(RouterCeilingParser.collaboratorCount(in: body) == 2)
  }

  /// #2068 (cloud review, PR #2070, round eleven). `@Sendable()->Void` is valid
  /// Swift and its adjacent `()` IS the parameter list, so the adjacency rule
  /// consumed it as attribute arguments and the property fell to COLLABORATOR.
  ///
  /// The report paired it with `@MainActor()->Void`, which does NOT compile
  /// (`error: expected type`), so the two forms cannot be separated by shape.
  /// Whether an attribute takes arguments is not knowable here, so the scan
  /// decides by what FOLLOWS the group: an arrow or effect specifier means the
  /// group was the parameter list.
  @Test func closureCount_readsACompactAttributeAndParameterList() throws {
    let body = try classBody(
      of: """
        final class Probe {
          let alpha: AlphaDep
          let tight: @Sendable()->Void
          let effectful: @Sendable()async->Bool
        }
        """)
    #expect(RouterCeilingParser.closureInjectedCount(in: body) == 2)
    #expect(RouterCeilingParser.collaboratorCount(in: body) == 1)
  }

  /// The control for that rewind: an attribute whose adjacent group really IS an
  /// argument list must keep it, or `@isolated(any) () -> Void` loses its
  /// parameter list and stops parsing. The discriminator is what follows the
  /// group — here another `(`, not an arrow.
  @Test func closureCount_keepsGenuineAttributeArgumentLists() throws {
    let body = try classBody(
      of: """
        final class Probe {
          let alpha: AlphaDep
          let isolated: @isolated(any) () -> Void
          let gated: @available(macOS 26, *) (Int) -> Bool
        }
        """)
    #expect(RouterCeilingParser.closureInjectedCount(in: body) == 2)
    #expect(RouterCeilingParser.collaboratorCount(in: body) == 1)
  }

  /// The over-fold control: a `let` that HAS reached its `:` or `=` is complete
  /// and must not swallow the declaration after it. Without this, "a `let` line
  /// might continue" would fold every property into its neighbour and undercount
  /// the whole class.
  @Test func closureCount_aCompleteLetDoesNotFoldTheNextDeclaration() throws {
    let body = try classBody(
      of: """
        final class Probe {
          let alpha: AlphaDep
          let beta: BetaDep
          let gamma: GammaDep
        }
        """)
    #expect(RouterCeilingParser.collaboratorCount(in: body) == 3)
    #expect(RouterCeilingParser.closureInjectedCount(in: body) == 0)
  }

  /// The control for that rule: a comma belonging to a GENERIC argument list or
  /// to the wrapped function's own parameter list is not a tuple separator, and
  /// must not block the recursion.
  @Test func closureCount_commasInsideNestedTypesStillCountAsClosures() throws {
    let body = try classBody(
      of: """
        final class Probe {
          let alpha: AlphaDep
          let paired: ((Int, String) -> Void)?
          let generic: ((Result<Int, DomainError>) -> Void)?
        }
        """)
    #expect(RouterCeilingParser.closureInjectedCount(in: body) == 2)
    #expect(RouterCeilingParser.collaboratorCount(in: body) == 1)
  }

  /// #2068 (cloud review, PR #2070, round nine). The recursion carried an
  /// arbitrary depth cap of 8 that returned false past its limit — silently, and
  /// in the UNDERCOUNT direction. The cap bought nothing: each recursive call is
  /// handed the current group's closing index as its limit, so the window
  /// strictly shrinks and termination is already guaranteed. Nine wrappers is
  /// absurd in real code, which is exactly why a wrong answer there would never
  /// be noticed.
  @Test func closureCount_survivesDeeplyNestedWrappers() throws {
    let body = try classBody(
      of: """
        final class Probe {
          let alpha: AlphaDep
          let deep: (((((((((() -> Void)))))))))
        }
        """)
    #expect(RouterCeilingParser.closureInjectedCount(in: body) == 1)
    #expect(RouterCeilingParser.collaboratorCount(in: body) == 1)
  }

  /// The over-fold control for that rule: a line ending in `)` that is a
  /// COMPLETED type, not an attribute, must still terminate the declaration.
  /// This is the exact failure the round-seven reasoning was guarding against
  /// when it wrongly concluded the two cases could not be told apart.
  @Test func closureCount_trailingParenTypeIsNotMistakenForAnAttribute() throws {
    let body = try classBody(
      of: """
        final class Probe {
          let wrapped: (AlphaDep)
          let built: Factory(config)
          let beta: BetaDep
        }
        """)
    #expect(RouterCeilingParser.closureInjectedCount(in: body) == 0)
    #expect(RouterCeilingParser.collaboratorCount(in: body) == 3)
  }

  /// #2068 (cloud review, PR #2070, round twelve). The recursion checked that a
  /// wrapping group started the type but not that it FINISHED it, so
  /// `(() -> Void).Type` — a function metatype, which is a collaborator — matched
  /// on the inner function and the `.Type` suffix was ignored.
  ///
  /// Confirmed valid Swift with `swiftc -swift-version 6 -typecheck` before
  /// fixing, as with every syntax claim since round ten produced one that did
  /// not compile.
  @Test func closureCount_aFunctionMetatypeIsACollaborator() throws {
    let body = try classBody(
      of: """
        final class Probe {
          let meta: (() -> Void).Type
          let alsoMeta: ((Int) -> Bool).Type
          let real: (() -> Void)?
        }
        """)
    #expect(RouterCeilingParser.closureInjectedCount(in: body) == 1)
    #expect(RouterCeilingParser.collaboratorCount(in: body) == 2)
  }

  /// #2068 (cloud review, PR #2070, round thirteen). `Optional<() -> Void>` is
  /// `(() -> Void)?` desugared — the same wrapped closure, spelled generically.
  /// The scan required the type to begin with `(`, so it fell to COLLABORATOR.
  ///
  /// LATENT, measured: `git grep -n "Optional<" -- 'Sources/**/*.swift'` returns
  /// zero hits, and the sugared form is what this codebase writes. Fixed anyway
  /// because the fix is genuinely small and the failure is an undercount of
  /// closures, which is the silent direction.
  @Test func closureCount_readsTheGenericOptionalSpelling() throws {
    let body = try classBody(
      of: """
        final class Probe {
          let alpha: AlphaDep
          let sugarFree: Optional<() -> Void>
          let qualified: Swift.Optional<(Int) -> Bool>
        }
        """)
    #expect(RouterCeilingParser.closureInjectedCount(in: body) == 2)
    #expect(RouterCeilingParser.collaboratorCount(in: body) == 1)
  }

  /// #2068 (cloud review, PR #2070, round fourteen). The generic-wrapper branch
  /// added last round returned as soon as its inner type parsed and never
  /// checked what followed, so `Optional<() -> Void>.Type` — a metatype — read as
  /// a closure. That is the SAME hole round twelve closed for the parenthesised
  /// wrapper, reopened by a new path that skipped the shared guard.
  ///
  /// Worth pinning as its own test rather than folding into the round-twelve
  /// one: the lesson is not "metatypes are collaborators", it is that a second
  /// wrapper path must end at the same trailing check as the first.
  @Test func closureCount_genericOptionalRejectsAMetatypeSuffix() throws {
    let body = try classBody(
      of: """
        final class Probe {
          let meta: Optional<() -> Void>.Type
          let real: Optional<() -> Void>
        }
        """)
    #expect(RouterCeilingParser.closureInjectedCount(in: body) == 1)
    #expect(RouterCeilingParser.collaboratorCount(in: body) == 1)
  }

  /// #2068 (cloud review, PR #2070, round fourteen). Swift accepts trivia inside
  /// the generic-Optional prefix — `Optional <…>`, `Swift . Optional<…>`, and
  /// `Optional /* docs */ <…>`, the last arriving here already blanked to spaces
  /// by the code view. Two string literals could not see any of them.
  @Test func closureCount_genericOptionalToleratesTriviaInThePrefix() throws {
    let body = try classBody(
      of: """
        final class Probe {
          let alpha: AlphaDep
          let spaced: Optional <() -> Void>
          let qualified: Swift . Optional<(Int) -> Bool>
          let commented: Optional /* the callback */ <() -> Void>
        }
        """)
    #expect(RouterCeilingParser.closureInjectedCount(in: body) == 3)
    #expect(RouterCeilingParser.collaboratorCount(in: body) == 1)
  }

  /// The control for that tolerance: a type whose name merely ENDS in `Optional`
  /// is not the generic wrapper, and `matchesKeyword`'s identifier-boundary
  /// check is what keeps them apart.
  @Test func closureCount_aTypeNamedLikeOptionalIsNotTheWrapper() throws {
    let body = try classBody(
      of: """
        final class Probe {
          let custom: MyOptional<() -> Void>
          let other: OptionalThing<() -> Void>
          let real: Optional<() -> Void>
        }
        """)
    #expect(RouterCeilingParser.closureInjectedCount(in: body) == 1)
    #expect(RouterCeilingParser.collaboratorCount(in: body) == 2)
  }

  /// The control: the whole-type guards must still apply THROUGH the generic
  /// wrapper. `Optional<(() -> Void, AlphaDep)>` wraps a tuple, not a closure,
  /// and an `Optional` of an ordinary collaborator is still a collaborator.
  @Test func closureCount_genericOptionalStillRejectsNonClosures() throws {
    let body = try classBody(
      of: """
        final class Probe {
          let bundled: Optional<(() -> Void, AlphaDep)>
          let plain: Optional<AlphaDep>
          let real: Optional<() -> Void>
        }
        """)
    #expect(RouterCeilingParser.closureInjectedCount(in: body) == 1)
    #expect(RouterCeilingParser.collaboratorCount(in: body) == 2)
  }

  /// The control: the markers that may legitimately follow a wrapper must still
  /// leave it a closure — optionals, forced optionals, and a default value,
  /// whose `=` ends the TYPE rather than disqualifying it.
  @Test func closureCount_optionalMarkersAndDefaultsStillCountAsClosures() throws {
    let body = try classBody(
      of: """
        final class Probe {
          let alpha: AlphaDep
          let opt: (() -> Void)?
          let forced: (() -> Void)!
          let defaulted: (() -> Void)? = nil
        }
        """)
    #expect(RouterCeilingParser.closureInjectedCount(in: body) == 3)
    #expect(RouterCeilingParser.collaboratorCount(in: body) == 1)
  }

  /// The control for the recursive scan: a parenthesised NON-function type must
  /// not become a closure just because the scanner now looks inside groups.
  /// `(AlphaDep)` is the exact shape `closureCount_doesNotFoldACompleteParenthesizedType`
  /// pins, and a tuple of collaborators must stay one collaborator.
  @Test func closureCount_recursionDoesNotInventClosuresInsidePlainGroups() throws {
    let body = try classBody(
      of: """
        final class Probe {
          let wrapped: (AlphaDep)
          let pair: (AlphaDep, BetaDep)
          let nested: ((AlphaDep, BetaDep), GammaDep)
        }
        """)
    #expect(RouterCeilingParser.closureInjectedCount(in: body) == 0)
    #expect(RouterCeilingParser.collaboratorCount(in: body) == 3)
  }

  /// The control for the attribute-termination rule: an attribute that is NOT at
  /// the end of the line must not make the declaration unterminated, or every
  /// `@MainActor (Int) -> Bool` would swallow the line after it.
  @Test func closureCount_attributeMidLineDoesNotFoldTheNextDeclaration() throws {
    let body = try classBody(
      of: """
        final class Probe {
          let onEvent: @MainActor (Int) -> Bool
          let beta: BetaDep
          let gamma: GammaDep
        }
        """)
    #expect(RouterCeilingParser.closureInjectedCount(in: body) == 1)
    #expect(RouterCeilingParser.collaboratorCount(in: body) == 2)
  }

  /// The control for both fixtures above: balancing brackets must not turn
  /// ordinary generic collaborators into closures. None of these declares a
  /// function type, and each contains the punctuation the scanner reads.
  @Test func closureCount_stillRejectsGenericsThatMerelyContainParentheses() throws {
    let body = try classBody(
      of: """
        final class Probe {
          let store: Storage<(Int, String)>
          let pair: (AlphaDep, BetaDep)
          let factory: Provider<Handler>
        }
        """)
    #expect(RouterCeilingParser.closureInjectedCount(in: body) == 0)
    #expect(RouterCeilingParser.collaboratorCount(in: body) == 3)
  }

  /// The two-way control for the fixture above. A multi-line block comment that
  /// is NOT followed by an effect specifier must still leave the declaration
  /// unfolded — otherwise the test above could pass because the fold became
  /// greedy rather than because it learned to see past the comment.
  @Test func closureCount_doesNotFoldPastACommentWhenNoSpecifierFollows() throws {
    let body = try classBody(
      of: """
        final class Probe {
          let alpha: AlphaDep
          let wrapped: (Renderer)
            /* a note that spans
               more than one line */
          let beta: BetaDep
        }
        """)
    #expect(RouterCeilingParser.closureInjectedCount(in: body) == 0)
    #expect(RouterCeilingParser.collaboratorCount(in: body) == 3)
  }

  /// The other half of matching on the code view: an arrow that only LOOKS like
  /// a closure type must not create one. Before this, `isClosureTyped` read raw
  /// text, so a comment or string containing `-> ` could fake a signature — the
  /// same class of false positive `classBody` already guards against for braces
  /// (#826).
  @Test func closureCount_ignoresArrowsInCommentsAndStrings() throws {
    let body = try classBody(
      of: """
        final class Probe {
          let alpha: AlphaDep  // maps (Int) -> Bool internally
          let label: Renderer = makeRenderer("(Int) -> Bool")
          let real: @MainActor (Int) -> Bool
        }
        """)
    #expect(RouterCeilingParser.closureInjectedCount(in: body) == 1)
    #expect(RouterCeilingParser.collaboratorCount(in: body) == 2)
  }

  /// The over-folding control. A complete parenthesized type must NOT swallow
  /// the declaration after it — that would UNDERCOUNT, which is the direction a
  /// ceiling must never fail in. This is why the fold looks ahead for an effect
  /// specifier instead of treating a trailing `)` as a continuation.
  @Test func closureCount_doesNotFoldACompleteParenthesizedType() throws {
    let body = try classBody(
      of: """
        final class Probe {
          let wrapped: (AlphaDep)
          let beta: BetaDep
          let gamma: GammaDep
        }
        """)
    #expect(RouterCeilingParser.closureInjectedCount(in: body) == 0)
    #expect(RouterCeilingParser.collaboratorCount(in: body) == 3)
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
