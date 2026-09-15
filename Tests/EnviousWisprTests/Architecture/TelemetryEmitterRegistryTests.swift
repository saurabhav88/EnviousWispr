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
/// Same shape as `TestInventoryFreezeTests`: `SwiftParser` over the one file that calls
/// `PostHogSDK.shared.capture`, a text registry under `scripts/`, an equality invariant in
/// both directions, and a ceiling that only ratchets down.
@Suite("Telemetry emitter registry (#2987)", .tags(.driftGuard))
struct TelemetryEmitterRegistryTests {

  // MARK: - Model

  static let emitterFile = "Sources/EnviousWisprServices/TelemetryService.swift"
  static let policyFile = "Sources/EnviousWisprServices/TelemetryVolumePolicy.swift"
  static let registryFile = "scripts/telemetry-emitter-registry.txt"

  /// Grandfathered rows at the freeze. ONLY EVER DECREASES: grade a row, lower the number.
  static let ungradedCeiling = 110

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
    let line: Int
  }

  // MARK: - Scanner

  /// Two passes over one file. Pass 1 learns which functions FORWARD a parameter into
  /// `PostHogSDK.shared.capture` (`emitUpdateStage(_ name:)`); pass 2 collects every direct
  /// capture with a resolvable name plus every call to a forwarder with a literal name.
  final class CaptureVisitor: SyntaxVisitor {
    let converter: SourceLocationConverter
    /// Function names whose capture argument is one of their own parameters, with the
    /// POSITION of that parameter, so a caller's argument at the same position is read.
    var forwarders: [String: Int]
    let collect: Bool
    private var functionStack: [FunctionDeclSyntax] = []
    var emitters: Set<Emitter> = []
    var unresolved: [(what: String, line: Int)] = []

    init(converter: SourceLocationConverter, forwarders: [String: Int], collect: Bool) {
      self.converter = converter
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
          emitters.insert(Emitter(name: name, line: line))
        } else {
          unresolved.append(("forwarder \(callee) called with a non-literal event name", line))
        }
      }
      return .visitChildren
    }

    private func handleCaptureArgument(_ argument: ExprSyntax, line: Int) {
      if let name = Self.literalName(argument) {
        if collect { emitters.insert(Emitter(name: name, line: line)) }
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
        if collect { emitters.insert(Emitter(name: name, line: line)) }
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

  static func scan(source: String, fileName: String) -> (
    emitters: Set<Emitter>, unresolved: [(what: String, line: Int)]
  ) {
    let tree = Parser.parse(source: source)
    let converter = SourceLocationConverter(fileName: fileName, tree: tree)
    let discovery = CaptureVisitor(converter: converter, forwarders: [:], collect: false)
    discovery.walk(tree)
    let collector = CaptureVisitor(
      converter: converter, forwarders: discovery.forwarders, collect: true)
    collector.walk(tree)
    return (collector.emitters, collector.unresolved)
  }

  static func scanEmitterFile() throws -> (
    emitters: Set<Emitter>, unresolved: [(what: String, line: Int)]
  ) {
    let url = RepoRoot.sourceURL(emitterFile)
    let source = try String(contentsOf: url, encoding: .utf8)
    return scan(source: source, fileName: emitterFile)
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
    let result = Self.scan(source: source, fileName: "Fixture.swift")
    #expect(
      Set(result.emitters.map(\.name)) == [
        "one.literal", "two.local", "three.*", "four.forwarded", "five.self_forwarded",
        "six.second_position",
      ])
    let unresolvedMessage =
      "`forward(dynamic)`, the shadowed `event` and the `var event` must be reported, not "
      + "dropped or guessed: \(result.unresolved)"
    #expect(result.unresolved.count == 3, Comment(rawValue: unresolvedMessage))
  }

  @Test("every capture name in the emitter file resolves")
  func everyCaptureNameResolves() throws {
    let result = try Self.scanEmitterFile()
    #expect(
      result.unresolved.isEmpty,
      """
      \(result.unresolved.count) capture(s) whose event name this suite cannot read. Pass a \
      string literal, a local `let` literal, or a forwarder parameter:
      \(result.unresolved.map { "  \(Self.emitterFile):\($0.line) \($0.what)" }.joined(separator: "\n"))
      """)
    #expect(
      result.emitters.count > 80,
      "found \(result.emitters.count) emitters; refusing to treat that as the whole file")
  }

  @Test("every emitter has a registry row, and every row names a live emitter")
  func registryMatchesEmitters() throws {
    let emitters = try Self.scanEmitterFile().emitters
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
      \(unregistered.map { "  \(Self.emitterFile):\($0.line) \($0.name)" }.joined(separator: "\n"))

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
    let policy = try String(contentsOf: RepoRoot.sourceURL(Self.policyFile), encoding: .utf8)
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
          policy.contains("\"\(row.event)\""),
          "\(at): declared sampled, but \(Self.policyFile) never names it")
      }
      #expect(
        row.event.hasSuffix(".*") || !row.event.contains("*"),
        "\(at): a family row is `prefix.*` and nothing else")
    }
  }

  @Test("the grandfathered count only ratchets down")
  func ungradedOnlyRatchetsDown() throws {
    let ungraded = try Self.registryRows().filter { $0.cadence == "ungraded" }.count
    #expect(
      ungraded <= Self.ungradedCeiling,
      """
      \(ungraded) ungraded rows, ceiling \(Self.ungradedCeiling). A NEW emitter is never \
      ungraded: give it a cadence, a treatment, a reader and its issue. When you grade an old \
      row, lower `ungradedCeiling` to match.
      """)
  }
}
