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

  /// #1947, hosted half: the picker's own data source, not `dynamicCatalog`'s
  /// (Manage Models' path, covered by `OllamaManageModelsPresentationTests`).
  /// `parseDownloadedModels` (`OllamaSetupService.swift:~1105`) is the shared
  /// construction site both paths draw from, and its own comment names this
  /// exact case ("left the picker listing... 'Gpt Oss' twice, which is what
  /// the founder screenshotted") — this test pins the fix at the layer #1947
  /// actually complained about AND through to `LLMModelInfo`, the row the
  /// picker actually renders (`Text(model.displayName)`,
  /// `AIPolishSettingsView.swift:977`) — a `DiscoveryCandidate`-only
  /// assertion stops one hop short of what the picker consumes. Uses the
  /// daemon's real `remote_host` shape (`"https://ollama.com"`, not a bare
  /// hostname) per whole-diff review r1.
  @Test(
    "two hosted models differing only by tag produce distinct picker labels",
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/1947",
      "Ollama model picker shows identical rows")
  )
  func hostedCandidatesDifferingOnlyByTagStayDistinct() {
    let candidates = LLMModelDiscovery.ollamaCandidates(fromTagsModels: [
      ["name": "gpt-oss:20b-cloud", "remote_host": "https://ollama.com"],
      ["name": "gpt-oss:120b-cloud", "remote_host": "https://ollama.com"],
    ])
    let models = candidates.map {
      LLMModelDiscovery.modelInfo(from: $0, provider: .ollama, isAvailable: true)
    }

    #expect(models.map(\.id) == ["gpt-oss:20b-cloud", "gpt-oss:120b-cloud"])
    #expect(models.map(\.displayName) == ["gpt-oss:20b-cloud", "gpt-oss:120b-cloud"])
  }

  /// #1947, local half: whole-diff review r1 found the fix above only covered
  /// HOSTED rows — `parseDownloadedModels` still sent local models through
  /// `inferDisplayName`, which drops everything after the colon, so two
  /// installed sizes of one LOCAL family (`llama3.2:1b` / `llama3.2:3b`)
  /// still both prettified to "Llama 3.2". #1947's own text named this: "Any
  /// two variants of one family collide. This is not specific to hosted
  /// models." Fixed by `disambiguateLocalCollisions` appending the parsed
  /// size, matching this catalog's own "(SIZE)" convention.
  @Test(
    "two local models differing only by size get a disambiguating suffix",
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/1947",
      "Ollama model picker shows identical rows")
  )
  func localCandidatesDifferingBySizeStayDistinct() {
    let candidates = LLMModelDiscovery.ollamaCandidates(fromTagsModels: [
      ["name": "llama3.2:1b", "details": ["parameter_size": "1B"]],
      ["name": "llama3.2:3b", "details": ["parameter_size": "3B"]],
    ])
    let names = candidates.map(\.displayName)
    // The base is the shared parser's own prettified form, not the CURATED
    // static-catalog string ("Llama 3.2") — that override belongs to
    // `dynamicCatalog`'s Manage Models path only, per
    // `candidateCarriesExactNameAndInferredLabel` above; the picker's own
    // path never applies it.
    let base = OllamaSetupService.inferDisplayName(from: "llama3.2")

    #expect(Set(names).count == 2, "collided: \(names)")
    #expect(names.contains("\(base) (1B)"), "\(names)")
    #expect(names.contains("\(base) (3B)"), "\(names)")
  }

  /// Second-pass fallback: two local variants can share a parsed size too
  /// (two quantizations of the same checkpoint), so the size suffix alone
  /// would still collide. The exact tag is unique by construction, so the
  /// fallback pass always resolves it.
  @Test("two local models sharing both family AND size fall back to the exact tag")
  func localCandidatesSharingSizeFallBackToExactTag() {
    let candidates = LLMModelDiscovery.ollamaCandidates(fromTagsModels: [
      ["name": "llama3.2:3b-instruct-q4_K_M", "details": ["parameter_size": "3B"]],
      ["name": "llama3.2:3b-instruct-q8_0", "details": ["parameter_size": "3B"]],
    ])
    let names = candidates.map(\.displayName)

    #expect(Set(names).count == 2, "collided: \(names)")
    #expect(names.contains("llama3.2:3b-instruct-q4_K_M"), "\(names)")
    #expect(names.contains("llama3.2:3b-instruct-q8_0"), "\(names)")
  }

  /// Two-way control: a local model with no sibling of the same family keeps
  /// its plain prettified name — the fix must not suffix everything.
  @Test("a local model with no colliding sibling keeps its plain prettified name")
  func localCandidateWithNoSiblingStaysPlain() {
    let candidates = LLMModelDiscovery.ollamaCandidates(fromTagsModels: [
      ["name": "llama3.2:1b", "details": ["parameter_size": "1B"]],
      ["name": "mistral:7b", "details": ["parameter_size": "7B"]],
    ])
    let expected = [
      OllamaSetupService.inferDisplayName(from: "llama3.2"),
      OllamaSetupService.inferDisplayName(from: "mistral"),
    ].sorted()

    #expect(candidates.map(\.displayName).sorted() == expected)
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
