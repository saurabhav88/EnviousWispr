import Foundation
import SwiftParser
import SwiftSyntax
import Testing

/// PR8 of #763 — strict source parser for `*EventRouter` / `WedgeRecoveryRouter`
/// and the `DictationRuntime`-family ceiling tests.
///
/// Counts ONLY top-level `let` stored properties, matching the governing rule
/// in `.claude/rules/architecture-rules.md` ("How the ceiling parser counts")
/// and the sibling parser `CeilingsTestSupport`. `var` declarations (owned
/// mutable state, lazy properties, setter-injected outlets, callback closures)
/// are NOT collaborators and are excluded.
///
/// `let` stored properties declared directly in the class body are sub-binned:
///   - collaborator slot: non-primitive, non-closure, non-NSObjectProtocol
///   - closure-injected slot: typed as `(...) -> ...`
///
/// # Why this reads a syntax tree instead of text
///
/// This was 1013 lines of regex and character scanning that approximated
/// Swift's type grammar. PR #2070's review found TEN genuine defects in it over
/// twenty rounds, every one the same shape: a valid Swift spelling the
/// approximation did not recognise. Block-comment state, `async` and
/// typed-throws effect specifiers, optional and generic-wrapped function types,
/// function metatypes, tuples containing a closure, dictionaries of closures,
/// attribute argument lists, the `nonisolated` / `final` / `dynamic` /
/// `unowned` modifiers, multi-line wrapping. Each fix was proven red-then-green
/// and each was followed by another.
///
/// That is not bad luck, it is the price of approximating a real grammar.
/// `SwiftParser` IS the grammar, so the class stops existing: a wrapped
/// optional closure is an `OptionalTypeSyntax` around a `FunctionTypeSyntax`
/// whether it was written `(() -> Void)?`, `Optional<() -> Void>`, or split
/// across four lines with a comment in the middle. There is nothing left to
/// spell differently.
///
/// The dependency was already here. `Package.swift` adds `SwiftParser` and
/// `SwiftSyntax` to THIS test target for `EngineMutationInventoryFreezeTests`,
/// whose manifest comment reads "real Swift parser (replaces its hand-rolled
/// comment/string scanner)" — the same migration, already made once, in the
/// same directory. `EngineProtocolSurfaceFreezeTests` is the second user and
/// the model this file follows, including its fail-closed posture.
///
/// # Fail closed, never plausibly zero
///
/// A ceiling that reads LOW passes forever without complaining. So a source
/// file that does not parse, or a requested class that is not found, throws.
/// The one thing this must never do is return a confident small number.
enum RouterCeilingParser {

  struct ScanFailure: Error, CustomStringConvertible {
    let context: String
    let reason: String
    var description: String { "\(context): \(reason)" }
  }

  // MARK: - Source extraction

  /// The member text of `typeName`'s class body, sliced from the real source.
  /// Returned as text because every consumer and all 52 regression tests take a
  /// body string; the counters re-parse it rather than re-scan it.
  static func classBody(named typeName: String, at path: String) throws -> String {
    let source = try String(contentsOf: RepoRoot.sourceURL(path), encoding: .utf8)
    let tree = try parsed(source, context: "\(typeName) at \(path)")
    guard let decl = ClassFinder.find(named: typeName, in: tree) else {
      Issue.record("\(typeName) declaration not found at \(path)")
      throw ScanFailure(context: typeName, reason: "no class declaration named \(typeName)")
    }
    return decl.memberBlock.members.description
  }

  /// The body of the FIRST function/method named `functionName` in the file.
  static func functionBody(named functionName: String, at path: String) throws -> String {
    let source = try String(contentsOf: RepoRoot.sourceURL(path), encoding: .utf8)
    let tree = try parsed(source, context: "\(functionName) at \(path)")
    guard let fn = FunctionFinder.find(named: functionName, in: tree) else {
      Issue.record("\(functionName) function declaration not found at \(path)")
      throw ScanFailure(context: functionName, reason: "no function named \(functionName)")
    }
    guard let body = fn.body else {
      Issue.record("Function \(functionName) at \(path) has no body")
      throw ScanFailure(context: functionName, reason: "declaration has no body")
    }
    return body.statements.description
  }

  // MARK: - Counting

  /// Collaborator slot: non-primitive non-closure non-NSObjectProtocol `let`
  /// stored properties declared directly in the class body.
  static func collaboratorCount(in body: String) -> Int {
    storedLetBindings(in: body).filter { binding in
      guard let type = binding.type else { return !binding.isBooleanLiteralInitialized }
      return !isPrimitive(type) && !isFunctionType(type) && !isNSObjectProtocol(type)
    }.count
  }

  /// Closure-injected slot: `let` whose declared type is a function type,
  /// including every wrapping Swift permits around one.
  static func closureInjectedCount(in body: String) -> Int {
    storedLetBindings(in: body).filter { binding in
      guard let type = binding.type else { return false }
      return isFunctionType(type)
    }.count
  }

  /// Non-private `func` declarations declared directly in the class body.
  static func nonPrivateMethodCount(in body: String) -> Int {
    members(in: body).compactMap { $0.decl.as(FunctionDeclSyntax.self) }
      .filter { !isPrivate($0.modifiers) }
      .count
  }

  static func imports(in source: String) -> Set<String> {
    let tree = Parser.parse(source: source)
    var found: Set<String> = []
    for statement in tree.statements {
      guard let importDecl = statement.item.as(ImportDeclSyntax.self) else { continue }
      if let first = importDecl.path.first { found.insert(first.name.text) }
    }
    return found
  }

  /// Range of the first occurrence of `statement` in `body`, located over the
  /// syntax tree so a commented-out or string-quoted occurrence cannot match,
  /// but returned as an index into the REAL `body` text for the caller to slice
  /// (#1634).
  static func rangeOfStatement(_ statement: String, in body: String) -> Range<String.Index>? {
    let needle = statement.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return nil }
    guard let offset = firstCodeOffset(of: needle, in: body) else { return nil }
    // SwiftSyntax positions are UTF-8 byte offsets; `String.Index` takes UTF-16.
    // Converting through the UTF-8 view keeps the two in the same unit rather
    // than assuming they agree, which they do not for any non-ASCII source.
    let utf8 = body.utf8
    guard
      let startUTF8 = utf8.index(utf8.startIndex, offsetBy: offset, limitedBy: utf8.endIndex),
      let endUTF8 = utf8.index(startUTF8, offsetBy: needle.utf8.count, limitedBy: utf8.endIndex),
      let start = String.Index(startUTF8, within: body),
      let end = String.Index(endUTF8, within: body)
    else { return nil }
    return start..<end
  }

  /// UTF-8 offset of the first occurrence of `needle` in REAL CODE — comments
  /// and string-literal contents masked out first, so a commented-out or quoted
  /// occurrence cannot match (#1634).
  ///
  /// A SUBSTRING search, not a node match. Callers pass fragments such as
  /// `"assertionFailure("`, which is not a whole syntax node and never equals
  /// one; an exact-node implementation returned nil for every real call site and
  /// was caught only by the full suite. The tree supplies the mask; the search
  /// itself stays textual because the question is textual.
  ///
  /// Masking is done on BYTES and the result is used only as a byte offset.
  /// Blanking a multi-byte character byte-by-byte would change the Character
  /// count and silently misalign a `String.Index` computed from it.
  private static func firstCodeOffset(of needle: String, in body: String) -> Int? {
    var bytes = Array(body.utf8)
    let space = UInt8(ascii: " ")
    let newline = UInt8(ascii: "\n")

    func blank(from start: Int, length: Int) {
      var i = start
      let end = min(start + length, bytes.count)
      while i < end {
        if bytes[i] != newline { bytes[i] = space }
        i += 1
      }
    }

    for token in Parser.parse(source: body).tokens(viewMode: .sourceAccurate) {
      var position = token.position.utf8Offset
      for piece in token.leadingTrivia {
        let length = piece.sourceLength.utf8Length
        if piece.isComment { blank(from: position, length: length) }
        position += length
      }
      // `.stringSegment` carries the segment text, so it is matched as a
      // pattern rather than compared with `==`.
      if case .stringSegment = token.tokenKind {
        blank(
          from: token.positionAfterSkippingLeadingTrivia.utf8Offset,
          length: token.trimmedLength.utf8Length)
      }
      var trailing = token.endPositionBeforeTrailingTrivia.utf8Offset
      for piece in token.trailingTrivia {
        let length = piece.sourceLength.utf8Length
        if piece.isComment { blank(from: trailing, length: length) }
        trailing += length
      }
    }

    let target = Array(needle.utf8)
    guard !target.isEmpty, bytes.count >= target.count else { return nil }
    for start in 0...(bytes.count - target.count) {
      if Array(bytes[start..<(start + target.count)]) == target { return start }
    }
    return nil
  }

  // MARK: - Private

  private static func parsed(_ source: String, context: String) throws -> SourceFileSyntax {
    let tree = Parser.parse(source: source)
    guard !tree.hasError else {
      Issue.record("Source did not parse cleanly for \(context)")
      throw ScanFailure(context: context, reason: "source did not parse cleanly (tree.hasError)")
    }
    return tree
  }

  /// A class body is not a valid source file on its own, so it is wrapped back
  /// into a synthetic class before parsing. Wrapping rather than parsing the
  /// members as top-level code keeps them genuine MEMBERS, where modifiers such
  /// as `nonisolated` and `final` are legal and mean what they mean in the real
  /// class.
  private static func members(in body: String) -> MemberBlockItemListSyntax {
    let tree = Parser.parse(source: "final class __CeilingProbe {\n\(body)\n}")
    guard let probe = ClassFinder.find(named: "__CeilingProbe", in: tree) else {
      return MemberBlockItemListSyntax([])
    }
    return probe.memberBlock.members
  }

  private struct StoredLet {
    let type: TypeSyntax?
    let isBooleanLiteralInitialized: Bool
  }

  /// Every `let` binding declared directly in the body, one entry PER BINDING —
  /// so `let a: A, b: B` contributes two, which the text scanner could not do
  /// because it classified a whole line at a time.
  ///
  /// Excluded: `var` (owned mutable state), `static` / `class` type properties,
  /// and any binding with an accessor block, which is a computed property or an
  /// inline closure initializer rather than an injected seam.
  ///
  /// The type-property exclusion is the one rule here that is a DECISION about
  /// what the ceiling means rather than a fact about Swift: a type property is
  /// not an injected instance collaborator.
  private static func storedLetBindings(in body: String) -> [StoredLet] {
    var result: [StoredLet] = []
    for member in members(in: body) {
      guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }
      guard variable.bindingSpecifier.tokenKind == .keyword(.let) else { continue }
      guard !isTypeProperty(variable.modifiers) else { continue }
      for binding in variable.bindings {
        guard binding.accessorBlock == nil else { continue }
        let isBool = binding.initializer.map { isBooleanLiteral($0.value) } ?? false
        result.append(
          StoredLet(type: binding.typeAnnotation?.type, isBooleanLiteralInitialized: isBool))
      }
    }
    return result
  }

  private static func isTypeProperty(_ modifiers: DeclModifierListSyntax) -> Bool {
    modifiers.contains {
      $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class)
    }
  }

  private static func isPrivate(_ modifiers: DeclModifierListSyntax) -> Bool {
    modifiers.contains {
      $0.name.tokenKind == .keyword(.private) || $0.name.tokenKind == .keyword(.fileprivate)
    }
  }

  private static func isBooleanLiteral(_ expr: ExprSyntax) -> Bool {
    expr.is(BooleanLiteralExprSyntax.self)
  }

  /// Peels every wrapper Swift permits around a type and reports whether what is
  /// left is a function type. This one function replaces the entire class of
  /// defects the text scanner accumulated: `(() -> Void)?`,
  /// `Optional<() -> Void>`, `@MainActor () -> Void`, `((Error) -> Void)!` and
  /// any nesting of those are the same tree shape here.
  ///
  /// Deliberately NOT peeled, because each means the property is not a closure:
  /// a metatype (`(() -> Void).Type` is a type value), a multi-element tuple
  /// (`(() -> Void, AlphaDep)` is a tuple), and any generic other than
  /// `Optional` (`[String: () -> Void]` is a dictionary).
  private static func isFunctionType(_ type: TypeSyntax) -> Bool {
    unwrapped(type)?.is(FunctionTypeSyntax.self) ?? false
  }

  private static func unwrapped(_ type: TypeSyntax) -> TypeSyntax? {
    var current = type
    // Bounded by the nesting of a single declaration, which is finite; the cap
    // only stops a malformed tree from spinning.
    for _ in 0..<64 {
      if current.is(FunctionTypeSyntax.self) { return current }
      if let attributed = current.as(AttributedTypeSyntax.self) {
        current = attributed.baseType
        continue
      }
      if let optional = current.as(OptionalTypeSyntax.self) {
        current = optional.wrappedType
        continue
      }
      if let forced = current.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
        current = forced.wrappedType
        continue
      }
      // A single UNLABELLED element is a parenthesised type, not a tuple.
      if let tuple = current.as(TupleTypeSyntax.self), tuple.elements.count == 1,
        let only = tuple.elements.first, only.firstName == nil
      {
        current = only.type
        continue
      }
      if let inner = soleOptionalGenericArgument(of: current) {
        current = inner
        continue
      }
      return current
    }
    return nil
  }

  /// `Optional<T>` / `Swift.Optional<T>` → `T`. In this swift-syntax version
  /// `GenericArgumentSyntax.argument` is an enum (value generics), so the
  /// `.type` case is matched explicitly rather than assumed — checked against
  /// the pinned checkout, not remembered.
  private static func soleOptionalGenericArgument(of type: TypeSyntax) -> TypeSyntax? {
    let arguments: GenericArgumentListSyntax?
    if let identifier = type.as(IdentifierTypeSyntax.self), identifier.name.text == "Optional" {
      arguments = identifier.genericArgumentClause?.arguments
    } else if let member = type.as(MemberTypeSyntax.self), member.name.text == "Optional" {
      arguments = member.genericArgumentClause?.arguments
    } else {
      return nil
    }
    guard let arguments, arguments.count == 1, let only = arguments.first else { return nil }
    guard case .type(let inner) = only.argument else { return nil }
    return inner
  }

  private static let primitiveNames: Set<String> = [
    "Bool", "Int", "String", "Double", "Float", "UInt64",
  ]

  private static func isPrimitive(_ type: TypeSyntax) -> Bool {
    guard let base = unwrapped(type) else { return false }
    guard let identifier = base.as(IdentifierTypeSyntax.self) else { return false }
    if identifier.genericArgumentClause != nil { return identifier.name.text == "Task" }
    return primitiveNames.contains(identifier.name.text)
  }

  private static func isNSObjectProtocol(_ type: TypeSyntax) -> Bool {
    guard let base = unwrapped(type), let identifier = base.as(IdentifierTypeSyntax.self) else {
      return false
    }
    return identifier.name.text == "NSObjectProtocol"
  }

  // MARK: - Finders

  private final class ClassFinder: SyntaxVisitor {
    let targetName: String
    var found: ClassDeclSyntax?

    init(targetName: String) {
      self.targetName = targetName
      super.init(viewMode: .sourceAccurate)
    }

    static func find(named name: String, in tree: SourceFileSyntax) -> ClassDeclSyntax? {
      let finder = ClassFinder(targetName: name)
      finder.walk(tree)
      return finder.found
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
      if found == nil, node.name.text == targetName {
        found = node
        return .skipChildren
      }
      return .visitChildren
    }
  }

  private final class FunctionFinder: SyntaxVisitor {
    let targetName: String
    var found: FunctionDeclSyntax?

    init(targetName: String) {
      self.targetName = targetName
      super.init(viewMode: .sourceAccurate)
    }

    static func find(named name: String, in tree: SourceFileSyntax) -> FunctionDeclSyntax? {
      let finder = FunctionFinder(targetName: name)
      finder.walk(tree)
      return finder.found
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
      if found == nil, node.name.text == targetName {
        found = node
        return .skipChildren
      }
      return .visitChildren
    }
  }

}
