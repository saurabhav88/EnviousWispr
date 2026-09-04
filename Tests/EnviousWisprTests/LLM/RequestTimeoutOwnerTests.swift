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
  /// they edited appears to do nothing. A DIFFERENT value is intent; an EQUAL
  /// value is a shadow.
  ///
  /// Enumerated by CAPABILITY, not by the value I expected. The first version of
  /// this test looked for assignments of `60` because that was the number in the
  /// diff, and a grep for `= 60` is what produced the original five-site list.
  /// Asking for every assignment instead immediately returned a sixth site at
  /// `OllamaConnector.swift:485` that no value-shaped search could have found.
  @Test("no connector restates the session's own timeout on a request")
  func noShadowCopies() throws {
    var offenders: [String] = []
    var deliberate: [String] = []
    for path in Self.sharedSessionConnectors {
      let url = RepoRoot.sourceURL(path)
      let source = try String(contentsOf: url, encoding: .utf8)
      let visitor = TimeoutAssignmentVisitor(viewMode: .sourceAccurate)
      visitor.walk(Parser.parse(source: source))
      for assignment in visitor.assignments {
        if assignment.literal == LLMNetworkSession.requestTimeoutSeconds {
          offenders.append("\(path): \(assignment.text)")
        } else {
          deliberate.append("\(path): \(assignment.text)")
        }
      }
    }
    #expect(
      offenders.isEmpty,
      """
      per-request timeouts restating the session's own \
      (\(LLMNetworkSession.requestTimeoutSeconds)s): \(offenders).
      A per-request value WINS over the configuration, so this copy does nothing \
      today and silently overrides the session the moment anyone edits it there. \
      Delete the assignment. If this request genuinely needs a different ceiling, \
      set a different NUMBER and say why — that is allowed and this test permits \
      it.
      """)

    // Two-way: the deliberate one must still be VISIBLE, or a future edit that
    // deletes it goes unnoticed and a fire-and-forget unload silently inherits a
    // 60-second ceiling.
    #expect(
      deliberate.contains { $0.contains("OllamaConnector") && $0.contains("3.0") },
      "the deliberate 3.0s evict timeout is gone; it is intent, not a shadow: \(deliberate)")
  }

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
    #expect(visitor.assignments.first?.literal == 60)
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
  struct Assignment {
    let text: String
    /// The assigned number when it is a plain literal, else nil — a computed
    /// value is never a shadow, because it cannot silently equal the session's.
    let literal: Double?
  }

  private(set) var assignments: [Assignment] = []

  override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
    let elements = Array(node.elements)
    for (index, element) in elements.enumerated() where element.is(AssignmentExprSyntax.self) {
      guard index > 0,
        let member = elements[index - 1].as(MemberAccessExprSyntax.self),
        member.declName.baseName.text == "timeoutInterval",
        index + 1 < elements.count
      else { continue }
      let value = elements[index + 1]
      let literal =
        value.as(FloatLiteralExprSyntax.self).map { Double($0.literal.text) ?? .nan }
        ?? value.as(IntegerLiteralExprSyntax.self).map { Double($0.literal.text) ?? .nan }
      assignments.append(Assignment(text: node.trimmedDescription, literal: literal))
    }
    return .visitChildren
  }
}
