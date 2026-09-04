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

  private func freshSession() -> LLMNetworkSession {
    let s = LLMNetworkSession.shared
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

    // Outside it: cold again. Injected clock, never a real sleep
    // (`swift-patterns.md` RULE: tests-no-real-time-scheduling-precision).
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
  /// single-threaded test cannot open the window between them
  /// (`validation-discipline.md`
  /// RULE: a-single-threaded-test-cannot-distinguish-atomic-from-check-then-act).
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
  /// **So this test is NOT the guard for atomicity, and must not be read as
  /// one.** It is a smoke test: it exercises the claim under genuine parallelism
  /// and would catch a gross regression such as removing the lock entirely. The
  /// property "decide and claim happen in ONE critical section" is pinned
  /// STRUCTURALLY by `claimIsASingleCriticalSection` below, because that is a
  /// question about the code's shape and the machine can answer it exactly —
  /// where a timing test can only ever answer "I did not happen to see it".
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

  /// THE ACTUAL ATOMICITY GUARD.
  ///
  /// Two review rounds and two failed controls established that this property
  /// cannot be demonstrated by racing: the window is nanoseconds wide and a
  /// timing test that never opens it reports green against broken code. So ask
  /// the machine about the SHAPE instead, which it can answer exactly.
  ///
  /// `claimWarmupSlot` must take the lock EXACTLY ONCE. Two acquisitions is the
  /// check-then-act bug, and it is invisible in every behavioural test.
  /// Parsed, never grepped — `swift-patterns.md`
  /// RULE: scan-swift-source-with-swiftparser-never-a-hand-rolled-lexer.
  @Test("the claim decides and commits inside ONE critical section")
  func claimIsASingleCriticalSection() throws {
    let url = RepoRoot.sourceURL("Sources/EnviousWisprLLM/LLMNetworkSession.swift")
    let tree = Parser.parse(source: try String(contentsOf: url, encoding: .utf8))
    let visitor = LockCountVisitor(functionName: "claimWarmupSlot", viewMode: .sourceAccurate)
    visitor.walk(tree)

    #expect(visitor.functionFound, "claimWarmupSlot not found — did it get renamed?")
    #expect(
      visitor.lockCallCount == 1,
      """
      claimWarmupSlot takes the lock \(visitor.lockCallCount) times, expected exactly 1.
      More than one acquisition means the decision and the claim are separable, which is       the check-then-act race. No behavioural test in this suite can see it — that was       measured twice, so this assertion is the only thing standing between us and it.
      """)
  }
}

/// Counts `withLock` calls inside one named function.
private final class LockCountVisitor: SyntaxVisitor {
  private let functionName: String
  private(set) var functionFound = false
  private(set) var lockCallCount = 0
  private var depth = 0

  init(functionName: String, viewMode: SyntaxTreeViewMode) {
    self.functionName = functionName
    super.init(viewMode: viewMode)
  }

  override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
    guard node.name.text == functionName else { return .visitChildren }
    functionFound = true
    depth += 1
    return .visitChildren
  }

  override func visitPost(_ node: FunctionDeclSyntax) {
    if node.name.text == functionName { depth -= 1 }
  }

  override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
    guard depth > 0 else { return .visitChildren }
    if let member = node.calledExpression.as(MemberAccessExprSyntax.self),
      member.declName.baseName.text == "withLock"
    {
      lockCallCount += 1
    }
    return .visitChildren
  }
}
