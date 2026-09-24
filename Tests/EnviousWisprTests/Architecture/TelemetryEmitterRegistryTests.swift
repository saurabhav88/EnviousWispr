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
/// WHAT THIS GUARDS AGAINST, so review rounds do not chase it forever: a session that FORGETS
/// the volume question. Every direct route to PostHog is closed structurally (an unregistered
/// name, a swapped grandfather row, a capture in another file, a stored or re-instantiated
/// singleton, the SDK named as a type, `capture` taken as a function value, a comment inside
/// the receiver, two sites on one line, a defaulted forwarder argument, a shadowing binding of
/// any kind, a second call site for a registered name). What a syntax scan cannot see is a
/// feature calling an EXISTING `TelemetryService` wrapper from a hot path; the rule and code
/// review own that, and an author working to evade this suite is a review finding, not a
/// scanner gap.
///
/// Same shape as `TestInventoryFreezeTests`: `SwiftParser` over every file under `Sources/`
/// (so a capture added outside `TelemetryService.swift` is seen), a text registry under `scripts/`, an equality invariant in
/// both directions, and a ceiling that only ratchets down.
/// `.serialized` for the same RESOURCE reason as `TestInventoryFreezeTests`: three members
/// read the whole-tree scan, and one cached scan run once beats three concurrent parses of
/// every file under `Sources/` on a constrained CI runner.
@Suite("Telemetry emitter registry (#2987)", .serialized, .tags(.driftGuard))
struct TelemetryEmitterRegistryTests {

  // MARK: - Model

  /// Every Swift file under here is scanned. `TelemetryService.swift` is the only caller
  /// today; scanning the tree is what keeps a capture added elsewhere from going unseen.
  static let sourcesDir = "Sources"
  static let policyFile = "Sources/EnviousWisprServices/TelemetryVolumePolicy.swift"
  static let registryFile = "scripts/telemetry-emitter-registry.txt"

  /// Grandfathered rows at the freeze. The count must EQUAL this: grade a row, lower the
  /// number in the same change. Slack here is a free `ungraded` slot for a new emitter.
  static let ungradedCeiling = 108
  /// SHA-256 of the sorted, newline-joined `ungraded` event names. The count alone lets a
  /// retired row be swapped for a new `ungraded` one; the fingerprint pins the IDENTITIES.
  /// The failure message prints the new value; paste it only when grading or retiring.
  /// SHA-256 of `name<TAB>file<TAB>function<TAB>count` for every call site, sorted. A second
  /// or MOVED call site for an already registered name (a per-buffer path reusing
  /// `dictation.completed`) changes the cadence without touching the registry; the fingerprint
  /// makes that a visible edit here.
  /// #3038: `llmPolishCompleted` gained two parameters (`validatorGuard`, `symbolTokens`), which
  /// changes the enclosing-function identity of the same single `llm.polish_completed` site. No
  /// new site, no new event, same per-take cadence; two properties on the existing row (checklist
  /// items 4-8: existing row, shape not content, Int on the wire, `take_id` unchanged, registry
  /// row unchanged).
  /// #996: seven `custom_words.learn_*` sites (one emitter each in `TelemetryService`, all through
  /// `emitLearnEvent`): the watcher's `learn_skipped`, `learn_observation_ended`, `learn_judged`
  /// and the auto-learn coordinator's `learn_save_failed`, `learn_added`, `learn_undo_shown`,
  /// `learn_undone` (2026-09-21 plan; the ask-first flow's five were retired with it). #3069
  /// added one new site: `file_import_completed` via `TelemetryService.trackFileImportCompleted`.
  /// #3106 added one new site: `dictation.last_reused` via `TelemetryService.lastDictationReused`
  /// (per_user_action, keep; checklist: one row per deliberate Paste/Copy Last invocation, three
  /// closed string fields, no content, reader the "Last dictation reuse" insight).
  /// #3106 step 1 added one new site: `paste.landing_observed` via
  /// `TelemetryService.pasteLandingObserved` (per_take, sampled; checklist: one row per committed
  /// arrival session (PR A), closed enums, Int durations, no text or bundle id, reader the "Paste landing"
  /// insight). Derived by removing that one line from the printed site list: the rest hashes to
  /// the previous value.
  /// #3106 PR A: the same single `paste.landing_observed` site gained two parameters
  /// (`lateCheckStatus`, `lateFoundMs`), which changes its enclosing-function identity. No new site,
  /// no new event, same per-take cadence; the row's vocabulary changed under telemetry policy 5
  /// (checklist: existing row, shape not content, Int on the wire, `take_id` unchanged, registry
  /// reader updated for the policy-5 floor).
  /// #3106 PR B: one NEW event, `paste.landing_retained`, one site in `pasteLandingRetained`
  /// (checklist: new registry row, per_take, kept whole, shape only with no text, Bool
  /// `pill_shown`, `take_id` in TAKE_KEYED_EVENTS, reader the #3106 release review).
  static let sitesFingerprint =
    "f8f0047ef994e2c9132be9bf5fe6d5b353e64fa666eb83ecd8664cf3e9770b15"
  static let ungradedFingerprint =
    "1fd54b3c7ba7ac9701ddd2825a5949d0a2cfee218f9f8e66d6eb1931186a0d68"

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
    /// Two captures on one line are two sites, so the column is part of the identity.
    let column: Int
    /// The enclosing function (or `<top>`): the stable site identity `sitesFingerprint` pins,
    /// so moving a capture into a different function is a visible change while re-indenting
    /// or reordering inside one is not.
    let function: String
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
    var forwarders: [String: ForwardSlot]
    /// Bare names that map to conflicting positions, within this file or across files.
    var conflictingForwarders: Set<String> = []
    let collect: Bool
    private var functionStack: [FunctionDeclSyntax] = []
    var emitters: Set<Emitter> = []
    var unresolved: [(what: String, line: Int)] = []

    init(
      converter: SourceLocationConverter, file: String, forwarders: [String: ForwardSlot],
      collect: Bool
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

    private func site(_ node: some SyntaxProtocol) -> (line: Int, column: Int) {
      let location = converter.location(for: node.positionAfterSkippingLeadingTrivia)
      return (location.line, location.column)
    }

    /// `Type.Nested.name(label:label:)`: the type path disambiguates same-named methods
    /// on different types, the labels disambiguate overloads.
    private var enclosingFunction: String {
      guard let function = functionStack.last else {
        return typeStack.joined(separator: ".") + ".<top>"
      }
      let labels = function.signature.parameterClause.parameters.map {
        $0.firstName.text + ":" + $0.type.trimmedDescription
      }
      return (typeStack + [function.name.text + "(" + labels.joined() + ")"]).joined(separator: ".")
    }

    private var typeStack: [String] = []
    private func enterType(_ name: String) -> SyntaxVisitorContinueKind {
      typeStack.append(name)
      return .visitChildren
    }
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
      enterType(node.name.text)
    }
    override func visitPost(_ node: StructDeclSyntax) { typeStack.removeLast() }
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
      enterType(node.name.text)
    }
    override func visitPost(_ node: ClassDeclSyntax) { typeStack.removeLast() }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
      enterType(node.name.text)
    }
    override func visitPost(_ node: ActorDeclSyntax) { typeStack.removeLast() }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
      enterType(node.name.text)
    }
    override func visitPost(_ node: EnumDeclSyntax) { typeStack.removeLast() }
    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
      enterType(node.extendedType.trimmedDescription)
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { typeStack.removeLast() }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
      let at = site(node)
      let arguments = Array(node.arguments)
      if Self.isPostHogCapture(node.calledExpression) {
        if let first = arguments.first?.expression {
          handleCaptureArgument(first, at: at)
        } else if collect {
          unresolved.append(("`PostHogSDK.shared.capture` called with no event name", at.line))
        }
      } else if collect, let (callee, receiver) = Self.forwarderName(node.calledExpression),
        let slot = forwarders[callee]
      {
        // A forwarder reached through another object (`telemetry.emit(...)`) cannot be
        // attributed by name alone; reported rather than skipped.
        guard receiver == nil else {
          unresolved.append(
            ("forwarder \(callee) called through `\(receiver!)`; call it on self", at.line))
          return .visitChildren
        }
        // The event argument is found by LABEL when the parameter has one, by position
        // otherwise; a defaulted event parameter left out is reported, never assumed.
        let argument: LabeledExprSyntax?
        if let label = slot.label {
          argument = arguments.first { $0.label?.text == label }
        } else if slot.position < arguments.count, arguments[slot.position].label == nil {
          argument = arguments[slot.position]
        } else {
          argument = nil
        }
        if let argument, let name = Self.literalName(argument.expression) {
          emitters.insert(
            Emitter(
              name: name, file: file, line: at.line, column: at.column,
              function: enclosingFunction))
        } else {
          unresolved.append(
            ("forwarder \(callee) called without a literal event name", at.line))
        }
      }
      return .visitChildren
    }

    private func handleCaptureArgument(_ argument: ExprSyntax, at: (line: Int, column: Int)) {
      let line = at.line
      if let name = Self.literalName(argument) {
        if collect {
          emitters.insert(
            Emitter(
              name: name, file: file, line: line, column: at.column, function: enclosingFunction))
        }
        return
      }
      guard let reference = argument.as(DeclReferenceExprSyntax.self),
        let function = functionStack.last
      else {
        if collect { unresolved.append(("capture name is not a literal or identifier", line)) }
        return
      }
      let identifier = reference.baseName.text
      let parameters = Array(function.signature.parameterClause.parameters)
      if let position = parameters.firstIndex(where: {
        ($0.secondName ?? $0.firstName).text == identifier
      }) {
        // A parameter that is ALSO bound locally (`let event = ...` in a nested scope) is
        // not a forwarder any scan can attribute; fail closed rather than guess.
        if Self.localLiteral(named: identifier, in: function) != .none {
          if collect {
            unresolved.append(("`\(identifier)` is a parameter shadowed by a local binding", line))
          }
          return
        }
        // A forwarder: its callers carry the literal and are counted in pass 2.
        let name = function.name.text
        let label = parameters[position].firstName.text
        let slot = ForwardSlot(label: label == "_" ? nil : label, position: position)
        if forwarders[name] == .conflicting { return }  // marked by pass 1
        if let known = forwarders[name], known != slot { conflictingForwarders.insert(name) }
        forwarders[name] = slot
        return
      }
      switch Self.localLiteral(named: identifier, in: function) {
      case .one(let name):
        if collect {
          emitters.insert(
            Emitter(
              name: name, file: file, line: line, column: at.column, function: enclosingFunction))
        }
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
    /// The called name and, when it is reached through something other than `self` /
    /// `Self`, the receiver's spelling (so the caller can refuse it).
    static func forwarderName(_ callee: ExprSyntax) -> (name: String, receiver: String?)? {
      if let reference = callee.as(DeclReferenceExprSyntax.self) {
        return (reference.baseName.text, nil)
      }
      if let member = callee.as(MemberAccessExprSyntax.self) {
        let base = member.base?.trimmedDescription
        let name = member.declName.baseName.text
        if base == nil || base == "self" || base == "Self" { return (name, nil) }
        return (name, base)
      }
      return nil
    }

    /// The singleton may only ever be the receiver of a member access (`.capture`, `.flush`,
    /// `.register`, ...). Stored, passed or returned, it becomes an alias whose `.capture`
    /// calls this scan cannot attribute, so the escape itself is reported.
    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
      guard collect else { return .visitChildren }
      if Self.isSingleton(ExprSyntax(node)), node.parent?.is(MemberAccessExprSyntax.self) != true {
        unresolved.append(
          ("`PostHogSDK.shared` escapes into an alias; call it directly", site(node).line))
      }
      // Module-qualified `PostHog.PostHogSDK` used other than as the base of `.shared`.
      if node.declName.baseName.text == "PostHogSDK", Self.isSDKType(ExprSyntax(node)),
        node.parent?.as(MemberAccessExprSyntax.self)?.declName.baseName.text != "shared"
      {
        unresolved.append(("`PostHogSDK` used other than through `.shared`", site(node).line))
      }
      // `PostHogSDK.shared.capture` as a VALUE (stored, passed) is a capture path whose
      // later calls carry no literal; only the callee position of a call is recognised.
      if let base = node.base, Self.isSingleton(base),
        node.declName.baseName.text == "capture",
        node.parent?.is(FunctionCallExprSyntax.self) != true
      {
        unresolved.append(
          ("`PostHogSDK.shared.capture` used as a function value", site(node).line))
      }
      return .visitChildren
    }

    /// `PostHogSDK.shared` matched by TOKENS (trivia such as a comment between them is
    /// ignored), never by source text.
    static func isSingleton(_ expression: ExprSyntax) -> Bool {
      guard let member = expression.as(MemberAccessExprSyntax.self),
        member.declName.baseName.text == "shared",
        let base = member.base
      else { return false }
      return isSDKType(base)
    }

    /// `PostHogSDK` bare, or module-qualified `PostHog.PostHogSDK`.
    static func isSDKType(_ expression: ExprSyntax) -> Bool {
      if let reference = expression.as(DeclReferenceExprSyntax.self) {
        return reference.baseName.text == "PostHogSDK"
      }
      if let member = expression.as(MemberAccessExprSyntax.self),
        member.declName.baseName.text == "PostHogSDK",
        let module = member.base?.as(DeclReferenceExprSyntax.self)
      {
        return module.baseName.text == "PostHog"
      }
      return false
    }

    /// The SDK named in TYPE position (`typealias Client = PostHogSDK`, `let x: PostHogSDK`)
    /// is a second route to the singleton this scan does not follow, so it is reported.
    override func visit(_ node: MemberTypeSyntax) -> SyntaxVisitorContinueKind {
      if collect, node.name.text == "PostHogSDK" {
        unresolved.append(
          (
            "`PostHogSDK` named as a qualified type; only `PostHogSDK.shared.capture` is scanned",
            site(node).line
          ))
      }
      return .visitChildren
    }

    override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
      if collect, node.name.text == "PostHogSDK" {
        unresolved.append(
          (
            "`PostHogSDK` named as a type; only `PostHogSDK.shared.capture` is scanned",
            site(node).line
          ))
      }
      return .visitChildren
    }

    /// Any other spelling of the SDK type as a value (`PostHogSDK()`, `PostHogSDK.self`, a
    /// second instance) is a capture path this scan cannot see, so it is reported too.
    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
      if collect, node.baseName.text == "PostHogSDK" {
        let parent = node.parent?.as(MemberAccessExprSyntax.self)
        // As the MEMBER of `PostHog.PostHogSDK` this node is owned by the member-access
        // visitor above; only a bare base reference is judged here.
        let isMemberName = parent?.base?.as(DeclReferenceExprSyntax.self)?.id != node.id
        let viaShared = parent?.declName.baseName.text == "shared"
        if parent == nil || (!isMemberName && !viaShared) {
          unresolved.append(("`PostHogSDK` used other than through `.shared`", site(node).line))
        }
      }
      return .visitChildren
    }

    /// `PostHogSDK.shared.capture`, spelled exactly as the sanitizer seam expects.
    static func isPostHogCapture(_ callee: ExprSyntax) -> Bool {
      guard let member = callee.as(MemberAccessExprSyntax.self),
        member.declName.baseName.text == "capture",
        let base = member.base
      else { return false }
      return isSingleton(base)
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
      // One binding whose initializer is not a literal (`let event = makeEvent()`) is a
      // binding all the same: never `.none`, which would let a parameter of the same name
      // be read as a forwarder.
      if finder.bindings == 1 { return finder.found.map { .one($0) } ?? .ambiguous }
      return .none
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
      /// EVERY binding of the identifier counts: `let`, `var`, `for ... in`, `if let`,
      /// `case let`, a closure parameter. Only a lone `let` with a literal initializer
      /// resolves; anything else is ambiguous.
      override func visit(_ node: IdentifierPatternSyntax) -> SyntaxVisitorContinueKind {
        guard node.identifier.text == identifier else { return .visitChildren }
        bindings += 1
        guard let binding = node.parent?.as(PatternBindingSyntax.self),
          let declaration = binding.parent?.parent?.as(VariableDeclSyntax.self)
        else {
          mutable = true  // a `for`, `if let`, `case let` or other non-declaration binding
          return .visitChildren
        }
        if declaration.bindingSpecifier.tokenKind != .keyword(.let) { mutable = true }
        if let value = binding.initializer?.value,
          let name = CaptureVisitor.literalName(value)
        {
          found = name
        }
        return .visitChildren
      }
      override func visit(_ node: ClosureShorthandParameterSyntax) -> SyntaxVisitorContinueKind {
        if node.name.text == identifier {
          bindings += 1
          mutable = true
        }
        return .visitChildren
      }
      override func visit(_ node: ClosureParameterSyntax) -> SyntaxVisitorContinueKind {
        if (node.secondName ?? node.firstName).text == identifier {
          bindings += 1
          mutable = true
        }
        return .visitChildren
      }
    }
  }

  /// Where a forwarder's event parameter sits: its label (nil for `_`) and its position.
  struct ForwardSlot: Equatable {
    let label: String?
    let position: Int
    static let conflicting = ForwardSlot(label: nil, position: Int.max)
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
    var forwarders: [String: ForwardSlot] = [:]
    var conflictingForwarders: Set<String> = []
    for (file, tree) in parsed {
      let discovery = CaptureVisitor(
        converter: SourceLocationConverter(fileName: file, tree: tree), file: file,
        forwarders: [:], collect: false)
      discovery.walk(tree)
      // Two forwarders sharing a bare name with the event in different positions: no
      // syntax-only attribution is safe, so every call to that name is reported.
      conflictingForwarders.formUnion(discovery.conflictingForwarders)
      for (name, slot) in discovery.forwarders {
        if let known = forwarders[name], known != slot { conflictingForwarders.insert(name) }
        forwarders[name] = slot
      }
    }
    for name in conflictingForwarders {
      forwarders[name] = .conflicting  // no argument satisfies it: every call is unresolved
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

  /// Run once per process and shared by every member that reads the tree.
  static let cachedScan: Result<(emitters: Set<Emitter>, unresolved: [Unresolved]), Error> =
    Result { try scanSources() }

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

  /// Only the cases of the `switch` whose subject is `event` count: a nested switch on a
  /// property value (`case "success"`) inside one arm is not an event name.
  final class CaseLiteralFinder: SyntaxVisitor {
    var names: Set<String> = []
    override func visit(_ node: SwitchExprSyntax) -> SyntaxVisitorContinueKind {
      guard node.subject.as(DeclReferenceExprSyntax.self)?.baseName.text == "event" else {
        return .skipChildren
      }
      for element in node.cases {
        guard let switchCase = element.as(SwitchCaseSyntax.self),
          let label = switchCase.label.as(SwitchCaseLabelSyntax.self)
        else { continue }
        for item in label.caseItems {
          if let expression = item.pattern.as(ExpressionPatternSyntax.self),
            let name = CaptureVisitor.literalName(expression.expression)
          {
            names.insert(name)
          }
        }
      }
      return .skipChildren
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
        func m() {
          let client = PostHogSDK.shared
          client.capture("hidden.alias")
        }
        func n() { PostHogSDK().capture("hidden.instance") }
        func o() { PostHogSDK.shared.flush() }
        func p() { let f = PostHogSDK.shared.capture; f("hidden.value") }
        typealias Client = PostHogSDK
        typealias Qualified = PostHog.PostHogSDK
        func q() { PostHogSDK /* c */ .shared.capture("eleven.trivia") }
        func r() { PostHogSDK.shared.capture("twelve.a"); PostHogSDK.shared.capture("twelve.a") }
        func defaulted(_ name: String = "hidden.default") { PostHogSDK.shared.capture(name) }
        func s() { defaulted() }
        func t() {
          let event = "thirteen.registered"
          for event in ["hidden.loop"] { PostHogSDK.shared.capture(event) }
        }
        func u() { PostHog.PostHogSDK.shared.capture("fourteen.qualified") }
        func v() { let c = PostHog.PostHogSDK.shared; c.capture("hidden.qualified_alias") }
        func clash(v: String, event: String) { PostHogSDK.shared.capture(event) }
        func w() { clash(v: "x", event: "hidden.conflict_a") }
        func y() { other.forward("hidden.foreign", v: "x") }
        func emit(event: String = "hidden.default_labelled", source: String) {
          PostHogSDK.shared.capture(event)
        }
        func z() { emit(source: "x"); emit(event: "fifteen.labelled", source: "y") }
        func shadowed(event: String) {
          if true { let event = "hidden.shadow"; PostHogSDK.shared.capture(event) }
        }
        func aa() { shadowed(event: "hidden.through_shadow") }
        func computed(event: String) {
          if true { let event = makeEvent(); PostHogSDK.shared.capture(event) }
        }
        func ab() { computed(event: "hidden.through_computed") }
      }
      struct Twin {
        func clash(event: String, v: String) { PostHogSDK.shared.capture(event) }
        func x() { clash(event: "hidden.conflict_b", v: "x") }
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
        "six.second_position", "nine.cross_file", "ten.other_file", "eleven.trivia",
        "twelve.a", "fourteen.qualified", "fifteen.labelled",
      ])
    #expect(
      result.emitters.filter { $0.name == "twelve.a" }.count == 2,
      "two captures on one line are two sites")
    #expect(
      result.emitters.first { $0.name == "ten.other_file" }?.file == "Elsewhere.swift",
      "an emitter reports the file it lives in")
    #expect(
      result.emitters.first { $0.name == "one.literal" }?.function == "Fixture.a()",
      "the site identity is the type path plus the function and its labels")
    let unresolvedMessage =
      "`forward(dynamic)`, the shadowed `event`, the `var event`, the stored singleton, the "
      + "second instance, the function value, the typealias, the defaulted forwarder and the "
      + "loop-shadowed `event` must be reported, not dropped or guessed: \(result.unresolved)"
    #expect(result.unresolved.count == 17, Comment(rawValue: unresolvedMessage))
    #expect(
      !result.emitters.contains { $0.name.hasPrefix("hidden.") },
      "an aliased capture is never counted as a registered emitter")
  }

  @Test("every capture name under Sources resolves")
  func everyCaptureNameResolves() throws {
    let result = try Self.cachedScan.get()
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
    let emitters = try Self.cachedScan.get().emitters
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

    // A mistyped or renamed `case` in `sampledDecision` would silently sample nothing and
    // retain the real event at 100%; every policy case must name a live emitter.
    let orphanCases = try Self.policyCaseNames().subtracting(emitted).sorted()
    #expect(
      orphanCases.isEmpty,
      "\(Self.policyFile) samples \(orphanCases), which no emitter sends; fix the case")
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
      if row.cadence != "ungraded", policyCases.contains(row.event) {
        #expect(
          row.treatment == "sampled",
          "\(at): \(Self.policyFile) samples this event, so a graded row must say `sampled`")
      }
      #expect(
        row.event.hasSuffix(".*") || !row.event.contains("*"),
        "\(at): a family row is `prefix.*` and nothing else")
    }
  }

  @Test("the number of call sites per event is frozen; a new site re-answers the checklist")
  func callSitesAreFrozen() throws {
    let emitters = try Self.cachedScan.get().emitters
    // Identity is (event, file, enclosing function, count within that function): a capture
    // MOVED into a hotter function changes it, a line or column shuffle does not.
    let counts = Dictionary(
      grouping: emitters, by: { "\($0.name)\t\($0.file)\t\($0.function)" }
    ).mapValues(\.count)
    let lines = counts.map { "\($0.key)\t\($0.value)" }
    let actual = Self.fingerprint(lines)
    #expect(
      actual == Self.sitesFingerprint,
      """
      The set of (event, file, function, site count) changed. A new or moved call site for a \
      registered event fires at that site's cadence, which the registry row does not \
      describe: answer the checklist for the site (or fold it), then set `sitesFingerprint` \
      to \(actual).
      Sites now: \(lines.sorted().joined(separator: ", "))
      """)
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
