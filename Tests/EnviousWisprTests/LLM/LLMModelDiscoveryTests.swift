import Testing

@testable import EnviousWisprLLM

/// #158 Grounded Review R1: real cursor pagination for Claude's model
/// catalog, rather than assuming a single page. Tests the pure decision
/// function `LLMModelDiscovery.claudePaginationDecision` — no existing unit
/// test file mocks `LLMModelDiscovery`'s network fetch functions (OpenAI/
/// Gemini discovery is only exercised live via `OpenAILiveSweepTests.swift`,
/// which cannot exercise a malformed-cursor edge case), and the decision was
/// extracted to a pure function specifically so this edge case is directly
/// testable without an HTTP mock.
@Suite("Claude model-discovery pagination")
struct LLMModelDiscoveryTests {

  @Test("has_more false stops pagination regardless of last_id")
  func stopsWhenHasMoreIsFalse() {
    let decision = LLMModelDiscovery.claudePaginationDecision(
      hasMore: false, lastID: "cursor-1", seenCursors: [])
    #expect(decision == .stop)
  }

  @Test("has_more true with a fresh cursor continues to the next page")
  func continuesWithFreshCursor() {
    let decision = LLMModelDiscovery.claudePaginationDecision(
      hasMore: true, lastID: "cursor-1", seenCursors: [])
    #expect(decision == .continue(afterID: "cursor-1"))
  }

  @Test("a second fresh cursor also continues (two-page traversal)")
  func continuesAcrossTwoPages() {
    let firstPage = LLMModelDiscovery.claudePaginationDecision(
      hasMore: true, lastID: "cursor-1", seenCursors: [])
    #expect(firstPage == .continue(afterID: "cursor-1"))

    let secondPage = LLMModelDiscovery.claudePaginationDecision(
      hasMore: true, lastID: "cursor-2", seenCursors: ["cursor-1"])
    #expect(secondPage == .continue(afterID: "cursor-2"))

    let thirdPage = LLMModelDiscovery.claudePaginationDecision(
      hasMore: false, lastID: nil, seenCursors: ["cursor-1", "cursor-2"])
    #expect(thirdPage == .stop)
  }

  @Test("has_more true with a missing last_id is a malformed cursor")
  func malformedWhenLastIDMissing() {
    let decision = LLMModelDiscovery.claudePaginationDecision(
      hasMore: true, lastID: nil, seenCursors: [])
    #expect(decision == .malformedCursor)
  }

  @Test("has_more true with an empty last_id is a malformed cursor")
  func malformedWhenLastIDEmpty() {
    let decision = LLMModelDiscovery.claudePaginationDecision(
      hasMore: true, lastID: "", seenCursors: [])
    #expect(decision == .malformedCursor)
  }

  @Test("has_more true with a repeated cursor is a malformed cursor (prevents an infinite loop)")
  func malformedWhenCursorRepeats() {
    let decision = LLMModelDiscovery.claudePaginationDecision(
      hasMore: true, lastID: "cursor-1", seenCursors: ["cursor-1"])
    #expect(decision == .malformedCursor)
  }
}
