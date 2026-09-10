import Foundation
import SwiftParser
import SwiftSyntax
import Testing

/// #2449: an executor for `swift-testing-patterns.md` `swift-testing-no-negated-expect`.
///
/// **Drift Guard.** When this fails, no user sees anything — we added a hidden negation to a test
/// assertion. It matters because of what the rule says: `#expect(!value)` reports "false is not
/// true" and hides the failing subexpression, so the next person debugging a red row learns
/// nothing from it. `#expect(value == false)` prints the value.
///
/// ## Why this exists at all, which is the whole point of #2449
///
/// The rule was written in May 2026 and is correct, well worded and known. It had no EXECUTOR, and
/// several rounds of people reading carefully is what "no executor" looks like from the inside —
/// #1989's Codex round caught a negated assertion that had already passed a plan review, a local
/// pass and a build. A written prohibition nobody runs does not stop the thing it prohibits.
///
/// ## Why it parses rather than greps
///
/// `swift-patterns.md` RULE: scan-swift-source-with-swiftparser-never-a-hand-rolled-lexer, and the
/// hazard is not hypothetical here. Measured while scoping this: `/usr/bin/grep -rn
/// "\.sheet(isPresented:" Sources/` returns 4 hits and one of them is a DOC COMMENT
/// (`LivePreviewSettingsView.swift:50`) describing why the form is wrong. A text scan of Swift
/// cannot tell a prohibition from its own explanation. A macro-expansion node can.
///
/// ## The invariant: the SET of hidden negations may only shrink
///
/// The rule grandfathers existing sites "until edited", and there are over a thousand. A whole-tree
/// ban is red on arrival and gets switched off; a diff-scoped lint would need the test to shell out
/// to git. So the baseline freezes the negations that exist, and none may be added.
///
/// **The key is the negated CONDITION's own text, not a per-file count** (PR #2771 cloud review
/// r2). A count cannot see a swap: delete one grandfathered negation and add a different one in the
/// same file and the count is unchanged, so a brand-new hidden negation lands with nothing failing.
/// The rule's words are "new or MODIFIED", and only an identity can see a modification. With text
/// as the key a swap reads as one line no longer earned plus one line never granted, and both
/// halves fail.
///
/// **Line numbers are deliberately NOT part of the key.** Every edit above a site would move it,
/// so the baseline would churn on changes that add no negation at all.
///
/// The equality — a baseline line must still name something real — is the reasoning
/// `TestInventoryFreezeTests` records for its own list. An entry left behind is a REUSABLE
/// EXEMPTION: a later assertion landing on the same text inherits it for free.
@Suite(.tags(.driftGuard))
struct NegatedExpectRatchetTests {

  private static let baselinePath = "scripts/negated-expect-baseline.txt"

  private static let header = """
    # Hidden negations in test assertions, frozen one line per distinct assertion (#2449).
    # Owner: .claude/rules/swift-testing-patterns.md `swift-testing-no-negated-expect`.
    #
    # The SET may only shrink. Adding a negation fails; so does leaving a line here after the
    # assertion it names is gone, because that line is an exemption the next change inherits.
    #
    # Keyed by "<count>\\t<path relative to the repo root>\\t<the negated condition, whitespace
    # collapsed>". The condition rather than a per-file count, so that swapping one negation for
    # another inside a file cannot pass unnoticed.
    # Regenerate: TEST_RUNNER_EW_WRITE_NEGATED_EXPECT_BASELINE=1 scripts/xcode-test.sh --filter EnviousWisprTests/NegatedExpectRatchetTests
    # (the TEST_RUNNER_ prefix is load-bearing — without it the row SKIPS, the run greens, and the
    # baseline is untouched, which reads exactly like "nothing needed regenerating")
    """

  // MARK: - Finding the sites

  /// The two Swift Testing macros that take a boolean condition first.
  private static let conditionMacros: Set<String> = ["expect", "require"]

  /// Peel one transparent layer off an expression, or return nil when there is none left.
  ///
  /// **The set is taken from the PRODUCING CODE, not from imagination.** These are every
  /// single-child wrapper expression the pinned swift-syntax generates:
  /// `grep -rhoE "public struct [A-Za-z]+ExprSyntax" <checkout>/Sources/SwiftSyntax/generated/`.
  /// Re-run that when the pin moves. A wrapper this does not know about is a hole, and the
  /// fixture row at the bottom of this file is what would notice one going missing.
  ///
  /// A parenthesised condition arrives as a one-element unlabelled tuple, which is why
  /// `#expect((!value))` needs peeling too.
  private static func peel(_ expr: ExprSyntax) -> ExprSyntax? {
    if let e = expr.as(TryExprSyntax.self) { return e.expression }
    if let e = expr.as(AwaitExprSyntax.self) { return e.expression }
    if let e = expr.as(UnsafeExprSyntax.self) { return e.expression }
    if let e = expr.as(BorrowExprSyntax.self) { return e.expression }
    if let e = expr.as(ConsumeExprSyntax.self) { return e.expression }
    if let e = expr.as(CopyExprSyntax.self) { return e.expression }
    if let e = expr.as(TupleExprSyntax.self), e.elements.count == 1,
      let only = e.elements.first, only.label == nil
    {
      return only.expression
    }
    return nil
  }

  /// A hidden negation is a leading `!` on the macro's FIRST argument, which is the condition.
  ///
  /// **The `!` is not necessarily the OUTERMOST node**, and reading it as if it were is how the
  /// first version of this shipped a hole: `#expect(try !words.isEmpty)` arrives as a
  /// `TryExprSyntax` wrapping the negation, so the check accepted it and the baseline undercounted
  /// a real site in `SmartImportStableStoreTests`. Found by cloud review on PR #2771. Peel every
  /// transparent layer first, then ask.
  ///
  /// A `!` anywhere else inside the condition is ordinary Swift and is not what the rule forbids.
  private static func isHiddenNegation(_ macro: MacroExpansionExprSyntax) -> Bool {
    guard conditionMacros.contains(macro.macroName.text) else { return false }
    guard let first = macro.arguments.first, first.label == nil else { return false }
    var condition = first.expression
    while let inner = peel(condition) { condition = inner }
    guard let prefix = condition.as(PrefixOperatorExprSyntax.self) else { return false }
    return prefix.operator.text == "!"
  }

  /// One line of source, with every run of whitespace collapsed, so a reformat of an untouched
  /// assertion does not read as a different assertion.
  private static func normalised(_ expr: ExprSyntax) -> String {
    expr.description
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
  }

  /// Every condition-taking macro call in one tree, and the text of each negated condition.
  private static func counts(in node: Syntax) -> (macros: Int, negated: [String]) {
    var macros = 0
    var negated: [String] = []
    if let macro = node.as(MacroExpansionExprSyntax.self),
      conditionMacros.contains(macro.macroName.text)
    {
      macros += 1
      if isHiddenNegation(macro), let first = macro.arguments.first {
        negated.append(normalised(first.expression))
      }
    }
    for child in node.children(viewMode: .sourceAccurate) {
      let sub = counts(in: child)
      macros += sub.macros
      negated.append(contentsOf: sub.negated)
    }
    return (macros, negated)
  }

  /// A distinct hidden negation: which file, and the condition's own text. Two identical
  /// assertions in one file share a key and are counted, which is why the value is a count.
  private struct Site: Hashable, Comparable {
    let file: String
    let condition: String
    var line: String { "\(file)\t\(condition)" }
    static func < (a: Site, b: Site) -> Bool { a.line < b.line }
  }

  private struct Sweep {
    var negations: [Site: Int] = [:]
    var totalMacros = 0
    var filesRead = 0
    var totalNegations: Int { negations.values.reduce(0, +) }
  }

  private static func sweep() throws -> Sweep {
    let root = RepoRoot.url.path
    let testsDir = root + "/Tests"
    var out = Sweep()
    guard
      let walker = FileManager.default.enumerator(
        at: URL(fileURLWithPath: testsDir), includingPropertiesForKeys: nil)
    else {
      Issue.record("cannot enumerate \(testsDir)")
      return out
    }
    for case let url as URL in walker where url.pathExtension == "swift" {
      let text = try String(contentsOf: url, encoding: .utf8)
      out.filesRead += 1
      let tree = Parser.parse(source: text)
      let found = counts(in: Syntax(tree))
      out.totalMacros += found.macros
      guard !found.negated.isEmpty else { continue }
      var relative = url.path
      if relative.hasPrefix(root + "/") { relative.removeFirst(root.count + 1) }
      for condition in found.negated {
        out.negations[Site(file: relative, condition: condition), default: 0] += 1
      }
    }
    return out
  }

  // MARK: - The baseline

  private static func baseline() throws -> [Site: Int] {
    let text = try String(contentsOf: RepoRoot.sourceURL(baselinePath), encoding: .utf8)
    var out: [Site: Int] = [:]
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
      let row = String(line)
      guard !row.hasPrefix("#"), !row.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
      let parts = row.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
      guard parts.count == 3, let count = Int(parts[0]) else {
        Issue.record("unparseable baseline row, so the whole file is untrusted: \(row)")
        continue
      }
      out[Site(file: String(parts[1]), condition: String(parts[2]))] = count
    }
    return out
  }

  /// Rewrites the freeze. Env-gated so CI can never regenerate the thing it checks against — a
  /// baseline that rewrites itself on failure is not a baseline.
  @Test(
    "regenerate the frozen counts",
    .enabled(if: ProcessInfo.processInfo.environment["EW_WRITE_NEGATED_EXPECT_BASELINE"] == "1"))
  func regenerateBaseline() throws {
    let found = try Self.sweep()
    let body =
      found.negations
      .sorted { $0.key < $1.key }
      .map { "\($0.value)\t\($0.key.line)" }
      .joined(separator: "\n")
    try (Self.header + "\n" + body + "\n").write(
      to: RepoRoot.sourceURL(Self.baselinePath), atomically: true, encoding: .utf8)
    print("Wrote \(found.negations.count) distinct site(s), \(found.totalNegations) assertion(s).")
  }

  // MARK: - The gate

  /// **A regeneration run is not a verification run, and must not pretend to be one.** Swift
  /// Testing schedules a suite's tests concurrently, so with the write variable set this row
  /// races the row that rewrites the baseline: it can finish its sweep against the OLD file and
  /// report stale entries for assertions the regeneration was in the middle of removing. That
  /// reads as a real failure of a regeneration that in fact succeeded. Found by cloud review on
  /// PR #2771.
  ///
  /// So the gate stands down when the baseline is being rewritten. **A skipped receipt is not a
  /// passed receipt**: a run with that variable set has verified NOTHING, and the run that
  /// matters is the ordinary one afterwards.
  @Test(
    "no hidden negation is added, and no frozen line outlives its assertion",
    .enabled(
      if: ProcessInfo.processInfo.environment["EW_WRITE_NEGATED_EXPECT_BASELINE"] != "1"))
  func theSetOnlyShrinks() throws {
    let found = try Self.sweep()

    // Fail closed twice. An empty sweep and a parser that stopped recognising the macro both look
    // like "nobody negates anything" from the assertions below, and both are instrument failures.
    try #require(
      found.filesRead > 200,
      "read only \(found.filesRead) test files — the walk is broken, not the tree")
    try #require(
      found.totalMacros > 1000,
      """
      found only \(found.totalMacros) #expect/#require calls across \(found.filesRead) files. The
      parser is not recognising the macro, so every count below would be zero for the wrong reason.
      """)

    let frozen = try Self.baseline()
    try #require(
      frozen.count > 500,
      "baseline lists \(frozen.count) sites; refusing to treat that as 'everything is new'")

    let gained =
      found.negations
      .filter { $0.value > (frozen[$0.key] ?? 0) }
      .sorted { $0.key < $1.key }
    #expect(
      gained.isEmpty,
      """
      \(gained.count) hidden negation(s) were added. Write the comparison instead:
      `#expect(value == false)`, `#expect(x != y)` — never `#expect(!value)`, and the `!` still
      counts through a `try`, an `await` or a bracket.
      Owner: .claude/rules/swift-testing-patterns.md `swift-testing-no-negated-expect`.

      \(gained.map { "  \($0.key.file)\n    \($0.key.condition)" }.joined(separator: "\n"))
      """)

    let stale =
      frozen
      .filter { $0.value > (found.negations[$0.key] ?? 0) }
      .sorted { $0.key < $1.key }
    #expect(
      stale.isEmpty,
      """
      \(stale.count) frozen line(s) no longer name an assertion that exists. Each is an exemption a
      later assertion inherits by landing on the same text, so regenerate:
      TEST_RUNNER_EW_WRITE_NEGATED_EXPECT_BASELINE=1 scripts/xcode-test.sh --filter EnviousWisprTests/NegatedExpectRatchetTests

      \(stale.map { "  \($0.key.file)\n    \($0.key.condition)" }.joined(separator: "\n"))
      """)
  }

  /// The instrument's own two-way control. Without this, a detector that matched NOTHING would make
  /// the gate above pass forever, and a detector that matched EVERY macro would make it fail on the
  /// first honest assertion — neither is visible from a green ratchet.
  @Test("the detector separates a hidden negation from an ordinary assertion")
  func theDetectorIsTwoWay() throws {
    let source = """
      func rows() async throws {
        #expect(value == false)
        #expect(a.contains("!"))
        #expect(x != y)
        somethingElse(!value)

        #expect(!value)
        #expect(!(x == y))
        #expect((!value))
        #expect(try !thing().isEmpty)
        #expect(await !thing())
        #expect(try await !thing())
        #require(!maybe)
      }
      """
    let found = Self.counts(in: Syntax(Parser.parse(source: source)))
    #expect(
      found.macros == 10,
      """
      saw \(found.macros) condition macros in the fixture, expected 10. The `somethingElse(!value)`
      row is not one of these macros and must never be counted as one.
      """)
    #expect(
      found.negated.count == 7,
      """
      saw \(found.negated.count) hidden negations in the fixture, expected 7.

      The first three macro rows are honest and must NOT count: a comparison, a `!` inside a
      string literal, and an inequality. The `!` on a non-macro call must not count either.

      The last seven are the same negation wearing every wrapper the peel loop knows about. A
      DROP means a wrapper stopped being peeled; a RISE means an honest row started counting.
      """)
  }
}
