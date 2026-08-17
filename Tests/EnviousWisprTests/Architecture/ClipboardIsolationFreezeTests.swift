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
@Suite("Clipboard isolation freeze (#2146)")
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

    /// Direct access to the process-global board, in any test file.
    ///
    /// Node-based, so `let pb = NSPasteboard\n  .general` is ONE member-access
    /// expression however it is wrapped — the case a line-oriented scanner
    /// missed entirely, reporting a clean pass on a live write.
    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
      if node.declName.baseName.text == "general",
        let base = node.base?.as(DeclReferenceExprSyntax.self),
        base.baseName.text == "NSPasteboard"
      {
        violations.append(
          Violation(
            file: file, line: line(node),
            reason: "reaches the developer's real clipboard directly (NSPasteboard.general)"))
      }
      return .visitChildren
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
      guard let callee = node.calledExpression.as(MemberAccessExprSyntax.self),
        let base = callee.base?.as(DeclReferenceExprSyntax.self),
        base.baseName.text == "PasteService",
        ClipboardIsolationFreezeTests.clipboardFunctions.contains(callee.declName.baseName.text)
      else { return .visitChildren }

      let name = callee.declName.baseName.text

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
      let namesBoard = node.arguments.contains { argument in
        guard let label = argument.label?.text else { return false }
        return ClipboardIsolationFreezeTests.boardLabels.contains(label)
      }

      if !namesBoard {
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
      // This file's own fixtures are string literals, which the parser excludes
      // structurally — but skip it anyway so the guard can never police itself.
      guard url.lastPathComponent != "ClipboardIsolationFreezeTests.swift" else { continue }
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
}
