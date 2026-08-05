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

  // MARK: - #1914 Ollama remoteness reaches the selection dropdown

  /// Pins the FIRST link, from a `/api/tags` row into a discovery candidate.
  /// `candidateRemotenessReachesModelInfo` separately pins the final handoff
  /// into the row consumed by selection and auto-selection. Two links, two
  /// tests: a control aimed only here would miss a mutation in the other.
  ///
  /// Extracted as a pure function for the same reason `claudePaginationDecision`
  /// was — this file has no HTTP mock, so without the seam breaking either link
  /// would fail nothing.
  @Test("a row with remote_host becomes a remote candidate; one without does not")
  func remotenessSurvivesTheMapping() {
    let candidates = LLMModelDiscovery.ollamaCandidates(fromTagsModels: [
      ["name": "llama3.2:latest"],
      ["name": "gpt-oss:120b-cloud", "remote_host": "ollama.com"],
    ])

    #expect(candidates.count == 2)
    #expect(candidates.first(where: { $0.id == "llama3.2:latest" })?.isRemote == false)
    #expect(candidates.first(where: { $0.id == "gpt-oss:120b-cloud" })?.isRemote == true)
  }

  /// Identity is the EXACT name, not the canonical one. The picker tags rows by
  /// this value and the runtime arms it, so dropping the `:latest` here would
  /// arm a name the daemon may not answer to.
  @Test("candidate id is the exact tag name, and the label is the inferred display name")
  func candidateCarriesExactNameAndInferredLabel() {
    let candidates = LLMModelDiscovery.ollamaCandidates(fromTagsModels: [
      ["name": "deepseek-r1:8b"]
    ])

    #expect(candidates.map(\.id) == ["deepseek-r1:8b"])
    #expect(
      candidates.map(\.displayName)
        == [OllamaSetupService.inferDisplayName(from: "deepseek-r1:8b")],
      "labels must match the shared parser, which is what kept them unchanged")
  }

  /// The SECOND link, and the one a parser-only control cannot reach: the
  /// candidate's fact has to survive into the `LLMModelInfo` that
  /// `applyDiscoveredModels` filters on. If it does not, a hosted model reads
  /// as local and becomes eligible for exactly the auto-arming this epic
  /// removes.
  @Test("candidate remoteness reaches the final model row")
  func candidateRemotenessReachesModelInfo() {
    let remote = LLMModelDiscovery.DiscoveryCandidate(
      id: "remote", displayName: "Remote", isRemote: true)
    let local = LLMModelDiscovery.DiscoveryCandidate(
      id: "local", displayName: "Local", isRemote: false)

    #expect(
      LLMModelDiscovery.modelInfo(from: remote, provider: .ollama, isAvailable: true).isRemote)
    // The negative half: without it, hard-coding `true` would pass the above
    // while marking every model hosted and disabling Ollama auto-selection.
    #expect(
      !LLMModelDiscovery.modelInfo(from: local, provider: .ollama, isAvailable: true).isRemote)
  }

  /// An unreadable row is dropped rather than guessed at, and a legitimately
  /// empty list stays empty — the two shapes a malformed daemon response takes.
  @Test("a nameless row is dropped and an empty list stays empty")
  func malformedRowsAreDropped() {
    #expect(LLMModelDiscovery.ollamaCandidates(fromTagsModels: []).isEmpty)
    #expect(
      LLMModelDiscovery.ollamaCandidates(fromTagsModels: [["size": 123]]).isEmpty,
      "a row with no name cannot be armed, so it must not become a candidate")
  }
}
