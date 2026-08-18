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
/// The parser is not the end of it, and the rest is the more useful half. Rounds 5-7 found eight more
/// defects with no lexical content at all, every one A COMPARISON NARROWER THAN THE LANGUAGE — a
/// module-qualified attribute, a backtick-escaped identifier, trivia inside a qualified name, a
/// same-basename method on an unrelated type, one identity in exclusive `#if` branches, and a key that
/// could not tell `OuterA.Inner` from `OuterB.Inner`. A parser prevents none of those. The answer was to
/// enumerate the axes and route every name through one place, and this suite's own spec below sweeps
/// their cross-product rather than one row per finding.
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
    /// The declaration's own name, for reading in a failure message.
    let name: String
    /// The type PATH within the file — `Outer.Inner` — and what the grandfather list is keyed by.
    ///
    /// Keying on `name` alone could not tell `OuterA.Inner` from `OuterB.Inner`, so a NEW untagged
    /// suite silently inherited a neighbour's grandfathering. Quiet direction, and the ratchet exists
    /// precisely to stop that.
    let qualifiedName: String
    /// `qualifiedName` plus the `#if` branch the declaration sits in, which is how a declaration and
    /// its EXTENSIONS recognise each other without a tag crossing between exclusive branches.
    ///
    /// Deliberately NOT the baseline key: a branch label embeds an `#if` CONDITION, so editing that
    /// condition would silently make every suite under it look new.
    let identity: String
    let classes: [TestClass]
    let testCount: Int
    let boundaryCount: Int

    var key: String { "\(file)\t\(qualifiedName)" }

    func declaring(_ classes: [TestClass]) -> SuiteRecord {
      SuiteRecord(
        file: file, name: name, qualifiedName: qualifiedName, identity: identity, classes: classes,
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
    collect(from: tree.statements.map(\.item), file: file, scope: Scope(), into: &state)
    return state.records.map { record in
      guard record.classes.isEmpty, let carried = state.tagCarriers[record.identity] else {
        return record
      }
      return record.declaring(TestClass.allCases.filter { carried.contains($0) })
    }
  }

  /// Where a declaration sits: its enclosing types, and which `#if` branch it is inside.
  ///
  /// The branch half exists because every clause is traversed. Mutually exclusive branches can declare
  /// the SAME type — a tagged `S` under `#if FEATURE` and an untagged `S` under `#else` — and pooling
  /// their tags by name alone let the untagged one inherit a tag it never declared, silently, in either
  /// configuration. Identity therefore includes the branch, so a tag never crosses one.
  /// Consequence, and it is the loud direction: a suite declared inside `#if` whose extension sits
  /// outside it resolves to nothing and is reported undeclared.
  private struct Scope {
    var types: [String] = []
    var branches: [String] = []

    func entering(type name: String) -> Scope {
      Scope(types: types + [name], branches: branches)
    }
    func entering(branch label: String) -> Scope {
      Scope(types: types, branches: branches + [label])
    }
    /// The type path alone. Stable across an `#if` condition being edited, which is why the baseline
    /// is keyed by this and resolution is not.
    func qualifiedName(of name: String) -> String {
      (types + [name]).joined(separator: ".")
    }

    func identity(of name: String) -> String {
      let path = qualifiedName(of: name)
      return branches.isEmpty ? path : branches.joined(separator: "|") + "|" + path
    }
  }

  private static func branchLabels(of ifConfig: IfConfigDeclSyntax) -> [String] {
    ifConfig.clauses.enumerated().map { index, clause in
      "\(index):\(clause.poundKeyword.text):\(clause.condition?.trimmedDescription ?? "")"
    }
  }

  /// Recurses so a nested helper type (a spy declared beside the tests) owns only its OWN `@Test`
  /// members and never steals its parent's.
  private static func collect(
    from items: [CodeBlockItemSyntax.Item], file: String, scope: Scope,
    into state: inout ParseState
  ) {
    for item in items {
      // `#if DEBUG` wraps 43 suites in this repo, and it arrives here as a DECL item, so
      // `collect(decl:)` is what descends through it. An earlier version also tried an
      // expression-statement shape; the compiler rejects that cast outright — `IfConfigDeclSyntax` is
      // not in the `ExprSyntaxProtocol` hierarchy — so the branch could never fire and only emitted a
      // deprecation warning. Removed rather than left as reassuring dead code, with
      // `ifConfigSuiteIsFound` covering the path that does run.
      guard let decl = item.as(DeclSyntax.self) else { continue }
      collect(decl: decl, file: file, scope: scope, into: &state)
    }
  }

  private static func collect(
    decl: DeclSyntax, file: String, scope: Scope, into state: inout ParseState
  ) {
    if let ifConfig = decl.as(IfConfigDeclSyntax.self) {
      let labels = branchLabels(of: ifConfig)
      for (index, clause) in ifConfig.clauses.enumerated() {
        if let elements = clause.elements?.as(CodeBlockItemListSyntax.self) {
          collect(
            from: elements.map(\.item), file: file,
            scope: scope.entering(branch: labels[index]), into: &state)
        }
      }
      return
    }

    guard let named = namedTypeDecl(decl) else { return }

    let qualifiedName = scope.qualifiedName(of: named.name)
    let identity = scope.identity(of: named.name)
    let declared = tagNames(in: Syntax(named.attributes))
    let classes = TestClass.allCases.filter { declared.contains($0.rawValue) }
    // Registered whether or not this declaration holds tests: a tag on a bodiless `@Suite struct S {}`
    // exists precisely so the tests in `extension S` can find it.
    if !classes.isEmpty { state.tagCarriers[identity, default: []].formUnion(classes) }

    var directTests = 0
    var directBoundary = 0
    countMembers(
      named.members, file: file, scope: scope.entering(type: named.name),
      tests: &directTests, boundary: &directBoundary, into: &state)

    if directTests > 0 {
      state.records.append(
        SuiteRecord(
          file: file, name: named.name, qualifiedName: qualifiedName, identity: identity,
          classes: classes, testCount: directTests, boundaryCount: directBoundary))
    }
  }

  /// Walks a member list, descending THROUGH `#if` transparently so a conditionally-compiled test still
  /// belongs to its enclosing suite.
  ///
  /// A member-level `#if DEBUG` is an `IfConfigDeclSyntax` in the member list, not a type, and treating it
  /// like one hoisted its tests out of their suite: 144 tests across 14 files vanished, including two
  /// suites that reported ZERO. Caught by the reconciliation guard, not by reading the code.
  private static func countMembers(
    _ members: MemberBlockItemListSyntax, file: String, scope: Scope,
    tests: inout Int, boundary: inout Int, into state: inout ParseState
  ) {
    for member in members {
      if let ifConfig = member.decl.as(IfConfigDeclSyntax.self) {
        let labels = branchLabels(of: ifConfig)
        for (index, clause) in ifConfig.clauses.enumerated() {
          if let nested = clause.elements?.as(MemberBlockItemListSyntax.self) {
            countMembers(
              nested, file: file, scope: scope.entering(branch: labels[index]),
              tests: &tests, boundary: &boundary, into: &state)
          }
        }
        continue
      }
      guard let fn = member.decl.as(FunctionDeclSyntax.self) else {
        // Nested type: recurse, so its tests belong to IT.
        collect(decl: member.decl, file: file, scope: scope, into: &state)
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

  /// Every name here comes through `identifierText` / `typeIdentity`, so a declaration and its
  /// extension recognise each other however either is spelled.
  private static func namedTypeDecl(_ decl: DeclSyntax) -> NamedType? {
    if let d = decl.as(StructDeclSyntax.self) {
      return NamedType(
        name: identifierText(d.name), attributes: d.attributes, members: d.memberBlock.members)
    }
    if let d = decl.as(ClassDeclSyntax.self) {
      return NamedType(
        name: identifierText(d.name), attributes: d.attributes, members: d.memberBlock.members)
    }
    if let d = decl.as(EnumDeclSyntax.self) {
      return NamedType(
        name: identifierText(d.name), attributes: d.attributes, members: d.memberBlock.members)
    }
    if let d = decl.as(ActorDeclSyntax.self) {
      return NamedType(
        name: identifierText(d.name), attributes: d.attributes, members: d.memberBlock.members)
    }
    if let d = decl.as(ExtensionDeclSyntax.self) {
      return NamedType(
        name: typeIdentity(d.extendedType) ?? d.extendedType.trimmedDescription,
        attributes: d.attributes, members: d.memberBlock.members)
    }
    return nil
  }

  // MARK: - Names
  //
  // ONE PLACE READS A NAME, because two review rounds returned six findings that were all the same
  // defect: A COMPARISON NARROWER THAN THE LANGUAGE. Switching from a lexer to a parser killed the
  // eleven LEXICAL variants at once and did nothing for these, because these are spellings the compiler
  // accepts as identical and a literal `==` does not. The set is enumerated rather than discovered one
  // round at a time (codex-cli.md RULE: enumerate-the-class-when-review-rounds-repeat):
  //
  //   a. a backtick-escaped identifier      `Test`, `tags`, `productOutcome`, `Inner`
  //   b. module or type qualification       Testing.Test
  //   c. trivia inside a qualified name     Outer . Inner
  //   d. the same basename on another type  CustomTrait.tags(...) is not Swift Testing's trait
  //   e. one identity in exclusive #if branches, where a tag on one must not reach the other
  //
  // a-c are spelling and are normalised here. d and e are MEANING and are handled where they are read.

  /// An identifier token's name with its escaping removed: `` `Test` `` and `Test` are one name.
  ///
  /// `SwiftSyntax` preserves the backticks in `text`, so every literal comparison in this file missed
  /// the escaped spelling — invisibly for `@`Test``, which made a whole suite vanish from the gate AND
  /// from the reconciliation guard.
  /// `identifier?.name` is SwiftSyntax's OWN canonical, escaping-stripped identifier, and it is what
  /// `EngineMutationInventoryFreezeTests` already reached for after its round 1 — its comment there
  /// calls it "the general fix, not a backtick special case", which is exactly right and is why this
  /// file now matches rather than hand-rolling a second answer. It is nil for a non-identifier token,
  /// so the manual strip stays as the fallback rather than as the mechanism.
  private static func identifierText(_ token: TokenSyntax) -> String {
    token.identifier?.name ?? unescaped(token.text)
  }

  private static func unescaped(_ name: some StringProtocol) -> String {
    let text = String(name)
    guard text.count >= 2, text.hasPrefix("`"), text.hasSuffix("`") else { return text }
    return String(text.dropFirst().dropLast())
  }

  /// A type's dotted name, built from its NODES rather than its description.
  ///
  /// Reading `trimmedDescription` carried whatever trivia the author wrote, so the legal `Outer . Inner`
  /// did not match the `Outer.Inner` its own nested declaration produced. Walking the type structurally
  /// removes the trivia and the escaping in one pass.
  private static func typeIdentity(_ type: TypeSyntax) -> String? {
    if let identifier = type.as(IdentifierTypeSyntax.self) {
      return identifierText(identifier.name)
    }
    if let member = type.as(MemberTypeSyntax.self), let base = typeIdentity(member.baseType) {
      return base + "." + identifierText(member.name)
    }
    return nil
  }

  /// The last component of an attribute's name: `Test` from `@Test`, `@Testing.Test`, ``@`Test` `` or
  /// ``@Testing.`Test` ``. All four are the same attribute to the compiler.
  ///
  /// `rawTestAttributeCount` reads through here too. It repeated an identical comparison once and so
  /// AGREED with the mistake instead of contradicting it — a second traversal isolates only the defects
  /// the two traversals do not SHARE, which is the entire reason it exists.
  private static func attributeBaseName(_ attr: AttributeSyntax) -> String {
    let written = typeIdentity(attr.attributeName) ?? attr.attributeName.trimmedDescription
    return unescaped(written.split(separator: ".").last ?? Substring(written))
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
  ///
  /// The callee must also RESOLVE TO SWIFT TESTING'S TRAIT, which is a question about meaning and not
  /// about spelling, so normalisation cannot answer it. `CustomTrait.tags(.productOutcome)` is another
  /// type's method that merely shares a basename, and counting it declared a class nobody declared.
  ///
  /// Requiring a leading dot was the first answer and it was WRONG IN THE EXPENSIVE DIRECTION: the real
  /// trait also type-checks written out as `Tag.List.tags(...)` or `Testing.Tag.List.tags(...)`, and
  /// rejecting those tells an author their correctly-tagged suite is untagged — a confident wrong
  /// subject, which this repo ranks as the worst failure a check can have. The base is therefore
  /// accepted when it is absent or IS that canonical list type, and nothing else.
  private static let canonicalTagListBase = "Tag.List"

  private static func isTagsTraitCallee(_ callee: MemberAccessExprSyntax) -> Bool {
    guard identifierText(callee.declName.baseName) == "tags" else { return false }
    guard let base = expressionIdentity(callee.base) else { return callee.base == nil }
    return base == canonicalTagListBase || base.hasSuffix("." + canonicalTagListBase)
  }

  /// A dotted name for a base EXPRESSION — `Tag.List` from `Testing.Tag.List` — built from nodes, so
  /// escaping and trivia are gone before anything is compared.
  private static func expressionIdentity(_ expr: ExprSyntax?) -> String? {
    if let reference = expr?.as(DeclReferenceExprSyntax.self) {
      return identifierText(reference.baseName)
    }
    if let member = expr?.as(MemberAccessExprSyntax.self) {
      guard let base = expressionIdentity(member.base) else { return nil }
      return base + "." + identifierText(member.declName.baseName)
    }
    return nil
  }

  private static func tagNames(in syntax: Syntax) -> Set<String> {
    var found: Set<String> = []
    if let call = syntax.as(FunctionCallExprSyntax.self),
      let callee = call.calledExpression.as(MemberAccessExprSyntax.self),
      isTagsTraitCallee(callee)
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
      found.insert(identifierText(member.declName.baseName))
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
        .filter {
          !$0.hasPrefix("#") && !$0.trimmingCharacters(in: CharacterSet.whitespaces).isEmpty
        })
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
    for child in syntax.children(viewMode: .sourceAccurate) {
      n += rawTestAttributeCount(in: child)
    }
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
        let rel =
          url.path.hasPrefix(root + "/") ? String(url.path.dropFirst(root.count + 1)) : url.path
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
  ///
  /// Run, and the prefix is load-bearing:
  /// ```
  /// TEST_RUNNER_EW_WRITE_TEST_INVENTORY_BASELINE=1 \
  ///   scripts/xcode-test.sh --filter EnviousWisprTests/TestInventoryFreezeTests
  /// ```
  /// then review the diff.
  ///
  /// **The recipe here used to omit `TEST_RUNNER_`, and that version SILENTLY DID NOTHING.** A plain
  /// variable is set on `xcodebuild`, which does not forward it to the xctest process that evaluates
  /// this condition; only the `TEST_RUNNER_`-prefixed form is passed through, with the prefix stripped.
  /// So the test reported `skipped`, the run printed `** TEST SUCCEEDED **` and `EXIT=0`, and the
  /// baseline was untouched — an operator following the documented recipe would read the green as
  /// "nothing needed regenerating". Measured 2026-08-18, and it is this PR's own subject one layer
  /// over: an instruction whose failure is indistinguishable from success. The condition reads the
  /// UNPREFIXED name because that is what the runner receives.
  @Test(
    "regenerate the grandfather list",
    .enabled(if: ProcessInfo.processInfo.environment["EW_WRITE_TEST_INVENTORY_BASELINE"] == "1"))
  func regenerateBaseline() throws {
    let records = try Self.inventory().filter { $0.classes.isEmpty }
    let header = """
      # Untagged suites grandfathered at the time of writing.
      # Keyed by "<path>\t<suite>" — a file-level list let an untagged suite ride along beside a tagged
      # one, and let a new suite be appended to a listed file.
      # Regenerate: TEST_RUNNER_EW_WRITE_TEST_INVENTORY_BASELINE=1 scripts/xcode-test.sh --filter EnviousWisprTests/TestInventoryFreezeTests
      # (the TEST_RUNNER_ prefix is required — without it the test silently skips and the run still greens)
      # Removing a line is always allowed. Adding one needs a stated reason.
      """
    let body = records.map(\.key).sorted().joined(separator: "\n")
    try (header + "\n" + body + "\n").write(
      to: RepoRoot.sourceURL("scripts/test-inventory-baseline.txt"), atomically: true,
      encoding: .utf8)
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
      \(ambiguous.map { "  \($0.file) :: \($0.qualifiedName) -> \($0.classes.map(\.rawValue))" }.joined(separator: "\n"))
      """)

    let undeclared = records.filter { $0.classes.isEmpty && !baseline.contains($0.key) }
    #expect(
      undeclared.isEmpty,
      """
      \(undeclared.count) suite(s) declare no test class:
      \(undeclared.map { "  \($0.file) :: \($0.qualifiedName)" }.joined(separator: "\n"))

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
    arguments: [
      "@Test", "@`Test`", "@Testing.Test", "@Testing.`Test`", "@TestOnly", "@Testing.Suite",
    ],
    ["in-type", "extension"])
  func attributeSpellingTimesHostSite(attribute: String, host: String) throws {
    // Qualification and escaping are the two ways Swift spells this one attribute, so all four accepted
    // forms are the SAME attribute to the compiler. A longer name is a different attribute. Matching the
    // last component also accepts `@AnyModule.Test`, which can only ever over-count — and over-counting
    // asks for a tag by name, the loud direction.
    let expected =
      ["@Test": 1, "@`Test`": 1, "@Testing.Test": 1, "@Testing.`Test`": 1][attribute] ?? 0
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
      // Escaping is spelling, not meaning: all three of these ARE the trait.
      (".`tags`(.productOutcome)", ["productOutcome"]),
      (".tags(.`productOutcome`)", ["productOutcome"]),
      (".`tags`(.`driftGuard`)", ["driftGuard"]),
      // Rejected halves: a trait that MENTIONS a class name has not been given it.
      (".enabled(if: Flags.productOutcome)", []),
      // A different type's method that merely SHARES the basename is not Swift Testing's trait. This one
      // is meaning rather than spelling, so no amount of normalising reaches it — the base must be absent.
      ("CustomTrait.tags(.productOutcome)", []),
      ("Testing.Tag.tags(.harnessContract)", []),
      (".enabled(if: Flags.driftGuard), .serialized", []),
      (".bug(\"https://example.invalid\", \"observabilityContract\")", []),
      ("\"titled\"", []),
    ])
  func onlyATagsTraitDeclaresAClass(traits: String, expected: [String]) throws {
    let records = Self.parse("@Suite(\(traits)) struct S { @Test func a() {} }")
    let s = try #require(records.first { $0.name == "S" }, "no suite parsed for traits: \(traits)")
    #expect(s.classes.map(\.rawValue) == expected, "traits: \(traits)")
  }

  /// The axis is HOW THE TRAIT'S BASE IS WRITTEN. Requiring a leading dot was wrong in the expensive
  /// direction — the canonical trait also type-checks written out, and rejecting it tells an author a
  /// correctly-tagged suite is untagged. Each accepted base is paired with a near-identical rejected
  /// one, so widening it until it stops discriminating fails here instead of looking clean.
  @Test(
    "the trait is recognised by what its base RESOLVES TO, not by whether one was written",
    arguments: [
      // (base as written before `.tags(...)`, does it declare the class)
      ("", true),
      ("Tag.List", true),
      ("Testing.Tag.List", true),
      ("Tag.`List`", true),
      // Rejected halves: another type's method that merely shares the basename.
      ("CustomTrait", false),
      ("MyThing.List", false),
      ("Tag", false),
      ("List", false),
    ])
  func traitIsRecognisedByWhatItsBaseResolvesTo(base: String, declares: Bool) throws {
    let records = Self.parse(
      "@Suite(\(base).tags(.productOutcome)) struct S { @Test func a() {} }")
    let s = try #require(records.first { $0.name == "S" }, "no suite parsed for base: \(base)")
    #expect(
      s.classes.map(\.rawValue) == (declares ? ["productOutcome"] : []),
      "base \"\(base)\" was \(s.classes.isEmpty ? "rejected" : "accepted") and should not have been"
    )
  }

  /// The axis is WHETHER THE GRANDFATHER KEY CAN TELL TWO SUITES APART. Keying on the bare name meant a
  /// NEW untagged suite inherited a listed neighbour's exemption — quiet, and the exact drift the
  /// ratchet exists to stop.
  @Test("two same-named nested suites in one file get distinct grandfather keys")
  func grandfatherKeysDistinguishQualifiedSuites() throws {
    let records = Self.parse(
      """
      enum OuterA { struct Inner { @Test func a() {} } }
      enum OuterB { struct Inner { @Test func b() {} } }
      """)
    let keys = Set(records.filter { $0.testCount > 0 }.map(\.key))
    #expect(keys.count == 2, "both suites shared one key, so one rides in on the other's listing")
    #expect(
      keys == ["probe.swift\tOuterA.Inner", "probe.swift\tOuterB.Inner"],
      "keys were \(keys.sorted())")
  }

  @Test("a grandfather key does NOT change when an #if condition is edited")
  func grandfatherKeysAreStableAcrossIfConditionEdits() throws {
    func keys(condition: String) -> Set<String> {
      Set(
        Self.parse(
          """
          #if \(condition)
            struct S { @Test func a() {} }
          #endif
          """
        ).filter { $0.testCount > 0 }.map(\.key))
    }
    // Resolution carries the branch so a tag cannot cross one; the KEY must not, or renaming a build
    // flag would silently make every suite under it look new and fail the ratchet.
    #expect(keys(condition: "DEBUG") == keys(condition: "RELEASE"))
    #expect(keys(condition: "DEBUG") == ["probe.swift\tS"])
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
    let tagged = try #require(
      records.first { $0.name == "Tagged" }, "the extension's tests vanished")
    #expect(tagged.classes.map(\.rawValue) == ["productOutcome"])
    #expect(tagged.testCount == 1)
    #expect(
      try #require(records.first { $0.name == "Untagged" }).classes.isEmpty,
      "a neighbouring suite's tag leaked across types")
    #expect(try #require(records.first { $0.name == "Neighbour" }).testCount == 1)
  }

  @Test(
    "a declaration and its extension recognise each other however either is SPELLED",
    arguments: [
      // (suite declaration, its extension) — every pair is one tagged suite holding one test.
      ("@Suite(.tags(.productOutcome)) struct S {}", "extension S { @Test func a() {} }"),
      ("@Suite(.tags(.productOutcome)) struct `S` {}", "extension S { @Test func a() {} }"),
      ("@Suite(.tags(.productOutcome)) struct S {}", "extension `S` { @Test func a() {} }"),
      (
        "enum Outer { @Suite(.tags(.productOutcome)) struct Inner {} }",
        "extension Outer . Inner { @Test func a() {} }"
      ),
      (
        "enum Outer { @Suite(.tags(.productOutcome)) struct `Inner` {} }",
        "extension Outer.Inner { @Test func a() {} }"
      ),
    ])
  func identityIsSpellingIndependent(declaration: String, ext: String) throws {
    let records = Self.parse(declaration + "\n" + ext)
    let holding = records.filter { $0.testCount > 0 }
    let suite = try #require(holding.first, "the extension's test reached no suite: \(ext)")
    #expect(holding.count == 1)
    #expect(
      suite.classes.map(\.rawValue) == ["productOutcome"],
      "the declaration's tag did not reach its extension: \(declaration) + \(ext)")
  }

  @Test("a tag never crosses mutually exclusive #if branches")
  func tagsDoNotPoolAcrossIfConfigBranches() throws {
    let records = Self.parse(
      """
      #if FEATURE
        @Suite(.tags(.productOutcome)) struct S {}
        extension S { @Test func a() {} }
      #else
        struct S {}
        extension S { @Test func b() {} }
      #endif
      """)
    let holding = records.filter { $0.testCount > 0 }
    #expect(holding.count == 2, "expected one suite per branch, got \(holding.map(\.name))")
    #expect(
      holding.filter { $0.classes.isEmpty }.count == 1,
      "the untagged branch inherited a tag it never declared")
    #expect(
      holding.filter { $0.classes.map(\.rawValue) == ["productOutcome"] }.count == 1,
      "the tagged branch lost its own tag")
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
