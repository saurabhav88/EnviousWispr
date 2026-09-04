import EnviousWisprCore
import Foundation
import SwiftParser
import SwiftSyntax
import Testing
import os

@testable import EnviousWisprLLM

/// #2093: the cloud pre-warm no longer fires on every recording.
///
/// It costs one provider request on the USER'S OWN key, and it used to fire on
/// every launch, every foreground and every recording start. Over 60 days
/// `rate_or_quota` — the provider refusing us for quota — was the largest cloud
/// polish failure we had (442 events / 4 users), and every one was Gemini.
///
/// Tagged `driftGuard` rather than `productOutcome` on purpose. What a person
/// notices is "my cleanup got refused", and this suite does not reach that far:
/// it pins the decision, the state machine and its atomicity. Claiming product
/// coverage here would inflate the split `TestInventoryFreezeTests` reports.
@Suite("Cloud pre-warm gate (#2093)", .tags(.driftGuard))
struct LLMWarmupGateTests {

  /// An ISOLATED instance per test, never `LLMNetworkSession.shared`.
  ///
  /// Review finding (2026-09-03): the first version reset the shared singleton.
  /// Swift Testing runs tests concurrently, and production `LLMPolishStep` calls
  /// `recordPolishSuccess` on `shared`, so resetting it here could race any
  /// other suite that polishes — nondeterministic failures and state leaking out
  /// of this file. Nothing in this suite needs the real shared session.
  private func freshSession() -> LLMNetworkSession {
    let s = LLMNetworkSession.makeIsolatedForTesting()
    s.resetWarmStateForTesting()
    return s
  }

  // MARK: - The decision

  /// EXHAUSTIVE over `LLMProvider`. The production switch has no `default:`, so
  /// adding a provider breaks the build until someone decides; this asserts the
  /// decision that shipped, one row per case, so a future edit that flips a
  /// provider back to warming-always fails here rather than in production
  /// quota telemetry weeks later.
  @Test(
    "every provider's warm-up policy is the one #2093 decided",
    arguments: [
      (LLMProvider.gemini, LLMNetworkSession.CloudWarmupPolicy.never),
      (LLMProvider.openAI, .whenCold),
      (LLMProvider.claude, .whenCold),
      (LLMProvider.ollama, .never),
      (LLMProvider.egOne, .never),
      (LLMProvider.appleIntelligence, .never),
      (LLMProvider.none, .never),
    ])
  func cloudWarmupPolicyPerProvider(provider: LLMProvider, expected: LLMNetworkSession.CloudWarmupPolicy) {
    #expect(LLMNetworkSession.cloudWarmupPolicy(for: provider) == expected)
  }

  /// The regression this issue exists to prevent, stated as its own row: Gemini
  /// must never warm, whatever else changes.
  @Test("Gemini never warms")
  func geminiNeverWarms() {
    #expect(LLMNetworkSession.cloudWarmupPolicy(for: .gemini) == .never)
  }

  // MARK: - Gemini touches nothing

  /// `preWarmModel` is the shared door all three cloud providers enter, so
  /// "removing Gemini cannot affect OpenAI or Claude" is not free — it depends
  /// on the Gemini guard running BEFORE any state is touched.
  ///
  /// Observable proof rather than a reading of the source: after a Gemini call,
  /// the slot is still claimable, which is only true if no in-flight marker was
  /// left behind. A guard placed after the claim would fail this.
  @Test("a Gemini pre-warm leaves no in-flight marker behind")
  func geminiLeavesNoState() {
    let session = freshSession()
    session.preWarmModel(
      provider: .gemini, model: "gemini-3.6-flash", keychainManager: KeychainManager())
    #expect(session.claimWarmupSlot(provider: .gemini, model: "gemini-3.6-flash", now: Date()))
  }

  // MARK: - The cold window

  @Test("a cold (provider, model) may warm; a warm one may not")
  func coldWindow() {
    let session = freshSession()
    let now = Date()

    #expect(session.claimWarmupSlot(provider: .openAI, model: "gpt-5.4-nano", now: now))
    session.releaseWarmupSlot(provider: .openAI, model: "gpt-5.4-nano", succeededAt: now)

    // Inside the window: no second warm-up.
    let justInside = now.addingTimeInterval(LLMNetworkSession.warmWindowSeconds - 1)
    #expect(!session.claimWarmupSlot(provider: .openAI, model: "gpt-5.4-nano", now: justInside))

    // Outside it: cold again. Injected clock, never a real sleep — this suite
    // must not depend on scheduling precision.
    let justOutside = now.addingTimeInterval(LLMNetworkSession.warmWindowSeconds + 1)
    #expect(session.claimWarmupSlot(provider: .openAI, model: "gpt-5.4-nano", now: justOutside))
  }

  /// Warmth is keyed on the PAIR. Switching model inside the window is a
  /// different route and must be treated as cold, or the first dictation after a
  /// model change silently loses the warm-up it was supposed to get.
  @Test("warmth is per (provider, model), not per provider")
  func warmthIsPerPair() {
    let session = freshSession()
    let now = Date()
    #expect(session.claimWarmupSlot(provider: .openAI, model: "gpt-5.4-nano", now: now))
    session.releaseWarmupSlot(provider: .openAI, model: "gpt-5.4-nano", succeededAt: now)

    #expect(session.claimWarmupSlot(provider: .openAI, model: "gpt-5.4-mini", now: now))
    #expect(session.claimWarmupSlot(provider: .claude, model: "gpt-5.4-nano", now: now))
  }

  /// A non-2xx warm-up proves the route is reachable and nothing else. Recording
  /// warmth on it would suppress the next real attempt on the strength of a
  /// failure — the arm that quietly makes a broken provider look warm forever.
  @Test("a failed warm-up frees the slot and records no warmth")
  func failedWarmupRecordsNothing() {
    let session = freshSession()
    let now = Date()
    #expect(session.claimWarmupSlot(provider: .claude, model: "claude-haiku-4-5", now: now))
    session.releaseWarmupSlot(provider: .claude, model: "claude-haiku-4-5", succeededAt: nil)
    // Immediately claimable again: not warm, not stuck in flight.
    #expect(session.claimWarmupSlot(provider: .claude, model: "claude-haiku-4-5", now: now))
  }

  // MARK: - The real-polish producer

  @Test("an accepted polish marks the pair warm")
  func acceptedPolishMarksWarm() {
    let session = freshSession()
    let now = Date()
    session.recordPolishSuccess(provider: .openAI, model: "gpt-5.4-nano", at: now)
    #expect(!session.claimWarmupSlot(provider: .openAI, model: "gpt-5.4-nano", now: now))
  }

  /// Gemini has no warm state to hold, so the producer must be inert for it.
  /// Asserted rather than assumed: a future edit that drops the policy guard
  /// inside `recordPolishSuccess` would start accumulating state nothing reads.
  @Test("recording a Gemini polish changes nothing")
  func geminiPolishRecordsNothing() {
    let session = freshSession()
    let now = Date()
    session.recordPolishSuccess(provider: .gemini, model: "gemini-3.6-flash", at: now)
    #expect(session.claimWarmupSlot(provider: .gemini, model: "gemini-3.6-flash", now: now))
  }

  @Test("an empty model name records nothing")
  func emptyModelRecordsNothing() {
    let session = freshSession()
    let now = Date()
    session.recordPolishSuccess(provider: .openAI, model: "", at: now)
    #expect(session.claimWarmupSlot(provider: .openAI, model: "", now: now))
  }

  // MARK: - Atomicity

  /// The decide-and-claim must be ONE critical section.
  ///
  /// A check-then-act across two reads passes every test above, because a
  /// single-threaded test cannot open the window between them.
  /// **This test was VACUOUS on its first writing and the control caught it.**
  /// A `withTaskGroup` of 64 children finished in 0.001s and passed against a
  /// deliberately broken check-then-act implementation, because `claimWarmupSlot`
  /// never suspends: each child ran start-to-finish before the next was
  /// scheduled, so the window between the check and the act was never opened.
  /// A concurrency test that cannot interleave is decoration.
  ///
  /// **AND THE SECOND ATTEMPT FAILED THE CONTROL TOO.** Rewritten to use
  /// `DispatchQueue.concurrentPerform` — real OS threads — across 400 trials of
  /// 32 racers, it STILL passed against the broken split-lock version, in 6ms.
  /// The critical section is two dictionary lookups; the window between a split
  /// check and act is on the order of nanoseconds, and real threads do not
  /// reliably land inside it.
  ///
  /// **What it does and does not catch, measured against three splits, and the
  /// discriminator is WHICH operation moves — not how wide the window is.** It
  /// catches a split that separates the IN-FLIGHT read from the in-flight write
  /// across a call boundary: 2 winners immediately. It misses that same split
  /// when the two sit adjacent, a few nanoseconds apart. And it misses a split
  /// that moves only the WARMTH read out — measured 2026-09-03, one winner,
  /// green — because `inFlight` is still read and written under one lock there,
  /// so nothing races even though the decision is no longer atomic.
  ///
  /// That last case is the one worth carrying: a real race test reports a real
  /// green against code whose guarantee is already broken. Only the structural
  /// guard below sees it.
  @Test("concurrent claims under real threads yield one winner (smoke, not the guard)")
  func concurrentClaimsProduceOneWinner() {
    let session = freshSession()
    for trial in 0..<400 {
      session.resetWarmStateForTesting()
      let model = "gpt-5.4-nano-\(trial)"
      let now = Date()
      let winners = OSAllocatedUnfairLock<Int>(initialState: 0)
      DispatchQueue.concurrentPerform(iterations: 32) { _ in
        if session.claimWarmupSlot(provider: .openAI, model: model, now: now) {
          winners.withLock { $0 += 1 }
        }
      }
      let count = winners.withLock { $0 }
      #expect(count == 1, "trial \(trial) produced \(count) winners")
      if count != 1 { return }
    }
  }

  /// **Two review rounds have now landed on this one assertion, so it asserts
  /// the whole property rather than another clause.** Round 2: the first
  /// version counted lock acquisitions, and a count says nothing about what is
  /// inside one. Round 3: counting the NAMES inside the lock is the same defect
  /// one level in — `inFlight` and `lastSuccess` can both appear inside the
  /// closure while `inFlight.insert` has moved out to a separately locking
  /// helper, which is check-then-act again with every name assertion green.
  ///
  /// So the unit is the OPERATION, not the name. All three of the decision's
  /// parts must sit inside ONE `withLock` closure: the in-flight read, the
  /// warmth read, and the in-flight write.
  ///
  /// Controlled 2026-09-03 against both splits, each applied to the real source
  /// and each red HERE and nowhere else in the suite: moving the in-flight
  /// check-and-write into a lock-taking helper while both reads stay in the
  /// original closure, and moving the WARMTH READ into one. The race test above
  /// stayed green on both. Recipes in #2632.
  @Test("the claim decides and commits inside ONE critical section")
  func claimIsASingleCriticalSection() throws {
    let url = RepoRoot.sourceURL("Sources/EnviousWisprLLM/LLMNetworkSession.swift")
    let tree = Parser.parse(source: try String(contentsOf: url, encoding: .utf8))
    let visitor = CriticalSectionVisitor(functionName: "claimWarmupSlot", viewMode: .sourceAccurate)
    visitor.walk(tree)

    #expect(visitor.functionFound, "claimWarmupSlot not found — did it get renamed?")
    #expect(
      visitor.lockCallCount == 1,
      "claimWarmupSlot takes the lock \(visitor.lockCallCount) times, expected exactly 1")
    #expect(
      visitor.stateTouchesOutsideLock.isEmpty,
      """
      warm state touched OUTSIDE the critical section: \(visitor.stateTouchesOutsideLock).
      Every read and write must be inside the single lock, or the decision and the \
      claim are separable and two callers can both warm.
      """)
    #expect(
      visitor.sectionsHoldingTheWholeDecision == 1,
      """
      no single critical section performs the whole decision. Sections found: \
      \(visitor.operationsPerSection.map { $0.sorted() }). \
      One `withLock` closure must contain ALL of \
      \(CriticalSectionVisitor.wholeDecision.sorted()) — the in-flight read, the \
      warmth read and the in-flight write together. Splitting any one of them into \
      a separately locking helper reopens the race with every name still present.
      """)
  }
}

/// Verifies that a named function performs its whole guarded decision inside a
/// single `withLock` closure.
///
/// The unit is the OPERATION (`inFlight.contains`, `lastSuccess[]`,
/// `inFlight.insert`), never the bare property name. A name-based check passes
/// against a version that reads both names inside the lock and writes one of
/// them outside it, which is exactly the race being guarded.
private final class CriticalSectionVisitor: SyntaxVisitor {
  private static let stateNames: Set<String> = ["inFlight", "lastSuccess"]

  /// Every operation the decision is made of. A section holding all three has
  /// decided and committed without releasing the lock.
  static let wholeDecision: Set<String> = [
    "inFlight.contains", "inFlight.insert", "lastSuccess[]",
  ]

  private let functionName: String
  private(set) var functionFound = false
  private(set) var lockCallCount = 0
  private(set) var stateTouchesOutsideLock: [String] = []
  private(set) var operationsPerSection: [Set<String>] = []

  var sectionsHoldingTheWholeDecision: Int {
    operationsPerSection.filter { Self.wholeDecision.isSubset(of: $0) }.count
  }

  private var functionRange: Range<AbsolutePosition>?
  private var lockRanges: [Range<AbsolutePosition>] = []
  private var tokensSeen: [(String, AbsolutePosition)] = []
  private var operationsSeen: [(String, AbsolutePosition)] = []

  init(functionName: String, viewMode: SyntaxTreeViewMode) {
    self.functionName = functionName
    super.init(viewMode: viewMode)
  }

  override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
    guard node.name.text == functionName else { return .visitChildren }
    functionFound = true
    functionRange = node.position..<node.endPosition
    return .visitChildren
  }

  override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
    guard let fnRange = functionRange, fnRange.contains(node.position) else {
      return .visitChildren
    }
    if let member = node.calledExpression.as(MemberAccessExprSyntax.self) {
      let method = member.declName.baseName.text
      if method == "withLock" {
        lockCallCount += 1
        lockRanges.append(node.position..<node.endPosition)
      } else if let owner = Self.stateName(of: member.base) {
        operationsSeen.append(("\(owner).\(method)", node.position))
      }
    }
    return .visitChildren
  }

  override func visit(_ node: SubscriptCallExprSyntax) -> SyntaxVisitorContinueKind {
    guard let fnRange = functionRange, fnRange.contains(node.position) else {
      return .visitChildren
    }
    if let owner = Self.stateName(of: node.calledExpression) {
      operationsSeen.append(("\(owner)[]", node.position))
    }
    return .visitChildren
  }

  override func visit(_ token: TokenSyntax) -> SyntaxVisitorContinueKind {
    if Self.stateNames.contains(token.text) {
      tokensSeen.append((token.text, token.position))
    }
    return .skipChildren
  }

  override func visitPost(_ node: SourceFileSyntax) {
    guard let fnRange = functionRange else { return }
    for (name, pos) in tokensSeen where fnRange.contains(pos) {
      if !lockRanges.contains(where: { $0.contains(pos) }) {
        stateTouchesOutsideLock.append(name)
      }
    }
    operationsPerSection = lockRanges.map { range in
      Set(operationsSeen.filter { range.contains($0.1) }.map(\.0))
    }
  }

  /// The guarded property an expression is rooted at, if any — `state.inFlight`
  /// and a bare `inFlight` both answer `inFlight`.
  private static func stateName(of expr: ExprSyntax?) -> String? {
    guard let expr else { return nil }
    if let member = expr.as(MemberAccessExprSyntax.self),
      stateNames.contains(member.declName.baseName.text)
    {
      return member.declName.baseName.text
    }
    if let ref = expr.as(DeclReferenceExprSyntax.self),
      stateNames.contains(ref.baseName.text)
    {
      return ref.baseName.text
    }
    return nil
  }
}
