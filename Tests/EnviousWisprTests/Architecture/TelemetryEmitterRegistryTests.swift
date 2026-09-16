import CryptoKit
import Foundation
import SwiftParser
import SwiftSyntax
import Testing

/// Every PostHog emitter declares how often it fires and what the volume policy does with
/// it, and this suite is what enforces it (#2987).
///
/// Owner: `.claude/rules/telemetry-contract.md` RULE: new-telemetry-checklist.
///
/// A feature session built an emitter that would have sent hundreds of thousands of rows a
/// month, and only a manual "is this efficient?" caught it (founder, 2026-09-15). The rule
/// asks the questions before the code is written; this suite refuses what slipped through:
/// an emitter with no registry row, a row naming no emitter, a cadence outside the closed
/// set (so `per_chunk` cannot be written down at all), a `sampled` treatment that
/// `TelemetryVolumePolicy.swift` does not implement, and a grandfather count that rises.
///
/// Same shape as `TestInventoryFreezeTests`: `SwiftParser` over every file under `Sources/`
/// (so a capture added outside `TelemetryService.swift` is seen), a text registry under `scripts/`, an equality invariant in
/// both directions, and a ceiling that only ratchets down.
@Suite("Telemetry emitter registry (#2987)", .tags(.driftGuard))
struct TelemetryEmitterRegistryTests {

  // MARK: - Model

  /// Every Swift file under here is scanned. `TelemetryService.swift` is the only caller
  /// today; scanning the tree is what keeps a capture added elsewhere from going unseen.
  static let sourcesDir = "Sources"
  static let policyFile = "Sources/EnviousWisprServices/TelemetryVolumePolicy.swift"
  static let registryFile = "scripts/telemetry-emitter-registry.txt"

  /// Grandfathered rows at the freeze. The count must EQUAL this: grade a row, lower the
  /// number in the same change. Slack here is a free `ungraded` slot for a new emitter.
  static let ungradedCeiling = 110
  /// SHA-256 of the sorted, newline-joined `ungraded` event names. The count alone lets a
  /// retired row be swapped for a new `ungraded` one; the fingerprint pins the IDENTITIES.
  /// The failure message prints the new value; paste it only when grading or retiring.
  static let ungradedFingerprint =
    "d36d076926939405942bc83c1a092345dc46a5b0f5518ef8e23c34bea9aa3320"

  /// The closed cadence vocabulary. Deliberately no `per_chunk`, `per_buffer`, `per_frame`,
  /// `per_second`: an event finer than a take folds into the take's terminal row.
  static let cadences: Set<String> = [
    "per_launch", "per_take", "per_user_action", "per_change", "rare_failure", "periodic",
    "ungraded",
  ]
  static let treatments: Set<String> = ["keep", "sampled", "folded", "ungraded"]

  struct Row: Equatable {
    let event: String
    let cadence: String
    let treatment: String
    let reader: String
    let since: String
    let line: Int
  }

  struct Emitter: Hashable {
    /// Exact event name, or `prefix.*` for an interpolated name.
    let name: String
    let file: String
    let line: Int
  }

  // MARK: - Scanner

  /// Two passes over one file. Pass 1 learns which functions FORWARD a parameter into
  /// `PostHogSDK.shared.capture` (`emitUpdateStage(_ name:)`); pass 2 collects every direct
  /// capture with a resolvable name plus every call to a forwarder with a literal name.
  final class CaptureVisitor: SyntaxVisitor {
    let converter: SourceLocationConverter
    let file: String
    /// Function names whose capture argument is one of their own parameters, with the
    /// POSITION of that parameter, so a caller's argument at the same position is read.
    var forwarders: [String: Int]
    let collect: Bool
    private var functionStack: [FunctionDeclSyntax] = []
    var emitters: Set<Emitter> = []
    var unresolved: [(what: String, line: Int)] = []

    init(
      converter: SourceLocationConverter, file: String, forwarders: [String: Int], collect: Bool
    ) {
      self.converter = converter
      self.file = file
      self.forwarders = forwarders
      self.collect = collect
      super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
      functionStack.append(node)
      return .visitChildren
    }

    override func visitPost(_ node: FunctionDeclSyntax) {
      functionStack.removeLast()
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
      let line = converter.location(for: node.positionAfterSkippingLeadingTrivia).line
      guard let first = node.arguments.first?.expression else { return .visitChildren }
      if Self.isPostHogCapture(node.calledExpression) {
        handleCaptureArgument(first, line: line)
      } else if collect, let callee = Self.forwarderName(node.calledExpression),
        let position = forwarders[callee]
      {
        let arguments = Array(node.arguments)
        if position < arguments.count, let name = Self.literalName(arguments[position].expression) {
          emitters.insert(Emitter(name: name, file: file, line: line))
        } else {
          unresolved.append(("forwarder \(callee) called with a non-literal event name", line))
        }
      }
      return .visitChildren
    }

    private func handleCaptureArgument(_ argument: ExprSyntax, line: Int) {
      if let name = Self.literalName(argument) {
        if collect { emitters.insert(Emitter(name: name, file: file, line: line)) }
        return
      }
      guard let reference = argument.as(DeclReferenceExprSyntax.self),
        let function = functionStack.last
      else {
        if collect { unresolved.append(("capture name is not a literal or identifier", line)) }
        return
      }
      let identifier = reference.baseName.text
      if let position = Self.parameterNames(of: function).firstIndex(of: identifier) {
        // A forwarder: its callers carry the literal and are counted in pass 2.
        forwarders[function.name.text] = position
        return
      }
      switch Self.localLiteral(named: identifier, in: function) {
      case .one(let name):
        if collect { emitters.insert(Emitter(name: name, file: file, line: line)) }
      case .none:
        if collect {
          unresolved.append(("`\(identifier)` is not a local `let` string literal", line))
        }
      case .ambiguous:
        if collect {
          unresolved.append(("`\(identifier)` is bound more than once, or is a `var`", line))
        }
      }
    }

    /// A call to a forwarder, bare (`emitUpdateStage(...)`) or on `self` / `Self`
    /// (`self.emitUpdateStage(...)`). Any other receiver is not a forwarder call.
    static func forwarderName(_ callee: ExprSyntax) -> String? {
      if let reference = callee.as(DeclReferenceExprSyntax.self) {
        return reference.baseName.text
      }
      if let member = callee.as(MemberAccessExprSyntax.self) {
        let base = member.base?.trimmedDescription
        if base == nil || base == "self" || base == "Self" {
          return member.declName.baseName.text
        }
      }
      return nil
    }

    /// `PostHogSDK.shared.capture`, spelled exactly as the sanitizer seam expects.
    static func isPostHogCapture(_ callee: ExprSyntax) -> Bool {
      guard let member = callee.as(MemberAccessExprSyntax.self),
        member.declName.baseName.text == "capture",
        let base = member.base
      else { return false }
      return base.trimmedDescription == "PostHogSDK.shared"
    }

    /// The event name from a string literal. Segments after the first interpolation are
    /// dropped and the name becomes a family (`eg1.*`); a leading interpolation is
    /// unresolvable and returns nil.
    static func literalName(_ expression: ExprSyntax) -> String? {
      guard let literal = expression.as(StringLiteralExprSyntax.self) else { return nil }
      var prefix = ""
      for segment in literal.segments {
        switch segment {
        case .stringSegment(let text):
          prefix += text.content.text
        case .expressionSegment:
          guard prefix.hasSuffix(".") else { return nil }
          return prefix + "*"
        }
      }
      return prefix.isEmpty ? nil : prefix
    }

    /// Positional, in declaration order, so an index here is an argument index at a call.
    static func parameterNames(of function: FunctionDeclSyntax) -> [String] {
      function.signature.parameterClause.parameters.map {
        ($0.secondName ?? $0.firstName).text
      }
    }

    enum LocalBinding: Equatable {
      case one(String)
      case none
      /// Bound more than once in the function, or bound with `var`: which value reaches the
      /// capture is a data-flow question this syntax-only scan refuses to guess.
      case ambiguous
    }

    /// Exactly one `let <identifier> = "<literal>"` in the function body.
    static func localLiteral(named identifier: String, in function: FunctionDeclSyntax)
      -> LocalBinding
    {
      guard let body = function.body else { return .none }
      let finder = LocalLiteralFinder(identifier: identifier)
      finder.walk(body)
      if finder.bindings > 1 || finder.mutable { return .ambiguous }
      return finder.found.map { .one($0) } ?? .none
    }

    final class LocalLiteralFinder: SyntaxVisitor {
      let identifier: String
      var found: String?
      var bindings = 0
      var mutable = false
      init(identifier: String) {
        self.identifier = identifier
        super.init(viewMode: .sourceAccurate)
      }
      override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        for binding in node.bindings {
          guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
            pattern.identifier.text == identifier
          else { continue }
          bindings += 1
          if node.bindingSpecifier.tokenKind != .keyword(.let) { mutable = true }
          if let value = binding.initializer?.value,
            let name = CaptureVisitor.literalName(value)
          {
            found = name
          }
        }
        return .visitChildren
      }
    }
  }

  struct Unresolved {
    let file: String
    let line: Int
    let what: String
  }

  /// Pass 1 over every file learns the forwarders; pass 2 over every file collects with the
  /// union, so a forwarder declared in one file and called from another still resolves.
  static func scan(sources: [(file: String, source: String)]) -> (
    emitters: Set<Emitter>, unresolved: [Unresolved]
  ) {
    let parsed = sources.map { (file: $0.file, tree: Parser.parse(source: $0.source)) }
    var forwarders: [String: Int] = [:]
    for (file, tree) in parsed {
      let discovery = CaptureVisitor(
        converter: SourceLocationConverter(fileName: file, tree: tree), file: file,
        forwarders: [:], collect: false)
      discovery.walk(tree)
      forwarders.merge(discovery.forwarders) { current, _ in current }
    }
    var emitters: Set<Emitter> = []
    var unresolved: [Unresolved] = []
    for (file, tree) in parsed {
      let collector = CaptureVisitor(
        converter: SourceLocationConverter(fileName: file, tree: tree), file: file,
        forwarders: forwarders, collect: true)
      collector.walk(tree)
      emitters.formUnion(collector.emitters)
      unresolved.append(
        contentsOf: collector.unresolved.map {
          Unresolved(file: file, line: $0.line, what: $0.what)
        })
    }
    return (emitters, unresolved)
  }

  static func scanSources() throws -> (emitters: Set<Emitter>, unresolved: [Unresolved]) {
    let root = RepoRoot.url.path
    let dir = RepoRoot.sourceURL(sourcesDir)
    // A traversal error or a symlink would otherwise be a silent hole in the scan: the
    // walker skips what it cannot read and does not follow links, and every registered
    // emitter it did reach would keep the suite green. Both are recorded as failures.
    guard
      let walker = FileManager.default.enumerator(
        at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey],
        errorHandler: { url, error in
          Issue.record("cannot enumerate \(url.path): \(error)")
          return true
        })
    else {
      Issue.record("cannot enumerate \(dir.path)")
      return ([], [])
    }
    var sources: [(file: String, source: String)] = []
    for case let url as URL in walker {
      let relative = String(url.path.dropFirst(root.count + 1))
      if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
        Issue.record("\(relative) is a symlink; the scan does not follow links, so it refuses one")
        continue
      }
      guard url.pathExtension == "swift" else { continue }
      sources.append((relative, try String(contentsOf: url, encoding: .utf8)))
    }
    return scan(sources: sources.sorted { $0.file < $1.file })
  }

  /// The event names `TelemetryVolumePolicy.sampledDecision` switches on: string literals
  /// used as `case` patterns inside THAT function's body only. A name in a comment, an
  /// unrelated constant, or another switch (`decide`) is not a sampling case.
  static func policyCaseNames() throws -> Set<String> {
    let source = try String(contentsOf: RepoRoot.sourceURL(policyFile), encoding: .utf8)
    let locator = FunctionBodyLocator(name: "sampledDecision")
    locator.walk(Parser.parse(source: source))
    guard let body = locator.body else {
      Issue.record("\(policyFile) must declare `sampledDecision`")
      return []
    }
    // Discovery and collection are separate visitors on purpose: the collector never sees
    // anything outside the located body, so a switch in an initializer, an accessor or a
    // closure elsewhere in the file cannot contribute a case.
    let collector = CaseLiteralFinder(viewMode: .sourceAccurate)
    collector.walk(body)
    return collector.names
  }

  final class FunctionBodyLocator: SyntaxVisitor {
    let name: String
    var body: CodeBlockSyntax?
    init(name: String) {
      self.name = name
      super.init(viewMode: .sourceAccurate)
    }
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
      if node.name.text == name, body == nil { body = node.body }
      return .skipChildren
    }
  }

  final class CaseLiteralFinder: SyntaxVisitor {
    var names: Set<String> = []
    override func visit(_ node: SwitchCaseItemSyntax) -> SyntaxVisitorContinueKind {
      if let expression = node.pattern.as(ExpressionPatternSyntax.self),
        let name = CaptureVisitor.literalName(expression.expression)
      {
        names.insert(name)
      }
      return .visitChildren
    }
  }

  // MARK: - Registry

  static func registryRows() throws -> [Row] {
    let source = try String(contentsOf: RepoRoot.sourceURL(registryFile), encoding: .utf8)
    var rows: [Row] = []
    for (index, raw) in source.components(separatedBy: "\n").enumerated() {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("#") { continue }
      let columns = raw.components(separatedBy: "\t")
      guard columns.count == 5 else {
        let message =
          "\(registryFile):\(index + 1) has \(columns.count) tab-separated columns, expected 5 "
          + "(event, cadence, treatment, reader, since)"
        Issue.record(Comment(rawValue: message))
        continue
      }
      rows.append(
        Row(
          event: columns[0], cadence: columns[1], treatment: columns[2], reader: columns[3],
          since: columns[4], line: index + 1))
    }
    return rows
  }

  static let checklist = """
    A new PostHog emitter needs a row in \(registryFile) (event, cadence, treatment, reader, \
    since) and the checklist in .claude/rules/telemetry-contract.md answered first: how often \
    per install, rows per month against the live budget, who reads it, whether an existing row \
    can carry it, numbers as numbers, privacy, take_id. Cadence finer than per_take is not a \
    value: fold it into the take's terminal row.
    """

  // MARK: - Tests

  @Test("the scanner resolves literal, local-let, interpolated and forwarded names")
  func scannerPositiveControl() {
    let source = """
      enum Fixture {
        func a() { PostHogSDK.shared.capture("one.literal", properties: [:]) }
        func b() {
          let event = "two.local"
          PostHogSDK.shared.capture(event, properties: [:])
        }
        func c(name: String) { PostHogSDK.shared.capture("three.\\(name)") }
        func forward(_ name: String, v: String) { PostHogSDK.shared.capture(name) }
        func d() { forward("four.forwarded", v: "x") }
        func e() { forward(dynamic, v: "x") }
        func f() { Other.shared.capture("not.posthog") }
        func g() { self.forward("five.self_forwarded", v: "x") }
        func second(v: String, event: String) { PostHogSDK.shared.capture(event) }
        func h() { second(v: "not_the_event", event: "six.second_position") }
        func i() {
          let event = "seven.shadowed"
          if true { let event = "seven.other" }
          PostHogSDK.shared.capture(event)
        }
        func j() {
          var event = "eight.mutable"
          PostHogSDK.shared.capture(event)
        }
      }
      """
    let other = """
      enum Elsewhere {
        func k() { self.forward("nine.cross_file", v: "x") }
        func l() { PostHogSDK.shared.capture("ten.other_file") }
      }
      """
    let result = Self.scan(sources: [
      (file: "Fixture.swift", source: source), (file: "Elsewhere.swift", source: other),
    ])
    #expect(
      Set(result.emitters.map(\.name)) == [
        "one.literal", "two.local", "three.*", "four.forwarded", "five.self_forwarded",
        "six.second_position", "nine.cross_file", "ten.other_file",
      ])
    #expect(
      result.emitters.first { $0.name == "ten.other_file" }?.file == "Elsewhere.swift",
      "an emitter reports the file it lives in")
    let unresolvedMessage =
      "`forward(dynamic)`, the shadowed `event` and the `var event` must be reported, not "
      + "dropped or guessed: \(result.unresolved)"
    #expect(result.unresolved.count == 3, Comment(rawValue: unresolvedMessage))
  }

  @Test("every capture name under Sources resolves")
  func everyCaptureNameResolves() throws {
    let result = try Self.scanSources()
    #expect(
      result.unresolved.isEmpty,
      """
      \(result.unresolved.count) capture(s) whose event name this suite cannot read. Pass a \
      string literal, a local `let` literal, or a forwarder parameter:
      \(result.unresolved.map { "  \($0.file):\($0.line) \($0.what)" }.joined(separator: "\n"))
      """)
    #expect(
      result.emitters.count > 80,
      "found \(result.emitters.count) emitters; refusing to treat that as the whole tree")
  }

  @Test("every emitter has a registry row, and every row names a live emitter")
  func registryMatchesEmitters() throws {
    let emitters = try Self.scanSources().emitters
    let rows = try Self.registryRows()
    let emitted = Set(emitters.map(\.name))
    let registered = Set(rows.map(\.event))

    let unregistered = emitters.filter { !registered.contains($0.name) }.sorted {
      $0.line < $1.line
    }
    #expect(
      unregistered.isEmpty,
      """
      \(unregistered.count) emitter(s) with no registry row:
      \(unregistered.map { "  \($0.file):\($0.line) \($0.name)" }.joined(separator: "\n"))

      \(Self.checklist)
      """)

    let stale = rows.filter { !emitted.contains($0.event) }
    #expect(
      stale.isEmpty,
      """
      \(stale.count) registry row(s) name no live emitter. Retiring an event means deleting its \
      row (and marking its knowledge row RETIRED):
      \(stale.map { "  \(Self.registryFile):\($0.line) \($0.event)" }.joined(separator: "\n"))
      """)

    let duplicates = Dictionary(grouping: rows, by: \.event).filter { $0.value.count > 1 }
    #expect(duplicates.isEmpty, "duplicate rows: \(duplicates.keys.sorted())")
  }

  @Test("every row is well formed and its treatment is real")
  func rowsAreWellFormed() throws {
    let rows = try Self.registryRows()
    let policyCases = try Self.policyCaseNames()
    #expect(
      policyCases.contains("hotkey.pressed"),
      "positive control: the policy's own `case \"hotkey.pressed\"` must be readable")
    for row in rows {
      let at = "\(Self.registryFile):\(row.line) \(row.event)"
      let cadenceMessage =
        "\(at): cadence `\(row.cadence)` is not one of \(Self.cadences.sorted()). Finer than "
        + "per_take is not a value; fold into the take's terminal row."
      #expect(Self.cadences.contains(row.cadence), Comment(rawValue: cadenceMessage))
      #expect(
        Self.treatments.contains(row.treatment),
        "\(at): treatment `\(row.treatment)` is not one of \(Self.treatments.sorted())")
      #expect(
        (row.cadence == "ungraded") == (row.treatment == "ungraded"),
        "\(at): `ungraded` applies to cadence and treatment together")
      if row.cadence != "ungraded" {
        #expect(
          !row.reader.isEmpty && row.reader != "-",
          "\(at): a graded row names its reader, or `none: <why>`")
        #expect(
          row.since.hasPrefix("#"), "\(at): `since` names the issue that graded the row")
      }
      if row.treatment == "sampled" {
        #expect(
          policyCases.contains(row.event),
          "\(at): declared sampled, but \(Self.policyFile) has no `case` for it")
      }
      #expect(
        row.event.hasSuffix(".*") || !row.event.contains("*"),
        "\(at): a family row is `prefix.*` and nothing else")
    }
  }

  static func fingerprint(_ names: [String]) -> String {
    let joined = names.sorted().joined(separator: "\n")
    return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  @Test("the grandfathered set is frozen by count and by identity, and only shrinks")
  func ungradedOnlyRatchetsDown() throws {
    let names = try Self.registryRows().filter { $0.cadence == "ungraded" }.map(\.event)
    #expect(
      names.count == Self.ungradedCeiling,
      """
      \(names.count) ungraded rows, ceiling \(Self.ungradedCeiling). A NEW emitter is never \
      ungraded: give it a cadence, a treatment, a reader and its issue. When you grade an old \
      row, lower `ungradedCeiling` to match in the same change; slack is a free slot.
      """)
    let actual = Self.fingerprint(names)
    #expect(
      actual == Self.ungradedFingerprint,
      """
      The set of ungraded event names changed (same count or not). Swapping a retired row for \
      a new `ungraded` row is not grading. If this change GRADES or RETIRES an old row, set \
      `ungradedFingerprint` to \(actual) and `ungradedCeiling` to \(names.count).
      """)
  }
}
