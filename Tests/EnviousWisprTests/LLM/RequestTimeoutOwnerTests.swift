import Foundation
import SwiftParser
import SwiftSyntax
import Testing

@testable import EnviousWisprLLM

/// #2635: the idle ceiling for LLM requests has ONE owner and no shadow copies.
///
/// This is not tidiness. A per-request `timeoutInterval` WINS over the session
/// configuration's — measured 2026-09-04 against a server that accepts and never
/// answers: config 2s with request 8s timed out at 8.00s, config 8s with request
/// 2s timed out at 2.00s, and request unset fell back to the config's 2s at
/// 2.02s. Every connector used to set 60 while the session also set 60, so the
/// two agreed and the shadowing was invisible; anyone raising the session value
/// to chase a slow provider would have changed nothing.
///
/// The regression this guards is copy-paste, not malice. `OllamaConnector` had
/// the same request-building block twice, each with its own copy of the
/// constant, so the next POST method written by copying one would have arrived
/// with a third.
///
/// Tagged `driftGuard`: what a person notices is a slow provider being cut off,
/// and this suite does not reach that far. It pins the ownership.
@Suite("Request timeout has one owner (#2635)", .tags(.driftGuard))
struct RequestTimeoutOwnerTests {

  /// Connectors that send on `LLMNetworkSession.shared.session`. Sessions with
  /// their own configuration are deliberately excluded and named below.
  private static let sharedSessionConnectors = [
    "Sources/EnviousWisprLLM/OpenAIConnector.swift",
    "Sources/EnviousWisprLLM/GeminiConnector.swift",
    "Sources/EnviousWisprLLM/ClaudeConnector.swift",
    "Sources/EnviousWisprLLM/OllamaConnector.swift",
  ]

  /// The property is NOT "no per-request timeout exists". `evictModel` sets 3.0s
  /// deliberately, because a fire-and-forget unload should give up long before a
  /// polish would, and that is a real intent the session cannot express.
  ///
  /// The defect is narrower and it is the one that hides: a per-request value
  /// that RESTATES the session's own. That copy changes nothing while it agrees,
  /// and silently wins the moment somebody edits the session — so the setting
  /// they edited appears to do nothing.
  ///
  /// **THE VALUE-EVALUATING MACHINERY IS DELETED, NOT FIXED A FOURTH TIME.**
  /// Three rounds tried to decide whether a given assignment EQUALS the session's
  /// value, and each fix was correct and exposed a subtler instance of the same
  /// question:
  ///
  ///   1. flag the literal `60`             -> missed `= 3.0` entirely (a sixth
  ///                                           site no value-shaped search found)
  ///   2. flag a literal equal to the owner -> missed
  ///                                           `= LLMNetworkSession.requestTimeoutSeconds`,
  ///                                           which always equals it (CONTROLLED green)
  ///   3. allow only a differing literal    -> missed `= 6_0`, because
  ///                                           `Double("6_0")` is nil and the
  ///                                           `?? .nan` fallback made "cannot
  ///                                           evaluate" look like a number
  ///                                           (CONTROLLED green)
  ///
  /// Each round produced a new SPELLING, never a new axis, which is the signature
  /// of describing a set instead of enumerating one. There is no last spelling:
  /// `0x3c` happens to be caught (Swift's `Double(String)` parses hex floats, so
  /// the review's own example was wrong), `6_0` is not, and the next one is
  /// unknowable.
  ///
  /// So the question is replaced rather than refined. **Every assignment is an
  /// offender unless it is on an explicit allowlist**, matched on exact source
  /// text. No parsing, no evaluation, nothing to be wrong about. A new assignment
  /// in any spelling — literal, reference, hex, underscored, computed, or a form
  /// nobody has written — fails until a person adds it here WITH a reason.
  ///
  /// Round 5 scoped each allowlist key to its ENCLOSING FUNCTION. Keyed on the
  /// file alone, a second `= 3.0` added to a polish request builder produced the
  /// same key as `evictModel`'s and was accepted — CONTROLLED green before the
  /// fix and red after, naming `polish()`. That was a new AXIS (key uniqueness),
  /// not another spelling, which is why it earned a round.
  ///
  /// **PRE-COMMITTED, declared before the next verdict is read: a SIXTH finding
  /// on this assertion DELETES this test rather than refining it again.** Five
  /// rounds is already past the point where the fixes are cleverer than the
  /// defect, and the user-visible benefit of a sixth would be nil — what a person
  /// feels was delivered by removing the five shadow copies, not by this guard.
  /// If it comes to that, delete the file and rely on review. Do not negotiate
  /// this paragraph.
  @Test("no connector sets a per-request timeout that is not explicitly allowed")
  func noShadowCopies() throws {
    var offenders: [String] = []
    var seenAllowed: Set<String> = []
    for path in Self.sharedSessionConnectors {
      let url = RepoRoot.sourceURL(path)
      let source = try String(contentsOf: url, encoding: .utf8)
      let visitor = TimeoutAssignmentVisitor(viewMode: .sourceAccurate)
      visitor.walk(Parser.parse(source: source))
      for text in visitor.assignments {
        let key = "\(path)|\(text.function)|\(text.assignment)"
        if Self.allowedAssignments[key] != nil {
          seenAllowed.insert(key)
        } else {
          offenders.append("\(path): \(text.function)(): \(text.assignment)")
        }
      }
    }
    #expect(
      offenders.isEmpty,
      """
      per-request timeout assignments that are not explicitly allowed: \(offenders).

      A per-request value WINS over `LLMNetworkSession`'s configuration \
      (measured), so a copy that matches it does nothing today and silently \
      overrides the session the moment anyone edits it there.

      Delete the assignment. If this request genuinely needs a different ceiling, \
      add it to `allowedAssignments` with the reason — that is a deliberate, \
      reviewable act, which is the point. If it needs a computed one, give it its \
      own URLSession the way `OllamaConnector.readinessSession` does.
      """)

    // The allowlist must not rot: every entry has to still be present, or a
    // deletion silently hands that request the session's ceiling instead.
    let missing = Set(Self.allowedAssignments.keys).subtracting(seenAllowed)
    #expect(
      missing.isEmpty,
      """
      allowlisted timeouts are GONE from the source: \(missing).
      Each was there for a reason recorded beside it; deleting one silently gives \
      that request the session's ceiling.
      """)
  }

  /// The only per-request timeouts allowed on the shared session, keyed by
  /// `path|exact source text`, valued by WHY. Adding an entry is the deliberate
  /// act this guard exists to force.
  private static let allowedAssignments: [String: String] = [
    "Sources/EnviousWisprLLM/OllamaConnector.swift|evictModel|request.timeoutInterval = 3.0":
      "a fire-and-forget model unload must give up long before a polish would, "
      + "and the shared session cannot express that."
  ]

  /// Two-way control: the visitor must actually be able to SEE an assignment, or
  /// the test above passes because it is blind rather than because the code is
  /// clean. Same class of defect as a sweep whose pattern never matches.
  @Test("the detector fires on a file that does set one")
  func detectorIsNotBlind() {
    let source = """
      func send() {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
      }
      """
    let visitor = TimeoutAssignmentVisitor(viewMode: .sourceAccurate)
    visitor.walk(Parser.parse(source: source))
    #expect(visitor.assignments.count == 1)
    #expect(visitor.assignments.first?.assignment == "request.timeoutInterval = 60")
    #expect(visitor.assignments.first?.function == "send")
  }

  /// The constants are actually WIRED to the session, asserted without naming
  /// either number.
  ///
  /// Review caught the first version pinning `60` and `180` here, which
  /// reintroduced the exact defect this change removes: a one-file edit to the
  /// owner would have failed CI until somebody also edited this test, so the
  /// policy still had two owners. Asserting the WIRING instead is both
  /// number-free and strictly stronger — it fails if a constant is declared and
  /// then not used in the configuration, which pinning the value could never see.
  ///
  /// Uses an isolated instance rather than `LLMNetworkSession.shared`, for the
  /// reason `freshSession()` gives in `LLMWarmupGateTests`.
  @Test("both ceilings are wired to the session, whatever their values are")
  func ceilingsAreWiredNotJustDeclared() {
    let config = LLMNetworkSession.makeIsolatedForTesting().session.configuration
    #expect(config.timeoutIntervalForRequest == LLMNetworkSession.requestTimeoutSeconds)
    #expect(config.timeoutIntervalForResource == LLMNetworkSession.resourceTimeoutSeconds)
  }
}

/// Finds assignments to a `timeoutInterval` member, structurally. Not a string
/// match: `timeoutInterval` in a comment, a log line or a READ does not count,
/// and only a write does.
///
/// The node is `SequenceExprSyntax`, NOT `InfixOperatorExprSyntax`. A raw parse
/// does not fold operators, so `a.b = c` arrives as a flat sequence of
/// [member access, AssignmentExpr, value]; the folded `InfixOperatorExpr` shape
/// only exists after `OperatorTable` folding, which nothing here runs. The first
/// version of this visitor matched the folded shape, found nothing, and the
/// suite's real assertion passed because the detector was BLIND rather than
/// because the code was clean. `detectorIsNotBlind` is what caught that, and it
/// is the reason this file has a two-way control at all.
private final class TimeoutAssignmentVisitor: SyntaxVisitor {
  struct Site {
    /// Name of the enclosing function, or `<top-level>`.
    let function: String
    /// Exact source text of the assignment, trimmed. No value is extracted and
    /// none is evaluated — deciding what an expression EQUALS is the question
    /// this suite deleted rather than answered.
    let assignment: String
  }

  private(set) var assignments: [Site] = []
  private var functionStack: [String] = []

  override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
    functionStack.append(node.name.text)
    return .visitChildren
  }

  override func visitPost(_ node: FunctionDeclSyntax) {
    functionStack.removeLast()
  }

  override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
    let elements = Array(node.elements)
    for (index, element) in elements.enumerated() where element.is(AssignmentExprSyntax.self) {
      guard index > 0,
        let member = elements[index - 1].as(MemberAccessExprSyntax.self),
        member.declName.baseName.text == "timeoutInterval"
      else { continue }
      assignments.append(
        Site(
          function: functionStack.last ?? "<top-level>",
          assignment: node.trimmedDescription))
    }
    return .visitChildren
  }
}
