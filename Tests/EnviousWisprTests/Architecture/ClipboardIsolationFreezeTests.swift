import Foundation
import SwiftParser
import SwiftSyntax
import Testing

// MARK: - ClipboardIsolationFreezeTests (#2146)
//
// THE TEST SUITE MUST NEVER WRITE TO THE DEVELOPER'S REAL CLIPBOARD.
//
// It used to. Nine tests across two suites drove `NSPasteboard.general` — the
// machine's actual clipboard — and `PasteService.restoreClipboard`'s
// change-count guard then DECLINED to put it back whenever a concurrently
// running suite had advanced the count. Swift Testing parallelises across
// suites and `.serialized` orders only its own, so that happened routinely and
// the fixture text (famously the literal "hello") survived on the founder's
// clipboard. The guard is correct; the shared board was the defect.
//
// WHAT ACTUALLY PREVENTS THE BUG, so the next reader trusts the right thing:
//
//   1. `KernelFinalizationWiring.init`'s `copyToClipboard` is REQUIRED, not
//      defaulted. No test can inherit the real write by omission. Compile
//      enforced, cannot be forgotten.
//   2. `KernelFinalizationWiringTests.makeWiring` defaults that seam to
//      `Issue.record`, so a wiring test that copies without opting in FAILS.
//
// This suite is the third layer, and covers only what those two cannot see: a
// test that DELIBERATELY writes `NSPasteboard.general` or calls a
// clipboard-capable `PasteService` entry point without naming its board.
//
// WHY A PARSER AND NOT A SCANNER — the part that matters, because this repo has
// already paid for the lesson once. The first version of this guard was a shell
// script with a hand-rolled `awk` lexer. Codex review found four lexical defects
// in two rounds — escaped quotes closing a string early, wrapped calls whose
// arguments sat on the next line, member access split across lines, and
// multiline string fixtures being scanned as executable code — with no reason to
// believe the fourth was the last.
//
// `EngineMutationInventoryFreezeTests` records the same arc reaching FIVE
// consecutive rounds with no convergence, and a web-grounded council consult
// concluding this is a known, named class (SwiftLint's own multi-year
// regex-to-SwiftSyntax migration being the closest precedent). Repeating that
// discovery a third time would be a choice, not an accident. Parsing with
// `SwiftParser` — the same front end the compiler uses — excludes comments and
// every string form STRUCTURALLY rather than pattern-matching around them, so
// the entire class disappears rather than shrinking.
//
// Consequence worth stating plainly: prose describing this defect is not a
// violation of it, and a guard that cannot tell those apart fires on the very
// document explaining why it exists
// (validation-discipline.md RULE: false-positives-not-gates-train-evasion).
/// Drift Guard: this freezes a call-site inventory in our own test tree. When it fails, no USER sees
/// anything — a DEVELOPER's clipboard is at risk. Layers 1 and 2 above are what protect the outcome.
@Suite("Clipboard isolation freeze (#2146)", .tags(.driftGuard))
struct ClipboardIsolationFreezeTests {

  /// The one suite allowed to touch clipboard capability, because it is the
  /// suite that tests `PasteService` itself. Even there, every call must name
  /// its board.
  private static let allowlistedFile = "PasteServiceClipboardTests.swift"

  /// `PasteService` entry points that take a defaulted pasteboard, so an
  /// unlabelled call silently targets the user's clipboard.
  private static let clipboardFunctions: Set<String> = [
    "copyToClipboard",
    "copyToClipboardReturningChangeCount",
    "saveClipboard",
    "restoreClipboard",
    // Moved here from `boardlessClipboardFunctions` by #2170, which gave it a
    // board parameter. A boarded call is safe; a bare one still writes the real
    // clipboard, and the rule below catches exactly that.
    "pasteToActiveApp",
  ]

  /// Entry points with NO board parameter at all, so no call from a test can be made safe.
  ///
  /// **EMPTY as of #2170, and kept with its criterion rather than deleted.** Its only member was
  /// `pasteToActiveApp`, which hard-coded `NSPasteboard.general` internally — there was nothing to pass
  /// and nothing to isolate, so the only correct rule was that no test called it at all. It now takes
  /// the board as a defaulted parameter, so it moves to `clipboardFunctions` above, where the existing
  /// rule already does the right thing: a call is a violation unless it passes a board.
  ///
  /// FOUND BY ENUMERATING THE SET, not by matching a spelling: every finding before it was a different
  /// way of writing a name the guard already knew, and that was a name it did not know. The two failure
  /// modes look identical from inside the guard — it reports clean — so a spelling sweep can never
  /// surface a missing member.
  ///
  /// Re-derive rather than trust this being empty: list `PasteService`'s static functions and ask which
  /// reach `NSPasteboard.general` with no board parameter. Today
  /// `grep -n "NSPasteboard.general" Sources/EnviousWisprServices/PasteService.swift` returns comments
  /// only. A new member is any entry point added with the board hard-coded.
  private static let boardlessClipboardFunctions: Set<String> = []

  /// Types OTHER than `PasteService` whose methods reach the real clipboard, keyed to the methods that
  /// do it.
  ///
  /// THE SET WAS SCOPED TO ONE TYPE AND THE PROBLEM IS NOT. `PasteCascadeExecutor.deliver` reaches
  /// the clipboard on its fallback tier, which is CORRECT for production — that path is meant to
  /// reach the user's board — and lethal for a test, which gets there through `@testable import`.
  ///
  /// WHAT THIS GUARD CATCHES CHANGED IN #2170, so do not read the paragraph above as current
  /// mechanism. The executor now takes its pasteboard as a REQUIRED init parameter, so the no-board
  /// form it was written for does not compile at all and the COMPILER owns that case. What is left
  /// reachable, and what this scanner is now for, is a test passing `.general` explicitly — a
  /// deliberate act with a visible token, which is exactly the kind a text scanner can see.
  ///
  /// Re-derive rather than trust this list:
  ///   grep -rn "PasteService\.\(copyToClipboard\|saveClipboard\|restoreClipboard\)" Sources/ \
  ///     | grep -vE "to:|from:|on:"
  /// Every hit is a production caller that legitimately wants the user's board; the question this set
  /// answers is which of them a TEST can reach directly.
  ///
  /// KNOWN LIMIT, unchanged: this matches a LITERAL type base, so an inline construction is caught
  /// and a stored `executor.deliver(…)` is not — that needs type resolution this suite does not do.
  /// The durable fix WAS the injected seam this comment used to point at as future work; it landed in
  /// #2170, and it is what closes the stored-variable hole the scanner cannot reach: a stored
  /// executor still had to be constructed with a board, and constructing one with `.general` is the
  /// visible act above.
  /// ENUMERATED, not collected from review reports. Every `NSPasteboard.general` in `Sources/` is:
  ///
  ///   PasteService.pasteToActiveApp                    WRITE   boarded since #2170; bare calls banned
  ///   PasteCascadeExecutor.deliver                     WRITE   here (only via an EXPLICIT `.general`
  ///                                                            at construction, since #2170)
  ///   AIAvailabilityCoordinator.copyDiagnosticsToClipboard  WRITE   here
  ///   PasteCascadeExecutor  (changeCount)              READ    harmless; reads clobber nothing
  ///   DiagnosticsSettingsView, OnboardingV2View        WRITE   inside SwiftUI `body`, which a unit
  ///                                                            test cannot practically invoke
  ///
  /// Re-derive with `grep -rn "NSPasteboard\.general" Sources/` and classify each hit write/read and
  /// reachable/not. Two entries here arrived as separate review findings before the enumeration was
  /// done, which is the lesson: **a missing member and a clean file are the same observation from
  /// inside a guard**, so the set has to be derived rather than accumulated.
  private static let boardReachingTypes: [String: Set<String>] = [
    "PasteCascadeExecutor": ["deliver"],
    "AIAvailabilityCoordinator": ["copyDiagnosticsToClipboard"],
  ]

  /// Argument labels that name a board explicitly.
  private static let boardLabels: Set<String> = ["to", "from", "on"]

  struct Violation: CustomStringConvertible, Sendable {
    let file: String
    let line: Int
    let reason: String
    var description: String { "\(file):\(line): \(reason)" }
  }

  // MARK: Visitor

  private final class ClipboardVisitor: SyntaxVisitor {
    let converter: SourceLocationConverter
    let file: String
    let isAllowlisted: Bool
    var violations: [Violation] = []

    init(converter: SourceLocationConverter, file: String, isAllowlisted: Bool) {
      self.converter = converter
      self.file = file
      self.isAllowlisted = isAllowlisted
      super.init(viewMode: .sourceAccurate)
    }

    private func line(_ node: some SyntaxProtocol) -> Int {
      converter.location(for: node.positionAfterSkippingLeadingTrivia).line
    }

    /// The trailing name of a base expression: `NSPasteboard` from either `NSPasteboard` or
    /// `AppKit.NSPasteboard`.
    ///
    /// Requiring a BARE `DeclReferenceExprSyntax` here meant a module-qualified spelling walked past
    /// this guard. That is the same defect #2150's inventory gate carried at its own attribute
    /// comparison, and the shape is worth naming because a parser does not prevent it: A COMPARISON
    /// NARROWER THAN THE LANGUAGE. It fails QUIETLY — the write still lands on the developer's real
    /// clipboard, and the scan reports clean.
    ///
    /// Deliberately NOT resolved further. An alias (`typealias PB = NSPasteboard`) or a helper that
    /// returns the board still walks past, which is why this suite is the THIRD layer and not the fix:
    /// the required `copyToClipboard` seam is what makes the mistake unwriteable.
    /// `SwiftSyntax` keeps the backticks on an escaped identifier, so `` `general` `` would not match a
    /// literal comparison. Same normalisation the inventory gate settled on.
    ///
    /// EVERY name this visitor reads goes through here — the member, the base, the FUNCTION name and the
    /// argument LABEL. Review found this file normalising one, then two, then three of those, each time
    /// leaving the rest raw, which is how a spelling class survives being "fixed" repeatedly. The rule is
    /// not "normalise the name that was reported"; it is "a name is never compared as raw text".
    private static func identifierText(_ token: TokenSyntax) -> String {
      token.identifier?.name ?? token.text
    }

    /// Strips spellings that change the SYNTAX and not the VALUE: parentheses, a one-element tuple, and
    /// an `as` coercion. `to: (.general)` is the same argument as `to: .general` and reaches the same
    /// process-global board, but the parentheses put a `TupleExprSyntax` between the label and the
    /// member so a direct cast finds nothing and the scan reports clean.
    ///
    /// This is the class this whole PR keeps meeting — a comparison narrower than the language — arriving
    /// as WRAPPING rather than as naming. Ask of any expression check what the compiler considers
    /// transparent.
    private static func unwrapped(_ expr: ExprSyntax) -> ExprSyntax {
      if let tuple = expr.as(TupleExprSyntax.self), tuple.elements.count == 1,
        let inner = tuple.elements.first?.expression
      {
        return unwrapped(inner)
      }
      if let cast = expr.as(AsExprSyntax.self) { return unwrapped(cast.expression) }
      // The UNFOLDED cast too. `SwiftParser` leaves `x as T` as a sequence, so handling it in the
      // `.general` visitor and not here left `(PasteService.self as PasteService.Type).copyToClipboard`
      // resolving to nil. Learning that the parser does not fold and then applying it at ONE site is the
      // same half-sweep this file has now corrected three times.
      if let sequence = expr.as(SequenceExprSyntax.self),
        sequence.elements.contains(where: { $0.is(UnresolvedAsExprSyntax.self) }),
        let first = sequence.elements.first
      {
        return unwrapped(first)
      }
      return expr
    }

    private static func trailingName(of base: ExprSyntax?) -> String? {
      // `identifierText` on BOTH halves. Normalising the member name and not the base left
      // `` `NSPasteboard`.general `` unmatched — caught by this suite's own paired row rather than by
      // review, which is the whole reason the rows are generated over the axis instead of hand-picked.
      let unwrappedBase = base.map { unwrapped($0) }
      // `PasteCascadeExecutor().deliver(…)` constructs inline, so the base is itself a CALL. Look
      // through it to the type being constructed — the same "what does this resolve to" question the
      // rest of this file asks about names.
      if let call = unwrappedBase?.as(FunctionCallExprSyntax.self) {
        // `T.init()` spells the same construction as `T()`, and its callee is a member access named
        // `init` — so recursing naively answers "init". Look through the explicit initialiser to the
        // type, the same way `T()` is looked through.
        if let member = unwrapped(call.calledExpression).as(MemberAccessExprSyntax.self),
          identifierText(member.declName.baseName) == "init"
        {
          return trailingName(of: member.base)
        }
        return trailingName(of: call.calledExpression)
      }
      if let reference = unwrappedBase?.as(DeclReferenceExprSyntax.self) {
        return identifierText(reference.baseName)
      }
      if let member = unwrappedBase?.as(MemberAccessExprSyntax.self) {
        // `T.self` is a metatype spelling of `T`, so resolving it to "self" loses the type entirely —
        // `NSPasteboard.self.general` and `PasteCascadeExecutor.self.init()` both hid behind it. Look
        // through it, same as every other transparent spelling.
        if identifierText(member.declName.baseName) == "self" {
          return trailingName(of: member.base)
        }
        return identifierText(member.declName.baseName)
      }
      return nil
    }

    /// Direct access to the process-global board, in any test file.
    ///
    /// Node-based, so `let pb = NSPasteboard\n  .general` is ONE member-access
    /// expression however it is wrapped — the case a line-oriented scanner
    /// missed entirely, reporting a clean pass on a live write.
    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
      // `identifierText` here as well as in the implicit-member check: `NSPasteboard.`general`` is the
      // same property, and `TokenSyntax.text` keeps the backticks. Normalising in only one of the two
      // places is how a "fixed" spelling class comes back.
      if Self.identifierText(node.declName.baseName) == "general",
        Self.trailingName(of: node.base) == "NSPasteboard"
      {
        violations.append(
          Violation(
            file: file, line: line(node),
            reason: "reaches the developer's real clipboard directly (NSPasteboard.general)"))
      }
      return .visitChildren
    }

    /// `let pb: NSPasteboard = .general` — the annotation makes the contextual type unambiguous, so
    /// this needs no inference, only reading what the author already wrote. It compiles, it is the real
    /// clipboard, and neither the member visitor (base is nil) nor the call visitor (there is no call)
    /// saw it.
    ///
    /// KNOWN LIMIT, and the boundary is worth stating precisely: this reads an EXPLICIT annotation. A
    /// board reached by inference (`let pb = makeBoard()`), by alias, or through a helper's return type
    /// still walks past, because catching those needs type resolution this suite deliberately does not
    /// do. That is why it is the THIRD layer and the required seam is the mechanism.
    /// `(.general as NSPasteboard).clearContents()` — the CAST supplies the contextual type, so there is
    /// no annotated binding for the variable visitor to read and the member's base is nil. Explicit
    /// syntax, not inference: the type is written right there.
    ///
    /// **It arrives as a SEQUENCE, not an `AsExprSyntax`.** `SwiftParser` does not fold operators
    /// without an operator table, so `x as T` parses as `SequenceExprSyntax` holding the expression, an
    /// `UnresolvedAsExprSyntax`, and a `TypeExprSyntax`. An `AsExprSyntax` visitor never fires on
    /// unfolded source and reports clean — which is exactly what this suite's own paired row caught,
    /// after review had reported only the spelling. The parser hands you what the LANGUAGE wrote, not
    /// what a compiler pass would later resolve it to.
    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
      let elements = Array(node.elements)
      guard elements.contains(where: { $0.is(UnresolvedAsExprSyntax.self) }),
        elements.contains(where: {
          guard let type = $0.as(TypeExprSyntax.self) else { return false }
          return Self.typeName(of: type.type) == "NSPasteboard"
        }),
        elements.contains(where: {
          guard let member = Self.unwrapped($0).as(MemberAccessExprSyntax.self),
            member.base == nil
          else { return false }
          return Self.identifierText(member.declName.baseName) == "general"
        })
      else { return .visitChildren }
      violations.append(
        Violation(
          file: file, line: line(node),
          reason: "casts the developer's real clipboard into place (`.general as NSPasteboard`)"))
      return .visitChildren
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
      for binding in node.bindings {
        guard let annotation = binding.typeAnnotation?.type,
          Self.typeName(of: annotation) == "NSPasteboard",
          let initial = binding.initializer?.value,
          let member = Self.unwrapped(initial).as(MemberAccessExprSyntax.self),
          member.base == nil,
          Self.identifierText(member.declName.baseName) == "general"
        else { continue }
        violations.append(
          Violation(
            file: file, line: line(node),
            reason: "binds the developer's real clipboard (`: NSPasteboard = .general`)"))
      }
      return .visitChildren
    }

    /// The trailing component of a written type, so `AppKit.NSPasteboard` and an escaped spelling both
    /// resolve. Same rule as every other name in this file: never compared as raw text.
    private static func typeName(of type: TypeSyntax) -> String? {
      // Transparent TYPE wrappers, for the same reason as the expression ones: `NSPasteboard?` and
      // `(NSPasteboard)` name the same type, and `let pb: NSPasteboard? = .general` is the identical
      // explicit binding already covered for the bare spelling.
      if let optional = type.as(OptionalTypeSyntax.self) {
        return typeName(of: optional.wrappedType)
      }
      if let forced = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
        return typeName(of: forced.wrappedType)
      }
      if let tuple = type.as(TupleTypeSyntax.self), tuple.elements.count == 1,
        let inner = tuple.elements.first?.type
      {
        return typeName(of: inner)
      }
      // `T.Type` names T for our purposes — a metatype of the clipboard is still the clipboard's type.
      if let meta = type.as(MetatypeTypeSyntax.self) { return typeName(of: meta.baseType) }
      if let identifier = type.as(IdentifierTypeSyntax.self) {
        return identifierText(identifier.name)
      }
      if let member = type.as(MemberTypeSyntax.self) { return identifierText(member.name) }
      return nil
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
      // Unwrap here too. The rule is "what does the compiler treat as transparent", and it has to hold
      // at EVERY expression this visitor inspects — `(executor.deliver)(request)` is the same call, and
      // applying the rule at three sites and not the other two is how the class comes back.
      guard let callee = Self.unwrapped(node.calledExpression).as(MemberAccessExprSyntax.self) else {
        return .visitChildren
      }
      let baseName = Self.trailingName(of: callee.base)

      if let base = baseName,
        let banned = ClipboardIsolationFreezeTests.boardReachingTypes[base],
        banned.contains(Self.identifierText(callee.declName.baseName))
      {
        violations.append(
          Violation(
            file: file, line: line(node),
            reason:
              "\(base).\(Self.identifierText(callee.declName.baseName)) reaches the real clipboard on its fallback path and bypasses the required wiring seam"
          ))
        return .visitChildren
      }

      guard baseName == "PasteService" else { return .visitChildren }

      let calleeName = Self.identifierText(callee.declName.baseName)

      if ClipboardIsolationFreezeTests.boardlessClipboardFunctions.contains(calleeName) {
        violations.append(
          Violation(
            file: file, line: line(node),
            reason:
              "PasteService.\(calleeName) writes NSPasteboard.general internally and dispatches Cmd+V — no test may call it"
          ))
        return .visitChildren
      }

      guard ClipboardIsolationFreezeTests.clipboardFunctions.contains(calleeName) else {
        return .visitChildren
      }

      let name = Self.identifierText(callee.declName.baseName)

      guard isAllowlisted else {
        violations.append(
          Violation(
            file: file, line: line(node),
            reason: "calls clipboard-capable PasteService.\(name) from a non-allowlisted test"))
        return .visitChildren
      }

      // Inspect THIS call's own arguments, never the enclosing statement. A
      // statement-wide search blesses `consume(from: x, snap: PasteService.saveClipboard())`,
      // where the `from:` belongs to a different call and the clipboard call
      // still defaults to the user's board.
      let boardArguments = node.arguments.filter { argument in
        // Labels too. An escaped `` `to`: `` would not match, the call would look board-LESS, and the
        // author would be told their correctly-boarded call defaults to the user's clipboard — the
        // confident-wrong-subject direction rather than the silent one, and still worth closing.
        guard let label = argument.label.map({ Self.identifierText($0) }) else { return false }
        return ClipboardIsolationFreezeTests.boardLabels.contains(label)
      }

      // NAMING a board is not the same as naming a SAFE one. `to: .general` is Swift's implicit-member
      // spelling of `NSPasteboard.general` — the process-global board, written shorter — so the call
      // satisfied the `to:` requirement while still overwriting the developer's clipboard, and the scan
      // reported clean. Silent, and it defeats the one thing this suite exists to prevent.
      //
      // The base is nil for an implicit member, which is exactly why the qualified-base fix above could
      // not see it: that one widened what counts as a base, and this is the case with NO base at all.
      // Same class as every other finding in this arc — a spelling the compiler treats as identical.
      let namesTheGlobalBoard = boardArguments.contains { argument in
        guard let member = Self.unwrapped(argument.expression).as(MemberAccessExprSyntax.self),
          member.base == nil
        else { return false }
        return Self.identifierText(member.declName.baseName) == "general"
      }

      if namesTheGlobalBoard {
        violations.append(
          Violation(
            file: file, line: line(node),
            reason:
              "PasteService.\(name) is handed `.general` — that IS the developer's real clipboard, just spelled shorter"
          ))
      } else if boardArguments.isEmpty {
        violations.append(
          Violation(
            file: file, line: line(node),
            reason:
              "PasteService.\(name) without an explicit to:/from:/on: board — defaults to the user's clipboard"
          ))
      }
      return .visitChildren
    }
  }

  // MARK: Scanning

  static func violations(inSource source: String, file: String) -> [Violation] {
    let tree = Parser.parse(source: source)
    let visitor = ClipboardVisitor(
      converter: SourceLocationConverter(fileName: file, tree: tree),
      file: file,
      isAllowlisted: (file as NSString).lastPathComponent == allowlistedFile)
    visitor.walk(tree)
    return visitor.violations
  }

  private final class SnapshotRoutingVisitor: SyntaxVisitor {
    private(set) var snapshotCalls = 0
    private(set) var callsUsingExecutorBoard = 0

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
      guard let member = node.calledExpression.as(MemberAccessExprSyntax.self),
        member.declName.baseName.text == "snapshotForDelivery",
        member.base?.trimmedDescription == "ClipboardCleanup"
      else { return .visitChildren }

      snapshotCalls += 1
      if node.arguments.count == 1, let argument = node.arguments.first,
        argument.label?.text == "from",
        argument.expression.trimmedDescription == "pasteboard"
      {
        callsUsingExecutorBoard += 1
      }
      return .visitChildren
    }
  }

  private static func scanTests() throws -> (violations: [Violation], filesScanned: Int) {
    let root = RepoRoot.sourceURL("Tests")
    var found: [Violation] = []
    var scanned = 0

    guard
      let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles, .skipsPackageDescendants],
        errorHandler: { _, _ in false })
    else {
      // A nil enumerator with no callback would otherwise fall through as zero
      // hits — a silent, wrongly-clean scan rather than a failure.
      throw ClipboardScanError.couldNotEnumerate(root.path)
    }

    let prefix = RepoRoot.url.path + "/"
    while let url = enumerator.nextObject() as? URL {
      guard url.pathExtension == "swift" else { continue }
      // THIS FILE IS SCANNED TOO. It used to exempt itself "so the guard can never police itself",
      // which was backwards: an instrument that stops checking one file reports clean about that file
      // forever, and the one file guaranteed to contain clipboard vocabulary is this one. Real
      // clipboard access added here would have overwritten the developer's board with the scan green.
      //
      // The exemption's stated reason was this suite's fixtures, and it was already unnecessary: the
      // fixtures are string literals and the parser excludes those STRUCTURALLY, which is the same
      // control the `prosePasses` and `multilineStringPasses` rows assert. Removing the skip therefore
      // costs no false positives and closes a self-exemption.
      let source = try String(contentsOf: url, encoding: .utf8)
      scanned += 1
      found += violations(
        inSource: source, file: url.path.replacingOccurrences(of: prefix, with: ""))
    }
    return (found, scanned)
  }

  enum ClipboardScanError: Error { case couldNotEnumerate(String) }

  // MARK: The guard

  @Test("no test reaches the developer's real clipboard")
  func noTestTouchesTheRealClipboard() throws {
    let (found, scanned) = try Self.scanTests()

    // Fail closed: scanning nothing is an instrument fault, not a pass.
    #expect(scanned > 100, "expected to scan the whole test tree, scanned \(scanned) files")

    #expect(
      found.isEmpty,
      """
      \(found.count) test site(s) can write the developer's real clipboard:
      \(found.map(\.description).joined(separator: "\n"))

      The restore is guarded on changeCount and DECLINES whenever a parallel
      suite touched the board, so whatever the test wrote stays there.
        - Wiring tests: pass `copyToClipboard:` and assert on the recorder.
        - PasteService tests: use `NSPasteboard.withUniqueName()` and pass it
          explicitly via `to:` / `from:` / `on:`.
      """)
  }

  @Test("every paste route inherits cleanup through the executor's board")
  func pasteRoutesUseCleanupSnapshot() throws {
    let url = RepoRoot.sourceURL("Sources/EnviousWisprPipeline/PasteCascadeExecutor.swift")
    let source = try String(contentsOf: url, encoding: .utf8)
    let tree = Parser.parse(source: source)
    let visitor = SnapshotRoutingVisitor(viewMode: .sourceAccurate)
    visitor.walk(tree)

    #expect(
      visitor.snapshotCalls == 3,
      "expected the three clipboard paste routes, found \(visitor.snapshotCalls)")
    #expect(
      visitor.callsUsingExecutorBoard == visitor.snapshotCalls,
      "a paste route bypasses cleanup inheritance or silently defaults to the real clipboard")
  }

  // MARK: Two-way controls
  //
  // A guard that merely stops firing is indistinguishable from one that was
  // deleted, so every fixture below asserts a DIRECTION. The four "caught"
  // fixtures are the four defects Codex found in the shell-scanner version;
  // each one passed that scanner and fails this parser.

  @Test("direct NSPasteboard.general is caught")
  func catchesDirectAccess() {
    let hits = Self.violations(
      inSource: "func f() { let pb = NSPasteboard.general; pb.clearContents() }",
      file: "Some.swift")
    #expect(hits.count == 1)
  }

  @Test("WRAPPED member access is caught (the shell scanner missed this entirely)")
  func catchesWrappedMemberAccess() {
    let hits = Self.violations(
      inSource: """
        func f() {
          let pb = NSPasteboard
            .general
          pb.clearContents()
        }
        """,
      file: "Some.swift")
    #expect(hits.count == 1, "a line-oriented scanner emitted two records and matched neither")
  }

  @Test("an indirect zero-argument saveClipboard() is caught")
  func catchesIndirectSave() {
    let hits = Self.violations(
      inSource: "func f() { let snap = PasteService.saveClipboard() }", file: "Other.swift")
    #expect(hits.count == 1)
  }

  @Test("an unlabelled clipboard call inside the allowlisted suite is still caught")
  func catchesUnlabelledCallInAllowlistedSuite() {
    let hits = Self.violations(
      inSource: #"func f() { PasteService.copyToClipboard("x") }"#,
      file: "PasteServiceClipboardTests.swift")
    #expect(hits.count == 1)
  }

  @Test("a board label belonging to a DIFFERENT call does not bless the clipboard call")
  func labelOnAnotherCallDoesNotBless() {
    // The statement contains `from:`, but it is an argument of `consume`, not of
    // `saveClipboard()`, which still defaults to the user's board.
    let hits = Self.violations(
      inSource: "func f() { consume(from: source, snapshot: PasteService.saveClipboard()) }",
      file: "PasteServiceClipboardTests.swift")
    #expect(hits.count == 1, "argument scope must be the matched call, not the whole statement")
  }

  @Test("an escaped quote cannot hide a live call later on the same line")
  func escapedQuoteCannotHideACall() {
    let hits = Self.violations(
      inSource: #"func f() { let s = "\""; PasteService.copyToClipboard("leak") }"#,
      file: "PasteServiceClipboardTests.swift")
    #expect(hits.count == 1)
  }

  @Test("explicitly-boarded calls pass")
  func allowsExplicitlyBoardedCalls() {
    let hits = Self.violations(
      inSource: """
        func f() {
          let pb = NSPasteboard.withUniqueName()
          PasteService.copyToClipboard("x", to: pb)
          _ = PasteService.saveClipboard(from: pb)
          PasteService.restoreClipboard(snap, changeCountAfterPaste: 1, on: pb)
        }
        """,
      file: "PasteServiceClipboardTests.swift")
    #expect(hits.isEmpty)
  }

  @Test("a WRAPPED explicitly-boarded call passes")
  func allowsWrappedBoardedCall() {
    let hits = Self.violations(
      inSource: """
        func f() {
          let count = PasteService.copyToClipboardReturningChangeCount(
            "text", to: pb)
        }
        """,
      file: "PasteServiceClipboardTests.swift")
    #expect(hits.isEmpty)
  }

  @Test("prose describing the defect is NOT a violation")
  func prosePasses() {
    let hits = Self.violations(
      inSource: """
        // This test used to touch NSPasteboard.general and call PasteService.saveClipboard().
        /* Block comment naming NSPasteboard.general too. */
        func f() { let x = 1 }
        """,
      file: "Some.swift")
    #expect(hits.isEmpty, "a guard that fires on its own explanation trains evasion")
  }

  @Test("a MULTILINE string fixture is not scanned as code")
  func multilineStringPasses() {
    // The shell scanner reset its in-string state per line and read this as
    // executable, producing a failing CI verdict for a harmless fixture.
    let hits = Self.violations(
      inSource: #"""
        func f() {
          let doc = """
            NSPasteboard.general is the user's clipboard.
            PasteService.saveClipboard() defaults to it.
            """
        }
        """#,
      file: "Some.swift")
    #expect(hits.isEmpty)
  }

  @Test("a RAW string fixture is not scanned as code")
  func rawStringPasses() {
    let hits = Self.violations(
      inSource: ##"func f() { let s = #"NSPasteboard.general"# }"##,
      file: "Some.swift")
    #expect(hits.isEmpty)
  }

  // MARK: Module-qualified spellings
  //
  // The axis is HOW THE BASE IS WRITTEN, swept over both matchers. Bare and module-qualified are the
  // same thing to the compiler, so a guard that accepts only the bare form fails quietly. Each caught
  // row is paired with a near-identical row that must still pass, so a matcher widened until it stops
  // discriminating fails here rather than looking clean.

  @Test(
    "a module-qualified base is the same access and is caught",
    arguments: [
      "func f() { let pb = AppKit.NSPasteboard.general; pb.clearContents() }",
      "func f() { let snap = EnviousWisprServices.PasteService.saveClipboard() }",
      "func f() { let pb = AppKit\n  .NSPasteboard\n  .general }",
    ])
  func catchesModuleQualifiedAccess(source: String) {
    let hits = Self.violations(inSource: source, file: "Some.swift")
    #expect(hits.count == 1, "a module-qualified spelling walked past the guard: \(source)")
  }

  @Test(
    "a DIFFERENT type whose trailing name is not ours still passes",
    arguments: [
      // Rejected halves: matching the trailing name must not match a different type entirely.
      "func f() { let x = MyThing.general }",
      "func f() { let x = Some.OtherService.saveClipboard() }",
      "func f() { let x = pasteboard.general }",
    ])
  func doesNotFireOnUnrelatedTypes(source: String) {
    #expect(
      Self.violations(inSource: source, file: "Some.swift").isEmpty,
      "the guard fired on an unrelated type: \(source)")
  }

  /// The axis is WHAT THE BOARD ARGUMENT RESOLVES TO, not whether one was written. `.general` in a
  /// board position is the real clipboard; a unique board is not. Each caught row is paired with the
  /// near-identical safe row, so a matcher widened until it rejects every boarded call fails here.
  @Test(
    "an implicit .general in a board position is the real clipboard",
    arguments: [
      // (call as written inside the allowlisted suite, violations expected)
      (#"PasteService.copyToClipboard("x", to: .general)"#, 1),
      (#"_ = PasteService.saveClipboard(from: .general)"#, 1),
      (#"PasteService.restoreClipboard(s, changeCountAfterPaste: 1, on: .general)"#, 1),
      (#"PasteService.copyToClipboard("x", to: NSPasteboard.general)"#, 1),
      // Wrapping and escaping change the syntax, not the board.
      (#"PasteService.copyToClipboard("x", to: (.general))"#, 1),
      (#"PasteService.copyToClipboard("x", to: ((.general)))"#, 1),
      (##"PasteService.copyToClipboard("x", to: NSPasteboard.`general`)"##, 1),
      (##"PasteService.copyToClipboard("x", to: `NSPasteboard`.general)"##, 1),
      // The FUNCTION name and the argument LABEL are names too.
      (##"PasteService.`copyToClipboard`("x", to: .general)"##, 1),
      (##"PasteService.`copyToClipboard`("x")"##, 1),
      (##"PasteService.copyToClipboard("x", `to`: .general)"##, 1),
      // Safe halves: a unique board, however it is spelled, must still pass.
      (#"PasteService.copyToClipboard("x", to: pb)"#, 0),
      (#"PasteService.copyToClipboard("x", to: NSPasteboard.withUniqueName())"#, 0),
      (#"_ = PasteService.saveClipboard(from: board)"#, 0),
      (#"PasteService.copyToClipboard("x", to: (pb))"#, 0),
      // Safe halves for the same two axes: escaped spellings of a UNIQUE board must still pass.
      (##"PasteService.`copyToClipboard`("x", to: pb)"##, 0),
      (##"PasteService.copyToClipboard("x", `to`: pb)"##, 0),
    ])
  func implicitGeneralInABoardPositionIsCaught(call: String, expected: Int) {
    let hits = Self.violations(
      inSource: "func f() { \(call) }", file: "PasteServiceClipboardTests.swift")
    #expect(hits.count == expected, "call: \(call) -> \(hits.map(\.description))")
  }

  // RENAMED AND RE-AIMED BY #2170. `pasteToActiveApp` gained a board parameter, so it is no longer
  // "an entry point with no board parameter" and the rows below no longer test that property — they
  // test that a BARE call is still a violation, which is true for a different reason: a bare call takes
  // the `.general` default and writes the developer's real clipboard.
  //
  // The accepted twin is new and is the row that matters now. Without it, moving the function into the
  // boarded set could have stopped it being classified at all and every rejected row would still pass.
  @Test(
    "a bare call to a boarded entry point is still banned, and a boarded one is not",
    arguments: [
      // (source, violations) — a bare call defaults to `.general`, so it is banned even in the
      // allowlisted suite.
      (#"func f() { _ = PasteService.pasteToActiveApp("fixture") }"#, 1),
      (##"func f() { _ = PasteService.`pasteToActiveApp`("fixture") }"##, 1),
      (#"func f() { _ = EnviousWisprServices.PasteService.pasteToActiveApp("x") }"#, 1),
      // ACCEPTED TWIN: passing a board is the whole point of the parameter.
      (#"func f() { _ = PasteService.pasteToActiveApp("x", to: pb) }"#, 0),
      // Safe half: a same-named method on an unrelated type is not ours.
      (#"func f() { _ = Other.pasteToActiveApp("x") }"#, 0),
    ])
  func aBareCallToABoardedEntryPointIsBanned(source: String, expected: Int) {
    let hits = Self.violations(inSource: source, file: "PasteServiceClipboardTests.swift")
    #expect(hits.count == expected, "source: \(source) -> \(hits.map(\.description))")
  }

  @Test(
    "a board-reaching method on another type is banned too",
    arguments: [
      (#"func f() async { _ = await PasteCascadeExecutor().deliver(request) }"#, 1),
      (#"func f() async { _ = await EnviousWisprPipeline.PasteCascadeExecutor().deliver(r) }"#, 1),
      // Every transparent wrapper, at every position this visitor inspects.
      (#"func f() async { _ = await PasteCascadeExecutor.init().deliver(request) }"#, 1),
      (#"func f() async { _ = await (PasteCascadeExecutor.init)().deliver(request) }"#, 1),
      (#"func f() async { _ = await (PasteCascadeExecutor()).deliver(request) }"#, 1),
      (#"func f() async { _ = await PasteCascadeExecutor.self.init().deliver(request) }"#, 1),
      (#"func f() { AIAvailabilityCoordinator().copyDiagnosticsToClipboard() }"#, 1),
      (#"func f() { NSPasteboard.self.general.clearContents() }"#, 1),
      (#"func f() { (.general as NSPasteboard).clearContents() }"#, 1),
      (#"func f() { (PasteService.self as PasteService.Type).copyToClipboard("x") }"#, 1),
      // Safe halves: a different method on that type, and `deliver` on anything else.
      (#"func f() { _ = PasteCascadeExecutor.clipboardOnlyTelemetryExtra(x) }"#, 0),
      (#"func f() async { _ = await wiring.deliver("hello") }"#, 0),
      (#"func f() async { _ = await pasteSink.deliver(request) }"#, 0),
      (#"func f() { AIAvailabilityCoordinator().refresh() }"#, 0),
      (#"func f() { (board as NSPasteboard).clearContents() }"#, 0),
    ])
  func aBoardReachingMethodOnAnotherTypeIsBanned(source: String, expected: Int) {
    let hits = Self.violations(inSource: source, file: "Some.swift")
    #expect(hits.count == expected, "source: \(source) -> \(hits.map(\.description))")
  }

  @Test(
    "a typed binding of .general is the real clipboard",
    arguments: [
      (#"func f() { let pb: NSPasteboard = .general; pb.clearContents() }"#, 1),
      (#"func f() { let pb: AppKit.NSPasteboard = .general }"#, 1),
      (#"func f() { let pb: NSPasteboard = (.general) }"#, 1),
      (#"func f() { let pb: NSPasteboard? = .general }"#, 1),
      (#"func f() { let pb: (NSPasteboard) = .general }"#, 1),
      (#"func f() { let pb: NSPasteboard! = .general }"#, 1),
      // Safe halves: a unique board, and a `.general` on some other type entirely.
      (#"func f() { let pb: NSPasteboard = NSPasteboard.withUniqueName() }"#, 0),
      (#"func f() { let x: MyThing = .general }"#, 0),
    ])
  func aTypedBindingOfGeneralIsCaught(source: String, expected: Int) {
    let hits = Self.violations(inSource: source, file: "Some.swift")
    #expect(hits.count == expected, "source: \(source) -> \(hits.map(\.description))")
  }

  @Test("a module-qualified call that DOES name its board still passes")
  func allowsQualifiedBoardedCall() {
    let hits = Self.violations(
      inSource: #"func f() { EnviousWisprServices.PasteService.copyToClipboard("x", to: pb) }"#,
      file: "PasteServiceClipboardTests.swift")
    #expect(hits.isEmpty, "widening the base match must not un-bless an explicit board")
  }
}
