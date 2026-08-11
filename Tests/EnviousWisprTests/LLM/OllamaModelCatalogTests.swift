import Foundation
import Testing

@testable import EnviousWisprLLM

@Suite("OllamaModelCatalog")
struct OllamaModelCatalogTests {

  // MARK: - Parameter Size Parsing

  @Test("parses standard billion values")
  func parsesBillions() {
    #expect(OllamaSetupService.parseParameterSize("3B") == 3.0)
    #expect(OllamaSetupService.parseParameterSize("7B") == 7.0)
    #expect(OllamaSetupService.parseParameterSize("70B") == 70.0)
  }

  @Test("parses fractional billion values")
  func parsesFractionalBillions() {
    #expect(OllamaSetupService.parseParameterSize("3.2B") == 3.2)
    #expect(OllamaSetupService.parseParameterSize("1.1B") == 1.1)
    #expect(OllamaSetupService.parseParameterSize("3.8B") == 3.8)
  }

  @Test("parses million values as fractional billions")
  func parsesMillions() {
    let result = OllamaSetupService.parseParameterSize("500M")
    #expect(result != nil)
    #expect(abs(result! - 0.5) < 0.001)

    let result2 = OllamaSetupService.parseParameterSize("125M")
    #expect(result2 != nil)
    #expect(abs(result2! - 0.125) < 0.001)
  }

  @Test("parses trillion values")
  func parsesTrillion() {
    #expect(OllamaSetupService.parseParameterSize("1T") == 1000.0)
    #expect(OllamaSetupService.parseParameterSize("1.5T") == 1500.0)
  }

  @Test("returns nil for invalid input")
  func parsesInvalid() {
    #expect(OllamaSetupService.parseParameterSize("") == nil)
    #expect(OllamaSetupService.parseParameterSize("abc") == nil)
    #expect(OllamaSetupService.parseParameterSize("B") == nil)
    #expect(OllamaSetupService.parseParameterSize("3X") == nil)
  }

  @Test("handles case insensitivity")
  func parsesCaseInsensitive() {
    #expect(OllamaSetupService.parseParameterSize("3b") == 3.0)
    #expect(OllamaSetupService.parseParameterSize("500m") == 0.5)
  }

  // MARK: - EG-1 curated-private catalog visibility (#1269)

  /// #1914: `facts` is required with no default, so every fixture states what
  /// the daemon reported. Defaults to a plain local model; the remote-grouping
  /// tests pass their own.
  private func downloaded(
    _ name: String, sizeGB: Double = 2.9,
    facts: OllamaModelFacts = OllamaModelFacts(isRemote: false, thinks: false)
  ) -> OllamaDownloadedModel {
    OllamaDownloadedModel(
      exactName: name,
      canonicalName: OllamaSetupService.canonicalModelName(name),
      parameterSize: "4B",
      parameterBillions: 4.0,
      fileSizeBytes: Int64(sizeGB * 1_000_000_000),
      displayName: name,
      facts: facts
    )
  }

  @Test("eg-1 never appears as an undownloaded suggestion (no dead Download row)")
  func egOneAbsentWhenNotDownloaded() {
    let catalog = OllamaSetupService.dynamicCatalog(from: [])
    #expect(!catalog.contains { OllamaSetupService.canonicalModelName($0.name) == "eg-1" })
    // The public catalog rows are all still offered.
    #expect(catalog.count == OllamaSetupService.modelCatalog.count)
  }

  @Test("downloaded eg-1 gets the curated first-party overlay")
  func egOneCuratedOverlayWhenDownloaded() throws {
    let catalog = OllamaSetupService.dynamicCatalog(from: [downloaded("eg-1:latest")])
    let row = try #require(
      catalog.first { OllamaSetupService.canonicalModelName($0.name) == "eg-1" })
    #expect(row.displayName == "EG-1")
    // #1950: EG-1 is `.firstParty`, not a measured verdict. It has its own acceptance evidence on a
    // different corpus, so ranking it in this vocabulary would be reading two rulers as one, and
    // calling it "Not tested by us" would be false.
    //
    // Asserted against `row.name`, the id the UI will actually hand the authority, not a hard-coded
    // string. A hard-coded id would keep passing if the row's name changed shape.
    #expect(OllamaModelVerdicts.verdict(for: row.name) == .firstParty)
    #expect(OllamaModelVerdicts.entry(for: row.name).note.isEmpty)
    #expect(row.isDownloaded == true)
  }

  @Test("curated-private entries do not leak into suggestions when other models are downloaded")
  func privateCatalogNeverSuggested() {
    let catalog = OllamaSetupService.dynamicCatalog(from: [downloaded("llama3.2:latest")])
    let undownloaded = catalog.filter { !$0.isDownloaded }
    #expect(!undownloaded.contains { OllamaSetupService.canonicalModelName($0.name) == "eg-1" })
  }

  @Test("isFirstPartyModel matches ONLY eg-1 and its tags (cloud review r3)")
  func firstPartyDefinition() {
    #expect(OllamaSetupService.isFirstPartyModel("eg-1"))
    #expect(OllamaSetupService.isFirstPartyModel("eg-1:latest"))
    #expect(OllamaSetupService.isFirstPartyModel("eg-1:q4"))
    #expect(OllamaSetupService.isFirstPartyModel("EG-1"))
    // User-controlled lookalikes are NOT ours: different model, normal routing,
    // custom telemetry (reviewer examples eg-10 / eg-1-acme-client).
    #expect(!OllamaSetupService.isFirstPartyModel("eg-10"))
    #expect(!OllamaSetupService.isFirstPartyModel("eg-1-q4"))
    #expect(!OllamaSetupService.isFirstPartyModel("eg-1-acme-client"))
    #expect(!OllamaSetupService.isFirstPartyModel("gemma-eg-1"))
    #expect(!OllamaSetupService.isFirstPartyModel("lego-eg-1"))
    #expect(!OllamaSetupService.isFirstPartyModel("llama3.2"))
  }

  @Test("unknown custom model still gets inferred metadata (unchanged behavior)")
  func unknownModelInferred() throws {
    let catalog = OllamaSetupService.dynamicCatalog(from: [downloaded("someones-finetune:7b")])
    let row = try #require(catalog.first { $0.name == "someones-finetune:7b" })

    #expect(row.displayName == "Someones Finetune")
    #expect(row.parameterCount == "4B")
    #expect(row.downloadSize == "2.7 GB")
    #expect(row.isDownloaded == true)
    // #1950: metadata is still inferred, but a VERDICT is not. This row used to come back `.medium`
    // from a parameter count alone; a model we have never run a case through says so.
    #expect(OllamaModelVerdicts.verdict(for: "someones-finetune:7b") == .notTested)
    #expect(OllamaModelVerdicts.entry(for: "someones-finetune:7b").note.isEmpty)
  }

  // MARK: - Suggestion ordering (#1950)

  @Test("models with no acceptable output are offered last, in their original relative order")
  func noAcceptableOutputModelsSortLast() throws {
    let catalog = OllamaSetupService.dynamicCatalog(from: [])
    let suggested = catalog.filter { $0.isDownloaded == false }.map(\.name)

    // MUTATION CONTROL: drop the stable partition in `dynamicCatalog` and this fails, because the
    // three no-acceptable-output models sit interspersed in the curated literal at positions 3, 5
    // and 11.
    #expect(
      suggested == [
        "gemma3n:e4b", "llama3.2", "mistral", "gemma2:2b", "gemma2", "qwen2.5:3b", "qwen2.5:7b",
        "qwen3:0.6b", "llama3.2:1b", "phi3", "tinyllama",
      ])
  }

  @Test("the partition boundary is clean: every other verdict precedes not recommended")
  func partitionBoundaryIsClean() {
    let catalog = OllamaSetupService.dynamicCatalog(from: [])
    let suggested = catalog.filter { $0.isDownloaded == false }
    let lastOtherVerdict =
      suggested.lastIndex { OllamaModelVerdicts.verdict(for: $0.name) != .notRecommended } ?? -1
    let firstNotRecommended =
      suggested.firstIndex { OllamaModelVerdicts.verdict(for: $0.name) == .notRecommended }
      ?? suggested.count
    #expect(lastOtherVerdict < firstNotRecommended)
  }

  @Test("relative order is preserved inside both partitions")
  func relativeOrderPreservedInBothPartitions() {
    let catalog = OllamaSetupService.dynamicCatalog(from: [])
    let suggested = catalog.filter { $0.isDownloaded == false }.map(\.name)
    let curated = OllamaSetupService.modelCatalog.map(\.name)

    // Each partition must be a SUBSEQUENCE of the curated order, which is what distinguishes a
    // stable partition from a sort that imposed an order the measurement cannot justify.
    func isSubsequence(_ part: [String], of whole: [String]) -> Bool {
      var remaining = whole[...]
      for name in part {
        guard let hit = remaining.firstIndex(of: name) else { return false }
        remaining = remaining[(hit + 1)...]
      }
      return true
    }
    let otherVerdicts =
      suggested.filter { OllamaModelVerdicts.verdict(for: $0) != .notRecommended }
    let notRecommended =
      suggested.filter { OllamaModelVerdicts.verdict(for: $0) == .notRecommended }
    #expect(isSubsequence(otherVerdicts, of: curated))
    #expect(isSubsequence(notRecommended, of: curated))
  }

  @Test("an installed model with no acceptable output is NOT moved behind the suggestions")
  func installedModelsAreNotPartitioned() throws {
    // `phi3` has no acceptable output and `qwen2.5:3b` is recommended, but both are INSTALLED, so
    // they keep the downloaded segment's display-name order: "phi3" before "qwen2.5:3b".
    // Reordering what someone already has is a different change, and nobody asked for it.
    let catalog = OllamaSetupService.dynamicCatalog(
      from: [downloaded("phi3"), downloaded("qwen2.5:3b")])
    let installed = catalog.filter { $0.isDownloaded }.map(\.name)
    let phiIndex = try #require(installed.firstIndex(of: "phi3"))
    let qwenIndex = try #require(installed.firstIndex(of: "qwen2.5:3b"))
    #expect(phiIndex < qwenIndex)
  }

  @Test("every installed model still precedes every suggestion")
  func installedPrecedeSuggestions() {
    let catalog = OllamaSetupService.dynamicCatalog(
      from: [downloaded("phi3"), downloaded("qwen2.5:3b")])
    let lastInstalled = catalog.lastIndex { $0.isDownloaded } ?? -1
    let firstSuggested = catalog.firstIndex { $0.isDownloaded == false } ?? catalog.count
    #expect(lastInstalled < firstSuggested)
  }

  // MARK: - Canonical Name

  @Test("strips :latest suffix")
  func canonicalStripsLatest() {
    #expect(OllamaSetupService.canonicalModelName("llama3.2:latest") == "llama3.2")
  }

  @Test("preserves other tags")
  func canonicalPreservesTags() {
    #expect(OllamaSetupService.canonicalModelName("llama3.2:1b") == "llama3.2:1b")
    #expect(OllamaSetupService.canonicalModelName("qwen2.5:7b") == "qwen2.5:7b")
  }

  @Test("bare name stays unchanged")
  func canonicalBareName() {
    #expect(OllamaSetupService.canonicalModelName("mistral") == "mistral")
  }

  // MARK: - Weak Model Detection — RETIRED (#1948)

  // Nine tests of `OllamaSetupService.isWeakModel` were deleted here with the symbol. They
  // froze a hardcoded prefix list and a `:Nb` size regex that decided which Ollama models
  // got a simplified prompt — a hand-authored prediction about which models other people
  // install. Prompt selection now reads the daemon's execution-location report, and its
  // freeze test lives in `PromptPlannerTests.ollamaLocalAlwaysLocalFixed`, which asserts
  // that every one of those names routes identically. Same retirement, same reason, as the
  // thinking-detection name list directly below.

  // MARK: - Thinking detection: RETIRED name list → reported capability (#272, #1914)

  /// #1914 retired the name-matching thinking classifier and its four-family
  /// prefix list. The question it answered is now answered by the daemon, so the
  /// coverage moves with the authority rather than being deleted: these assert
  /// that the SAME seven model names the old list classified are still
  /// classified correctly, via `OllamaModelFacts` decoded from a real-shaped
  /// `/api/tags` row.
  ///
  /// Verified live 2026-08-01 that all four retired families report the
  /// `thinking` capability, `qwen3` and `deepseek-r1` as local builds.
  private func facts(name: String, capabilities: [String]) -> OllamaModelFacts {
    let body = try! JSONSerialization.data(withJSONObject: [
      "models": [["name": name, "capabilities": capabilities]]
    ])
    let response = HTTPURLResponse(
      url: URL(string: "http://localhost:11434/api/tags")!,
      statusCode: 200, httpVersion: nil, headerFields: nil)!
    guard
      case .ready(let facts) = OllamaConnector.classifyReadiness(
        data: body, response: response, model: name)
    else {
      Issue.record("fixture did not classify as ready for \(name)")
      return OllamaModelFacts(isRemote: false, thinks: false)
    }
    return facts
  }

  @Test(
    "the four retired families are still detected as thinking, now by capability",
    arguments: [
      "gemma4:latest", "gemma4:8b", "qwen3", "qwen3:7b", "deepseek-r1", "deepseek-r1:14b",
      "gpt-oss:20b",
    ])
  func retiredFamiliesReportThinking(name: String) {
    #expect(facts(name: name, capabilities: ["completion", "thinking"]).thinks == true)
  }

  @Test(
    "non-thinking models are still not flagged, now by capability",
    arguments: [
      "llama3.2", "llama3.1:8b", "mistral", "gemma2:2b", "gemma3:12b", "phi-2", "qwen2.5:7b",
    ])
  func nonThinkingModelsDoNotReportThinking(name: String) {
    // Prevents the regression the #272 test guarded: a non-thinking model
    // getting the 2048 budget and risking the 15s pipeline timeout on a rambly
    // generation.
    #expect(facts(name: name, capabilities: ["completion"]).thinks == false)
  }

  /// The behaviour change the retirement exists for. Under the old list these
  /// two would have been classified by NAME — `gemma4` always thinking,
  /// `qwen2.5` never — regardless of what the daemon reported. Now the name is
  /// irrelevant and the daemon decides, which is what fixes every thinking
  /// model that was outside the four hard-coded names.
  @Test func capabilityOverridesWhatTheNameWouldHaveImplied() {
    #expect(facts(name: "gemma4:latest", capabilities: ["completion"]).thinks == false)
    #expect(facts(name: "qwen2.5:7b", capabilities: ["completion", "thinking"]).thinks == true)
  }
}
