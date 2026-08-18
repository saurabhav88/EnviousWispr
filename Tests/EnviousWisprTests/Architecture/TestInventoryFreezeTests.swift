import Foundation
import SwiftParser
import SwiftSyntax
import Testing

/// Every test suite declares WHICH OF FOUR THINGS it protects, and this suite is what enforces it.
///
/// Owner: `.claude/rules/testing-philosophy.md`
/// RULE: every-test-declares-which-of-four-things-it-protects
///
/// The #2141 audit found 978 tests counted as safety for the user that protect something else, and ZERO
/// tests crossing a real boundary. All four classes are legitimate; the defect was arithmetic. Nothing
/// ever showed the split, so this prints it and refuses a NEW suite that declares nothing.
///
/// WHY THIS IS A SWIFT TEST AND NOT A SHELL SCRIPT — the history is the design, so it stays.
/// The first version was a hand-rolled awk lexer over Swift. Four Codex rounds found ELEVEN defects and
/// every one was a lexical form the scanner did not model: escaped quotes, inline block comments, a
/// `@Test` attribute wrapped by swift-format, a `/*` inside a glob in a doc comment, a suite title
/// containing the word "class", a tag mentioned in a trailing comment. Severity fell across rounds but
/// nothing suggested the next round was the last.
///
/// `EngineMutationInventoryFreezeTests` had already walked this exact arc and written down the answer: a
/// hand-rolled scanner, five consecutive review rounds on comment and string handling with no convergence,
/// then a web-grounded council consult naming it a KNOWN class with SwiftLint's multi-year
/// regex-to-SwiftSyntax migration as precedent. A real parser is the right fix once a scanner needs this
/// level of lexical precision. That conclusion was committed a month before this suite was written, and
/// re-deriving it cost four review rounds — the absence check that would have found it is "how does this
/// repo parse Swift", not "can Swift Testing enumerate suites at runtime".
///
/// Parsing with `SwiftParser` and walking the tree excludes comments and every string form STRUCTURALLY,
/// so all eleven defects vanish as a class rather than one at a time. `swift-syntax` is a
/// test-target-only SPM dependency; it never reaches the shipped app.
///
/// The generated axis matrix that specified the old lexer is retained as this suite's spec:
/// `.claude/tests/test-inventory-parser.test.sh`.
@Suite("Test inventory — every suite declares what it protects (#2141)", .tags(.driftGuard))
struct TestInventoryFreezeTests {

  // MARK: - Model

  /// The four things a test can protect. Exactly one per suite.
  enum TestClass: String, CaseIterable {
    case productOutcome, driftGuard, observabilityContract, harnessContract

    /// Applied IN ADDITION to a class tag; not a class of its own.
    static let realBoundaryTag = "realBoundary"
  }

  struct SuiteRecord {
    let file: String
    let name: String
    /// The type's path within its file (`Outer.Inner`), which is how a declaration and its
    /// EXTENSIONS recognise each other. The baseline is keyed by `key`, never by this.
    let identity: String
    let classes: [TestClass]
    let testCount: Int
    let boundaryCount: Int

    var key: String { "\(file)\t\(name)" }

    func declaring(_ classes: [TestClass]) -> SuiteRecord {
      SuiteRecord(
        file: file, name: name, identity: identity, classes: classes,
        testCount: testCount, boundaryCount: boundaryCount)
    }
  }

  /// One file's parse. Tags are collected separately from tests because the type that CARRIES the tag
  /// need not be the one that holds them.
  private struct ParseState {
    var records: [SuiteRecord] = []
    var tagCarriers: [String: Set<TestClass>] = [:]
  }

  // MARK: - Parsing

  /// Collects every suite that CONTAINS tests, with its declared classes and counts.
  ///
  /// A suite is any type declaration holding at least one `@Test` member. Swift Testing treats a plain
  /// `struct` of `@Test` functions as an IMPLICIT suite, so `@Suite` is not required to be one — an
  /// earlier enumeration keyed on `@Suite` missed 14 files holding 146 tests.
  private static func suites(inFile path: String, relativeTo root: String) throws -> [SuiteRecord] {
    let source = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
    let rel = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
    return suites(inSource: source, file: rel)
  }

  /// Resolves a file, then hands each suite the tag its own TYPE declared.
  ///
  /// Swift Testing applies a suite's traits to a test declared in an EXTENSION of that suite, so
  /// `@Suite(.tags(.productOutcome)) struct S {}` plus `extension S { @Test func works() {} }` is one
  /// tagged suite. Reading attributes only where the tests sit called it untagged and named the file —
  /// a confident wrong subject, which sends the author to inspect a suite they tagged correctly
  /// (testing-philosophy.md RULE: never-guess-when-the-subject-is-finished ranks that failure worst).
  ///
  /// KNOWN LIMIT, stated rather than hidden: resolution is per FILE, so a suite whose extension lives
  /// in a DIFFERENT file inherits nothing and is reported undeclared. That direction is loud, names the
  /// file, and asks for a tag; no such split exists in this tree.
  private static func suites(inSource source: String, file: String) -> [SuiteRecord] {
    let tree = Parser.parse(source: source)
    var state = ParseState()
    collect(from: tree.statements.map(\.item), file: file, parent: [], into: &state)
    return state.records.map { record in
      guard record.classes.isEmpty, let carried = state.tagCarriers[record.identity] else {
        return record
      }
      return record.declaring(TestClass.allCases.filter { carried.contains($0) })
    }
  }

  /// Recurses so a nested helper type (a spy declared beside the tests) owns only its OWN `@Test`
  /// members and never steals its parent's.
  private static func collect(
    from items: [CodeBlockItemSyntax.Item], file: String, parent: [String],
    into state: inout ParseState
  ) {
    for item in items {
      guard let decl = item.as(DeclSyntax.self) else {
        // `#if DEBUG` wraps 43 suites in this repo. Descend through it rather than treating the
        // indentation it introduces as structure, which is what the text lexer got wrong.
        if let ifConfig = item.as(StmtSyntax.self)?.as(ExpressionStmtSyntax.self)?
          .expression.as(IfConfigDeclSyntax.self)
        {
          for clause in ifConfig.clauses {
            if let elements = clause.elements?.as(CodeBlockItemListSyntax.self) {
              collect(from: elements.map(\.item), file: file, parent: parent, into: &state)
            }
          }
        }
        continue
      }
      collect(decl: decl, file: file, parent: parent, into: &state)
    }
  }

  private static func collect(
    decl: DeclSyntax, file: String, parent: [String], into state: inout ParseState
  ) {
    if let ifConfig = decl.as(IfConfigDeclSyntax.self) {
      for clause in ifConfig.clauses {
        if let elements = clause.elements?.as(CodeBlockItemListSyntax.self) {
          collect(from: elements.map(\.item), file: file, parent: parent, into: &state)
        }
      }
      return
    }

    guard let named = namedTypeDecl(decl) else { return }

    let identity = (parent + [named.name]).joined(separator: ".")
    let declared = tagNames(in: Syntax(named.attributes))
    let classes = TestClass.allCases.filter { declared.contains($0.rawValue) }
    // Registered whether or not this declaration holds tests: a tag on a bodiless `@Suite struct S {}`
    // exists precisely so the tests in `extension S` can find it.
    if !classes.isEmpty { state.tagCarriers[identity, default: []].formUnion(classes) }

    var directTests = 0
    var directBoundary = 0
    countMembers(
      named.members, file: file, parent: parent + [named.name],
      tests: &directTests, boundary: &directBoundary, into: &state)

    if directTests > 0 {
      state.records.append(
        SuiteRecord(
          file: file, name: named.name, identity: identity, classes: classes,
          testCount: directTests, boundaryCount: directBoundary))
    }
  }

  /// Walks a member list, descending THROUGH `#if` transparently so a conditionally-compiled test still
  /// belongs to its enclosing suite.
  ///
  /// A member-level `#if DEBUG` is an `IfConfigDeclSyntax` in the member list, not a type, and treating it
  /// like one hoisted its tests out of their suite: 144 tests across 14 files vanished, including two
  /// suites that reported ZERO. Caught by the reconciliation guard, not by reading the code.
  private static func countMembers(
    _ members: MemberBlockItemListSyntax, file: String, parent: [String],
    tests: inout Int, boundary: inout Int, into state: inout ParseState
  ) {
    for member in members {
      if let ifConfig = member.decl.as(IfConfigDeclSyntax.self) {
        for clause in ifConfig.clauses {
          if let nested = clause.elements?.as(MemberBlockItemListSyntax.self) {
            countMembers(
              nested, file: file, parent: parent,
              tests: &tests, boundary: &boundary, into: &state)
          }
        }
        continue
      }
      guard let fn = member.decl.as(FunctionDeclSyntax.self) else {
        // Nested type: recurse, so its tests belong to IT.
        collect(decl: member.decl, file: file, parent: parent, into: &state)
        continue
      }
      guard let testAttribute = attribute(named: "Test", on: fn.attributes) else { continue }
      tests += 1
      if tagNames(in: Syntax(testAttribute)).contains(TestClass.realBoundaryTag) { boundary += 1 }
    }
  }

  private struct NamedType {
    let name: String
    let attributes: AttributeListSyntax
    let members: MemberBlockItemListSyntax
  }

  private static func namedTypeDecl(_ decl: DeclSyntax) -> NamedType? {
    if let d = decl.as(StructDeclSyntax.self) {
      return NamedType(name: d.name.text, attributes: d.attributes, members: d.memberBlock.members)
    }
    if let d = decl.as(ClassDeclSyntax.self) {
      return NamedType(name: d.name.text, attributes: d.attributes, members: d.memberBlock.members)
    }
    if let d = decl.as(EnumDeclSyntax.self) {
      return NamedType(name: d.name.text, attributes: d.attributes, members: d.memberBlock.members)
    }
    if let d = decl.as(ActorDeclSyntax.self) {
      return NamedType(name: d.name.text, attributes: d.attributes, members: d.memberBlock.members)
    }
    if let d = decl.as(ExtensionDeclSyntax.self) {
      return NamedType(
        name: d.extendedType.trimmedDescription, attributes: d.attributes,
        members: d.memberBlock.members)
    }
    return nil
  }

  /// The last component of an attribute's written name.
  ///
  /// An attribute may be MODULE-QUALIFIED — `@Testing.Test` is the same attribute as `@Test`, and
  /// comparing the whole written name did not see it. `rawTestAttributeCount` repeated the identical
  /// comparison, so the reconciliation guard AGREED with the mistake: a second traversal isolates only
  /// the defects the two traversals do not SHARE, which is why both now read the name through here.
  private static func attributeBaseName(_ attr: AttributeSyntax) -> String {
    let written = attr.attributeName.trimmedDescription
    return String(written.split(separator: ".").last ?? Substring(written))
  }

  private static func attribute(named name: String, on list: AttributeListSyntax)
    -> AttributeSyntax?
  {
    for element in list {
      guard let attr = element.as(AttributeSyntax.self) else { continue }
      if attributeBaseName(attr) == name { return attr }
    }
    return nil
  }

  /// Every identifier GIVEN TO a `tags` trait inside the given syntax.
  ///
  /// Reading the TREE is what makes a tag in a comment or a string impossible to mistake for a
  /// declaration: a comment is trivia and never a node, and a string literal is a
  /// `StringLiteralExprSyntax`, never a `DeclReferenceExprSyntax`. Both were real defects in the lexer.
  ///
  /// Reading EVERY member access was the next mistake, and it failed quietly: `.enabled(if:
  /// Flags.productOutcome)` declares no class, and counting it as one lets an untagged suite pass the
  /// ratchet and corrupts the printed split. A trait that MENTIONS an identifier has not been given it.
  private static func tagNames(in syntax: Syntax) -> Set<String> {
    var found: Set<String> = []
    if let call = syntax.as(FunctionCallExprSyntax.self),
      let callee = call.calledExpression.as(MemberAccessExprSyntax.self),
      callee.declName.baseName.text == "tags"
    {
      found.formUnion(memberAccessNames(in: Syntax(call.arguments)))
    }
    for node in syntax.children(viewMode: .sourceAccurate) {
      found.formUnion(tagNames(in: node))
    }
    return found
  }

  private static func memberAccessNames(in syntax: Syntax) -> Set<String> {
    var found: Set<String> = []
    if let member = syntax.as(MemberAccessExprSyntax.self) {
      found.insert(member.declName.baseName.text)
    }
    for node in syntax.children(viewMode: .sourceAccurate) {
      found.formUnion(memberAccessNames(in: node))
    }
    return found
  }

  // MARK: - Inventory

  private static func inventory() throws -> [SuiteRecord] {
    let root = RepoRoot.url.path
    let testsDir = root + "/Tests"
    guard
      let walker = FileManager.default.enumerator(
        at: URL(fileURLWithPath: testsDir), includingPropertiesForKeys: nil)
    else {
      Issue.record("cannot enumerate \(testsDir)")
      return []
    }
    var records: [SuiteRecord] = []
    for case let url as URL in walker where url.pathExtension == "swift" {
      records.append(contentsOf: try suites(inFile: url.path, relativeTo: root))
    }
    return records.sorted { $0.key < $1.key }
  }

  private static func baselineKeys() throws -> Set<String> {
    let url = RepoRoot.sourceURL("scripts/test-inventory-baseline.txt")
    let text = try String(contentsOf: url, encoding: .utf8)
    let keys = Set(
      text.split(separator: "\n", omittingEmptySubsequences: true)
        .map(String.init)
        .filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: CharacterSet.whitespaces).isEmpty })
    return keys
  }

  // MARK: - The gate

  /// Counts `@Test` attributes by a SECOND, structurally different traversal of the same trees.
  ///
  /// This isolates ATTRIBUTION bugs: the suite walk can only lose a test by failing to find its enclosing
  /// type, and this walk does not care about enclosing types at all. The shell version this replaced had
  /// exactly such a guard and it caught three defects unaided; dropping it during the rewrite immediately
  /// hid a 136-test attribution gap, which is its own argument for keeping it
  /// (testing-philosophy.md RULE: an-instrument-you-stopped-checking-reports-its-strongest-result).
  private static func rawTestAttributeCount(in syntax: Syntax) -> Int {
    var n = 0
    if let attr = syntax.as(AttributeSyntax.self), attributeBaseName(attr) == "Test" {
      n += 1
    }
    for child in syntax.children(viewMode: .sourceAccurate) { n += rawTestAttributeCount(in: child) }
    return n
  }

  @Test("the suite walk attributes every test it can see")
  func attributionReconciles() throws {
    let root = RepoRoot.url.path
    guard
      let walker = FileManager.default.enumerator(
        at: URL(fileURLWithPath: root + "/Tests"), includingPropertiesForKeys: nil)
    else {
      Issue.record("cannot enumerate Tests/")
      return
    }
    var mismatches: [String] = []
    var parsedTotal = 0
    var rawTotal = 0
    for case let url as URL in walker where url.pathExtension == "swift" {
      let source = try String(contentsOf: url, encoding: .utf8)
      let tree = Parser.parse(source: source)
      let raw = Self.rawTestAttributeCount(in: Syntax(tree))
      let attributed = try Self.suites(inFile: url.path, relativeTo: root)
        .reduce(0) { $0 + $1.testCount }
      rawTotal += raw
      parsedTotal += attributed
      if raw != attributed {
        let rel = url.path.hasPrefix(root + "/") ? String(url.path.dropFirst(root.count + 1)) : url.path
        mismatches.append("  \(rel): attributed \(attributed), found \(raw)")
      }
    }
    #expect(
      mismatches.isEmpty,
      """
      \(rawTotal - parsedTotal) @Test attribute(s) were found but not attributed to any suite:
      \(mismatches.joined(separator: "\n"))
      """)
  }

  /// Rewrites the grandfather list. Env-gated so CI can never regenerate the thing it is checking against
  /// — a baseline that rewrites itself on failure is not a baseline.
  /// Run: `EW_WRITE_TEST_INVENTORY_BASELINE=1 scripts/xcode-test.sh --filter EnviousWisprTests/TestInventoryFreezeTests`
  /// then review the diff.
  @Test(
    "regenerate the grandfather list",
    .enabled(if: ProcessInfo.processInfo.environment["EW_WRITE_TEST_INVENTORY_BASELINE"] == "1"))
  func regenerateBaseline() throws {
    let records = try Self.inventory().filter { $0.classes.isEmpty }
    let header = """
      # Untagged suites grandfathered at the time of writing.
      # Keyed by "<path>\t<suite>" — a file-level list let an untagged suite ride along beside a tagged
      # one, and let a new suite be appended to a listed file.
      # Regenerate: EW_WRITE_TEST_INVENTORY_BASELINE=1 scripts/xcode-test.sh --filter EnviousWisprTests/TestInventoryFreezeTests
      # Removing a line is always allowed. Adding one needs a stated reason.
      """
    let body = records.map(\.key).sorted().joined(separator: "\n")
    try (header + "\n" + body + "\n").write(
      to: RepoRoot.sourceURL("scripts/test-inventory-baseline.txt"), atomically: true, encoding: .utf8)
    print("Wrote \(records.count) grandfathered suites.")
  }

  @Test("every suite outside the grandfather list declares exactly one class")
  func everyNewSuiteDeclaresItsClass() throws {
    let records = try Self.inventory()

    // Fail closed: an empty sweep would otherwise pass every assertion below.
    try #require(
      records.count > 400,
      "found only \(records.count) suites — the sweep is broken, not the tree")

    let baseline = try Self.baselineKeys()
    try #require(
      baseline.count > 400,
      "baseline lists \(baseline.count) suites; refusing to treat that as 'every suite is new'")

    let ambiguous = records.filter { $0.classes.count > 1 }
    #expect(
      ambiguous.isEmpty,
      """
      suite(s) declare more than one class tag. A suite protects ONE of the four:
      \(ambiguous.map { "  \($0.file) :: \($0.name) -> \($0.classes.map(\.rawValue))" }.joined(separator: "\n"))
      """)

    let undeclared = records.filter { $0.classes.isEmpty && !baseline.contains($0.key) }
    #expect(
      undeclared.isEmpty,
      """
      \(undeclared.count) suite(s) declare no test class:
      \(undeclared.map { "  \($0.file) :: \($0.name)" }.joined(separator: "\n"))

      Add one tag: .productOutcome | .driftGuard | .observabilityContract | .harnessContract
      Decide with: "when this fails, the user sees ___." Can you finish it? .productOutcome.
      A plain struct of @Test functions is an IMPLICIT suite and cannot carry a tag — add @Suite(...).
      Owner: .claude/rules/testing-philosophy.md
      """)
  }

  @Test("the inventory reports what the suite protects")
  func reportsTheSplit() throws {
    let records = try Self.inventory()
    var byClass: [String: Int] = [:]
    var untaggedTests = 0
    for r in records {
      if let c = r.classes.first {
        byClass[c.rawValue, default: 0] += r.testCount
      } else {
        untaggedTests += r.testCount
      }
    }
    let boundary = records.reduce(0) { $0 + $1.boundaryCount }
    let total = records.reduce(0) { $0 + $1.testCount }
    let nonProduct = TestClass.allCases
      .filter { $0 != .productOutcome }
      .reduce(0) { $0 + (byClass[$1.rawValue] ?? 0) }

    print(
      """

      TEST INVENTORY  (\(records.count) suites, \(total) tests)
      ---------------------------------------------------------------
        Product Outcome          \(byClass["productOutcome"] ?? 0)
        Drift Guard              \(byClass["driftGuard"] ?? 0)
        Observability Contract   \(byClass["observabilityContract"] ?? 0)
        Harness Contract         \(byClass["harnessContract"] ?? 0)
        Undeclared (legacy)      \(untaggedTests)
      ---------------------------------------------------------------
        Not protecting a user outcome  \(nonProduct)
        REAL-BOUNDARY receipts         \(boundary)   (mic / shipped model / foreground app)

      """)

    // The report must reach its subject, or it is decoration.
    #expect(total > 5000, "inventory reported \(total) tests; the sweep is broken")

    if boundary == 0 {
      print(
        """
        WARNING: zero real-boundary receipts. Every test runs against stand-ins.
                 testing-philosophy.md RULE: the-heart-crosses-a-real-boundary-at-least-once
                 Tracked in #2142.

        """)
    }
  }

  // MARK: - The parser's own spec
  //
  // The lexer this replaced was wrong eleven times, so the replacement asserts its behaviour on the
  // forms that broke it rather than only on the live tree. Each accepted form is paired with a
  // near-identical rejected one, so a parser that stopped classifying anything fails rather than looks
  // clean (testing-philosophy.md RULE: generate-the-sweep-do-not-hand-pick-it).

  private static func parse(_ source: String) -> [SuiteRecord] {
    suites(inSource: source, file: "probe.swift").sorted { $0.name < $1.name }
  }

  @Test(
    "a tag is read from CODE and never from a comment or a string",
    arguments: [
      // (source, expected classes, expected tests)
      ("@Suite(.tags(.productOutcome)) struct S { @Test func a() {} }", ["productOutcome"], 1),
      ("@Suite(\"t\", .tags(.driftGuard))\nstruct S { @Test func a() {} }", ["driftGuard"], 1),
      (
        "@Suite(\n  \"t\",\n  .tags(.observabilityContract)\n)\nstruct S { @Test func a() {} }",
        ["observabilityContract"], 1
      ),
      (
        "@MainActor\n@Suite(.tags(.harnessContract))\nstruct S { @Test func a() {} }",
        ["harnessContract"], 1
      ),
      (
        "@Suite(.tags(.productOutcome))\n/// doc\nstruct S { @Test func a() {} }",
        ["productOutcome"], 1
      ),
      // Rejected halves: prose must never read as a declaration.
      ("@Suite(\"probe\") // .tags(.productOutcome)\nstruct S { @Test func a() {} }", [], 1),
      ("@Suite(\"a title saying .tags(.productOutcome)\")\nstruct S { @Test func a() {} }", [], 1),
      ("@Suite(\"t\" /* .tags(.productOutcome) */)\nstruct S { @Test func a() {} }", [], 1),
      (
        "/*\nstruct Commented { @Test func x() {} }\n*/\n@Suite(.tags(.driftGuard)) struct S { @Test func a() {} }",
        ["driftGuard"], 1
      ),
      (
        "@Suite(\"an escaped \\\" quote and a (paren\", .tags(.productOutcome))\nstruct S { @Test func a() {} }",
        ["productOutcome"], 1
      ),
      (
        "@Suite(.tags(.productOutcome)) struct S { @Test(\"privacy-safe class names\") func a() {} }",
        ["productOutcome"], 1
      ),
      // Implicit suite: a plain struct of tests is a suite and carries no tag.
      ("struct S { @Test func a() {} }", [], 1),
    ])
  func tagsComeFromTheTree(source: String, expectedClasses: [String], expectedTests: Int) throws {
    let records = Self.parse(source)
    let s = try #require(records.first { $0.name == "S" }, "no suite S parsed from: \(source)")
    #expect(s.classes.map(\.rawValue) == expectedClasses)
    #expect(s.testCount == expectedTests)
  }

  @Test("a nested helper type owns only its own tests")
  func nestedTypeDoesNotStealTests() throws {
    let records = Self.parse(
      """
      @Suite(.tags(.productOutcome)) struct S {
        final class Spy { var hits = 0 }
        @Test func a() {}
        @Test func b() {}
      }
      """)
    let s = try #require(records.first { $0.name == "S" })
    #expect(s.testCount == 2)
    #expect(records.contains { $0.name == "Spy" } == false, "Spy holds no tests and is not a suite")
  }

  @Test("a #if DEBUG INSIDE a suite body keeps its tests in that suite")
  func memberLevelIfConfigKeepsItsTests() throws {
    let records = Self.parse(
      """
      @Suite(.tags(.productOutcome)) struct S {
        @Test func always() {}
        #if DEBUG
          @Test func debugOnly() {}
          @Test(.tags(.realBoundary)) func debugBoundary() {}
        #endif
      }
      """)
    let s = try #require(records.first { $0.name == "S" })
    #expect(s.testCount == 3, "a member-level #if hoisted its tests out of the suite")
    #expect(s.boundaryCount == 1)
  }

  @Test("a suite indented inside #if DEBUG is still found")
  func ifConfigSuiteIsFound() throws {
    let records = Self.parse(
      """
      #if DEBUG
        @Suite(.tags(.productOutcome))
        struct S {
          @Test func a() {}
        }
      #endif
      """)
    let s = try #require(records.first { $0.name == "S" }, "the #if DEBUG suite was missed")
    #expect(s.classes.map(\.rawValue) == ["productOutcome"])
  }

  @Test("a multiline string fixture holding Swift source is text, not code")
  func multilineFixtureIsNotCode() throws {
    let records = Self.parse(
      #"""
      @Suite(.tags(.harnessContract)) struct S {
        let fixture = """
          @Suite struct NotReal {
            @Test func notReal() {}
          }
          """
        @Test func a() {}
      }
      """#)
    let s = try #require(records.first { $0.name == "S" })
    #expect(s.testCount == 1, "the fixture's @Test was counted as a real test")
    #expect(records.contains { $0.name == "NotReal" } == false)
  }

  @Test("realBoundary is read per test, from code only")
  func realBoundaryIsCountedFromCode() throws {
    let wrapped = Self.parse(
      """
      @Suite(.tags(.productOutcome)) struct S {
        @Test(
          "wrapped",
          .tags(.realBoundary)
        )
        func a() {}
        @Test func b() {}
      }
      """)
    #expect(
      try #require(wrapped.first).boundaryCount == 1, "a wrapped @Test attribute lost its tag")

    let commented = Self.parse(
      """
      @Suite(.tags(.productOutcome)) struct S {
        @Test("t" /* .tags(.realBoundary) */) func a() {}
      }
      """)
    #expect(try #require(commented.first).boundaryCount == 0, "a comment faked a boundary receipt")
  }

  @Test("two class tags on one suite are reported, not silently resolved")
  func twoClassTagsAreAmbiguous() throws {
    let records = Self.parse(
      "@Suite(.tags(.productOutcome, .harnessContract)) struct S { @Test func a() {} }")
    let s = try #require(records.first)
    #expect(s.classes.count == 2, "precedence silently picked one class")
  }

  // MARK: - The axes round 5 named
  //
  // Three more findings, all one shape: a VALID Swift spelling this parser compared too literally. Two
  // failed QUIETLY — a module-qualified attribute made a whole suite invisible to the gate AND to the
  // reconciliation guard that exists to contradict it, and any member access counted as a tag, so a
  // trait that merely mentioned a class name declared one. The third failed loudly and wrongly, calling
  // a correctly-tagged suite untagged because its tests sat in an extension.
  //
  // Each axis is instantiated as a cross-product, and each accepted row is paired with a near-identical
  // rejected one, so a parser that stopped classifying anything fails rather than looks clean
  // (testing-philosophy.md RULE: generate-the-sweep-do-not-hand-pick-it).

  @Test(
    "a test is recognised by its attribute's last component, wherever the suite's body lives",
    arguments: ["@Test", "@Testing.Test", "@TestOnly", "@Testing.Suite"],
    ["in-type", "extension"])
  func attributeSpellingTimesHostSite(attribute: String, host: String) throws {
    // `@Testing.Test` is the SAME attribute as `@Test`. A longer name is a different one. Matching the
    // last component accepts `@AnyModule.Test` too, which can only ever over-count — and over-counting
    // asks for a tag by name, the loud direction.
    let expected = ["@Test": 1, "@Testing.Test": 1][attribute] ?? 0
    let source =
      host == "in-type"
      ? "@Suite(.tags(.productOutcome)) struct S { \(attribute) func a() {} }"
      : """
        @Suite(.tags(.productOutcome)) struct S {}
        extension S { \(attribute) func a() {} }
        """

    let holding = Self.parse(source).filter { $0.testCount > 0 }
    #expect(
      holding.reduce(0) { $0 + $1.testCount } == expected,
      "\(attribute) in \(host) yielded \(holding.map(\.testCount))")
    if expected > 0 {
      let s = try #require(holding.first)
      #expect(
        s.classes.map(\.rawValue) == ["productOutcome"],
        "the suite's class tag did not reach its tests (\(attribute), \(host))")
    }
    // The reconciliation guard has to agree. A defect the two traversals SHARE is one it cannot see.
    #expect(
      Self.rawTestAttributeCount(in: Syntax(Parser.parse(source: source))) == expected,
      "the second traversal disagrees for \(attribute)")
  }

  @Test(
    "an identifier is a tag only where a tags trait was GIVEN it",
    arguments: [
      // (traits as written on @Suite, classes it declares)
      (".tags(.productOutcome)", ["productOutcome"]),
      (".tags([.driftGuard])", ["driftGuard"]),
      ("\"titled\", .tags(.harnessContract)", ["harnessContract"]),
      (".serialized, .tags(.observabilityContract)", ["observabilityContract"]),
      // Rejected halves: a trait that MENTIONS a class name has not been given it.
      (".enabled(if: Flags.productOutcome)", []),
      (".enabled(if: Flags.driftGuard), .serialized", []),
      (".bug(\"https://example.invalid\", \"observabilityContract\")", []),
      ("\"titled\"", []),
    ])
  func onlyATagsTraitDeclaresAClass(traits: String, expected: [String]) throws {
    let records = Self.parse("@Suite(\(traits)) struct S { @Test func a() {} }")
    let s = try #require(records.first { $0.name == "S" }, "no suite parsed for traits: \(traits)")
    #expect(s.classes.map(\.rawValue) == expected, "traits: \(traits)")
  }

  @Test(
    "a real-boundary receipt comes from a tags trait, never from an enablement condition",
    arguments: [
      ("@Test(.tags(.realBoundary))", 1),
      // The rule tells authors to gate a real-boundary test on its resource, so the two must coexist.
      ("@Test(.tags(.realBoundary), .enabled(if: Devices.hasMicrophone))", 1),
      ("@Test(.enabled(if: Devices.realBoundary))", 0),
      ("@Test(\"realBoundary\")", 0),
    ])
  func realBoundaryComesFromATagsTrait(attribute: String, expected: Int) throws {
    let records = Self.parse(
      "@Suite(.tags(.productOutcome)) struct S { \(attribute) func a() {} }")
    let s = try #require(records.first { $0.name == "S" })
    #expect(s.testCount == 1, "attribute: \(attribute)")
    #expect(s.boundaryCount == expected, "attribute: \(attribute)")
  }

  @Test("an extension's tests take their own type's tag and no neighbour's")
  func extensionTakesOnlyItsOwnTypesTag() throws {
    let records = Self.parse(
      """
      @Suite(.tags(.productOutcome)) struct Tagged {}
      extension Tagged { @Test func a() {} }
      @Suite(.tags(.driftGuard)) struct Neighbour { @Test func b() {} }
      struct Untagged {}
      extension Untagged { @Test func c() {} }
      """)
    let tagged = try #require(records.first { $0.name == "Tagged" }, "the extension's tests vanished")
    #expect(tagged.classes.map(\.rawValue) == ["productOutcome"])
    #expect(tagged.testCount == 1)
    #expect(
      try #require(records.first { $0.name == "Untagged" }).classes.isEmpty,
      "a neighbouring suite's tag leaked across types")
    #expect(try #require(records.first { $0.name == "Neighbour" }).testCount == 1)
  }

  @Test("a nested suite and its extension recognise each other by QUALIFIED name")
  func nestedExtensionResolvesByQualifiedIdentity() throws {
    let records = Self.parse(
      """
      enum Outer {
        @Suite(.tags(.harnessContract)) struct Inner {}
      }
      extension Outer.Inner { @Test func a() {} }
      struct Inner {}
      extension Inner { @Test func b() {} }
      """)
    let nested = try #require(records.first { $0.name == "Outer.Inner" })
    #expect(nested.classes.map(\.rawValue) == ["harnessContract"])
    // Rejected half: a same-named type at file scope is a DIFFERENT type and takes nothing.
    #expect(
      try #require(records.first { $0.name == "Inner" }).classes.isEmpty,
      "an unqualified sibling took the nested suite's tag")
  }
}
