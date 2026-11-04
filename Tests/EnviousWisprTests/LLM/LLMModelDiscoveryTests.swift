import EnviousWisprCore
import Foundation
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
  /// picker actually renders (`Text(model.displayName)` in
  /// `ProviderSetup.swift`; cited by SYMBOL because the line number this
  /// used to carry was already pointing at unrelated code, #2602) — a
  /// `DiscoveryCandidate`-only
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
      LLMModelDiscovery.modelInfo(from: $0, provider: .ollama, availability: .available, observedAt: nil)
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
      LLMModelDiscovery.modelInfo(from: remote, provider: .ollama, availability: .available, observedAt: nil).isRemote)
    // The negative half: without it, hard-coding `true` would pass the above
    // while marking every model hosted and disabling Ollama auto-selection.
    #expect(
      LLMModelDiscovery.modelInfo(from: local, provider: .ollama, availability: .available, observedAt: nil).isRemote
        == false)
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

/// #2884: `filterModels` is the shared exclusion gate every cloud catalog passes
/// after its provider-specific fetch filter. Production 400s on Gemini were every time
/// `gemini-3.5-transcribe`, an audio-input id that advertises `generateContent`
/// and so passed `fetchGeminiModels`. When this fails, the user sees a model in
/// the picker that rejects every polish.
@Suite("Cloud model-discovery exclusion (#2884)", .tags(.productOutcome))
struct LLMModelDiscoveryExclusionTests {

  private func survivingIDs(_ ids: [String]) -> [String] {
    // A fixed display name, never the id: the filter reads the id, and a fixture
    // whose two fields agree cannot tell which one production consulted.
    LLMModelDiscovery().filterModels(
      ids.map { .init(id: $0, displayName: "Text model", isRemote: false) }
    ).map(\.id)
  }

  @Test(
    "audio-input ids never reach the picker",
    arguments: [
      "gemini-3.5-transcribe",
      "gemini-2.5-flash-native-audio-preview",
      "gemini-3.5-flash-preview-tts",
    ])
  func audioInputIDsAreExcluded(id: String) {
    #expect(survivingIDs([id]).isEmpty)
  }

  @Test(
    "text polish ids survive the same filter",
    arguments: ["gemini-3.7-flash", "gemini-3.7-pro", "gemini-2.5-flash"])
  func textModelsSurvive(id: String) {
    #expect(survivingIDs([id]) == [id])
  }

  @Test("one catalog: the transcribe id is dropped and the flash id kept, in order")
  func mixedCatalogKeepsOnlyTextModels() {
    #expect(
      survivingIDs(["gemini-3.7-flash", "gemini-3.5-transcribe", "gemini-3.7-pro"])
        == ["gemini-3.7-flash", "gemini-3.7-pro"])
  }
}

/// #4353 D5: a provider's release date survives from its own list format to the final row and
/// through the cache; a missing or unusable date keeps the row, undated.
@Suite("Cloud model release dates (#4353)", .tags(.productOutcome))
struct LLMModelReleaseDateTests {
  private static func row(_ candidate: LLMModelDiscovery.DiscoveryCandidate, _ provider: LLMProvider)
    -> LLMModelInfo
  {
    LLMModelDiscovery.modelInfo(
      from: candidate, provider: provider, availability: .available, observedAt: .now)
  }

  @Test("OpenAI's created (Unix seconds) reaches the final row; a missing one keeps the row undated")
  func openAIDate() throws {
    let candidates = LLMModelDiscovery.openAICandidates(fromModels: [
      ["id": "gpt-4.1-mini", "created": 1_744_316_542, "object": "model"],
      ["id": "gpt-5-mini", "object": "model"],
      ["id": "gpt-4o-mini", "created": "yesterday", "object": "model"],
      ["id": "gpt-4.1-nano", "created": true, "object": "model"],
      ["id": "gpt-5-nano", "created": Double.infinity, "object": "model"],
      ["id": "gpt-4.1", "created": 0, "object": "model"],
    ])
    let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
    let dated = try #require(byID["gpt-4.1-mini"])
    #expect(Self.row(dated, .openAI).releaseDate == Date(timeIntervalSince1970: 1_744_316_542))
    #expect(try #require(byID["gpt-5-mini"]).releaseDate == nil)
    #expect(try #require(byID["gpt-4o-mini"]).releaseDate == nil, "an unusable date keeps the row")
    #expect(try #require(byID["gpt-4.1-nano"]).releaseDate == nil, "a JSON boolean is no date")
    #expect(try #require(byID["gpt-5-nano"]).releaseDate == nil, "a non-finite number is no date")
    #expect(try #require(byID["gpt-4.1"]).releaseDate == nil, "the epoch is no date")
  }

  @Test("Anthropic's created_at (RFC 3339) reaches the final row; the epoch marker is no date")
  func claudeDate() throws {
    // Two parsed pages concatenated as `fetchClaudeModels` appends them (the parser, not the
    // HTTP pagination loop, which `LLMModelDiscoveryTests` covers through its pure decision).
    let page1 = LLMModelDiscovery.claudeCandidates(fromModels: [
      ["id": "claude-haiku-4-5-20251001", "display_name": "Claude Haiku 4.5",
       "created_at": "2025-10-01T00:00:00Z"],
    ])
    let page2 = LLMModelDiscovery.claudeCandidates(fromModels: [
      ["id": "claude-opus-4-8", "display_name": "Claude Opus 4.8",
       "created_at": "2026-06-12T09:30:00.250Z"],
      ["id": "claude-old", "display_name": "Old", "created_at": "not a date"],
      ["id": "claude-undated", "display_name": "Undated"],
      ["id": "claude-unknown", "display_name": "Unknown", "created_at": "1970-01-01T00:00:00Z"],
    ])
    let rows = (page1 + page2).map { Self.row($0, .claude) }
    #expect(
      rows.map(\.id) == [
        "claude-haiku-4-5-20251001", "claude-opus-4-8", "claude-old", "claude-undated",
        "claude-unknown",
      ])
    #expect(rows[4].releaseDate == nil, "Anthropic's unknown-date epoch keeps the row, undated")
    #expect(rows[0].releaseDate == Date(timeIntervalSince1970: 1_759_276_800))
    #expect(rows[1].releaseDate == Date(timeIntervalSince1970: 1_781_256_600.25))
    #expect(rows[2].releaseDate == nil)
    #expect(rows[3].releaseDate == nil)
  }

  @Test("Gemini rows stay undated")
  func geminiUndated() {
    let rows = LLMModelDiscovery.geminiCandidates(fromModels: [
      ["name": "models/gemini-3.7-flash", "displayName": "Gemini 3.7 Flash",
       "supportedGenerationMethods": ["generateContent"], "createTime": "2026-01-01T00:00:00Z"],
    ]).map { Self.row($0, .gemini) }
    #expect(rows.map(\.id) == ["gemini-3.7-flash"])
    #expect(rows.allSatisfy { $0.releaseDate == nil })
  }

  @Test("the filter keeps a surviving row's date")
  func filterKeepsDate() {
    let date = Date(timeIntervalSince1970: 1_744_316_542)
    let kept = LLMModelDiscovery().filterModels([
      .init(id: "gpt-4.1-mini", displayName: "G", isRemote: false, releaseDate: date),
      .init(id: "gpt-4o-audio-preview", displayName: "A", isRemote: false, releaseDate: date),
    ])
    #expect(kept.map(\.id) == ["gpt-4.1-mini"])
    #expect(kept.first?.releaseDate == date)
  }
}
