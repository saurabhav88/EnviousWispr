import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprLLM

/// #4353 D6: the cloud model list contract. The Swift parser and the publication validator
/// (`scripts/cloud-models/validate-list.py`) must give the same answer on every shared fixture,
/// and the seed must reproduce today's compiled per-model behavior row for row, so the later
/// cutover changes nothing for anyone.
@Suite("Cloud model list (#4353)", .tags(.productOutcome))
struct CloudModelListTests {
  private static let fixtures = RepoRoot.sourceURL("scripts/cloud-models/fixtures")
  private static let websiteSeed = RepoRoot.sourceURL("website/public/cloud-models.json")
  private static let bundledSeed = RepoRoot.sourceURL(
    "Sources/EnviousWispr/Resources/cloud-models.json")

  private static func files(_ kind: String) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
      at: fixtures.appending(path: kind), includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  private static func seed() throws -> CloudModelList {
    try CloudModelList.validated(from: Data(contentsOf: websiteSeed)).get()
  }

  // MARK: - The shared contract

  @Test("every shared valid fixture is accepted, every invalid one refused")
  func sharedFixtures() throws {
    let valid = try Self.files("valid")
    let invalid = try Self.files("invalid")
    #expect(valid.count >= 5 && invalid.count >= 50, "fixtures missing")
    for url in valid {
      let result = CloudModelList.validated(from: try Data(contentsOf: url))
      if case .failure(let error) = result {
        Issue.record("\(url.lastPathComponent) should pass, refused: \(error)")
      }
    }
    for url in invalid {
      if case .success = CloudModelList.validated(from: try Data(contentsOf: url)) {
        Issue.record("\(url.lastPathComponent) should be refused, passed")
      }
    }
  }

  @Test("document size and row count limits")
  func bounds() {
    var oversized = Data(#"{"schema":1,"updated":"2026-11-04","models":[]}"#.utf8)
    oversized.append(Data(repeating: 0x20, count: CloudModelList.maxDocumentBytes))
    #expect((try? CloudModelList.validated(from: oversized).get()) == nil)
    func rows(_ count: Int) -> Data {
      let row = { (n: Int) in
        #"{"provider":"claude","id":"claude-row-\#(n)","recommended":false,"hidden":false,"request":{"claudeShape":"thinkingDisabled"},"supportsChatCompletions":false,"allowsFileBatch":true}"#
      }
      let body = (0..<count).map(row).joined(separator: ",")
      return Data(#"{"schema":1,"updated":"2026-11-04","models":[\#(body)]}"#.utf8)
    }
    #expect(
      (try? CloudModelList.validated(from: rows(CloudModelList.maxRows)).get())?.models.count
        == CloudModelList.maxRows)
    #expect((try? CloudModelList.validated(from: rows(CloudModelList.maxRows + 1)).get()) == nil)
  }

  @Test("omit and none are different requests; a listed row never falls back")
  func explicitSemantics() throws {
    let data = Data(
      #"{"schema":1,"updated":"2026-11-04","models":[{"provider":"openAI","id":"gpt-a","recommended":false,"hidden":false,"request":{"openAIEffort":"none","temperature":"omit"},"supportsChatCompletions":true,"allowsFileBatch":false},{"provider":"openAI","id":"gpt-b","recommended":true,"hidden":true,"request":{"openAIEffort":"omit","temperature":"include"},"supportsChatCompletions":false,"allowsFileBatch":true},{"provider":"gemini","id":"gemini-a","recommended":false,"hidden":false,"request":{"geminiThinking":"none"},"supportsChatCompletions":false,"allowsFileBatch":true}]}"#
        .utf8)
    let list = try CloudModelList.validated(from: data).get()
    #expect(list.models[0].request == .openAI(effort: .none, temperature: .omit))
    #expect(list.models[1].request == .openAI(effort: .omit, temperature: .include))
    #expect(list.models[2].request == .gemini(thinking: .none))
    #expect(list.models[0].allowsFileBatch == false, "a listed false stays false")
    #expect(list.models[1].hidden && list.models[1].recommended, "hidden rows stay recognized")
  }

  @Test("revision is the updated date plus the SHA-256 of the exact bytes")
  func revision() throws {
    let compact = Data(#"{"schema":1,"updated":"2026-11-04","models":[]}"#.utf8)
    let spaced = Data(#"{"schema": 1, "updated": "2026-11-04", "models": []}"#.utf8)
    let a = try CloudModelList.validated(from: compact).get()
    let b = try CloudModelList.validated(from: spaced).get()
    #expect(a.revision.hasPrefix("2026-11-04-"))
    #expect(a.revision.count == "2026-11-04-".count + 64)
    #expect(a.revision != b.revision, "formatting changes the revision, as accepted")
    #expect(a.documentBytes == compact)
  }

  // MARK: - The seed

  @Test("both seed copies are byte-identical and valid")
  func seedCopies() throws {
    let website = try Data(contentsOf: Self.websiteSeed)
    let bundled = try Data(contentsOf: Self.bundledSeed)
    #expect(website == bundled)
    let list = try Self.seed()
    // The weekly routine adds rows (#4353 PR 5), so only the original 66 seed rows are pinned.
    let original = list.models.filter { Self.deletedTelemetryAllowlist.contains($0.id) }
    #expect(original.count == 66)
    #expect(
      Dictionary(grouping: original, by: \.provider).mapValues(\.count)
        == [.openAI: 34, .gemini: 18, .claude: 14])
    #expect(
      original.allSatisfy { $0.released == nil && $0.medianPolishMs == nil },
      "the seed invents no dates and no measurements")
    #expect(list.models.allSatisfy { !$0.hidden }, "hiding stays with the compiled kind filters")
  }

  /// The oracle is a frozen dump of the compiled tables at `58d4f15d`, taken before #4353 D6
  /// deleted them (`Tests/EnviousWisprTests/Resources/cloud-policy-baseline-58d4f15d.tsv`:
  /// provider, id, thinking, temperature, chat, Claude shape). It covers every seed id, its
  /// dashed and compact dated copies, and unlisted probes, so the list-driven resolver is
  /// checked against the old code's own answers, never against the list itself.
  private static func baseline() throws -> [(LLMProvider, String, String)] {
    let text = try String(
      contentsOf: RepoRoot.sourceURL(
        "Tests/EnviousWisprTests/Resources/cloud-policy-baseline-58d4f15d.tsv"), encoding: .utf8)
    return try text.split(separator: "\n").map { line in
      let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      let provider = try #require(LLMProvider(rawValue: fields[0]))
      return (provider, fields[1], fields.dropFirst(2).joined(separator: "\t"))
    }
  }

  private static func render(_ c: LLMModelCapabilities) -> String {
    let thinking =
      switch c.thinkingControl {
      case .unsupported: "unsupported"
      case .budget(let n): "budget:\(n)"
      case .level(let l): "level:\(l)"
      case .effort(let e): "effort:\(e)"
      }
    let shape =
      switch c.claudeRequestShape {
      case .thinkingDisabled: "thinkingDisabled"
      case .thinkingBetweenTools: "thinkingBetweenTools"
      case .effortLow: "effortLow"
      }
    return [thinking, c.temperaturePolicy == .include ? "include" : "omit",
      String(c.supportsChatCompletions), shape].joined(separator: "\t")
  }

  @Test("the list-driven resolver reproduces the deleted compiled tables, with three accepted changes")
  func resolverMatchesFrozenBaseline() throws {
    let seed = try Self.seed()
    let rows = try Self.baseline()
    #expect(rows.count == 211)
    let byID = Dictionary(uniqueKeysWithValues: rows.map { ("\($0.0.rawValue)/\($0.1)", $0.2) })
    var accepted: [String] = []
    for (provider, id, old) in rows {
      let new = Self.render(provider.modelCapabilities(model: id, list: seed))
      // A dated copy of a listed id now inherits its base row (plan D6 decision 5); where the
      // old tables treated the copy differently from its base, that is an accepted change.
      if let base = ProviderModelID.withoutDateSnapshot(id),
        provider.listedRow(model: base, list: seed) != nil,
        let baseOld = byID["\(provider.rawValue)/\(base)"], baseOld != old
      {
        #expect(new == baseOld, "\(provider.rawValue)/\(id) should inherit \(base)")
        accepted.append("\(provider.rawValue)/\(id)")
        continue
      }
      #expect(new == old, "\(provider.rawValue)/\(id): baseline \(old), now \(new)")
    }
    // The three accepted classes, and only them: compact-dated OpenAI copies of `none` rows
    // (the old effort lookup stripped dashed dates only), dated Claude copies of shaped rows
    // and dated Gemini copies of rows with a thinking value (both were exact-match only).
    let openAINone = seed.models.filter { $0.request == .openAI(effort: .none, temperature: .omit) }
    let claudeShaped = seed.models.filter {
      if case .claude(let shape) = $0.request { return shape != .thinkingDisabled }
      return false
    }
    let geminiThinking = seed.models.filter {
      if case .gemini(let thinking) = $0.request { return thinking != .none }
      return false
    }
    let expected = Set(
      openAINone.map { "openAI/\($0.id)-20260423" }
        + claudeShaped.flatMap { ["claude/\($0.id)-2026-04-23", "claude/\($0.id)-20260423"] }
        + geminiThinking.flatMap { ["gemini/\($0.id)-2026-04-23", "gemini/\($0.id)-20260423"] })
    #expect(Set(accepted) == expected)
    #expect(accepted.count == 9 + 4 * 2 + 13 * 2)
  }

  @Test("with no list every id takes the compiled fallback, never a listed value")
  func noListMeansUnlisted() {
    #expect(
      LLMProvider.openAI.modelCapabilities(model: "gpt-5.5", list: nil).thinkingControl
        == .effort("low"), "the old exact `none` lives only in the list")
    #expect(
      LLMProvider.gemini.modelCapabilities(model: "gemini-3.6-flash", list: nil).thinkingControl
        == .unsupported)
    #expect(
      LLMProvider.claude.modelCapabilities(model: "claude-sonnet-5-5", list: nil)
        .claudeRequestShape == .thinkingDisabled)
    #expect(LLMProvider.openAI.allowsFileBatch(model: "gpt-4o-mini-2024-07-18", list: nil) == false)
    #expect(LLMProvider.claude.allowsFileBatch(model: "claude-haiku-4-5-latest", list: nil) == false)
    #expect(LLMProvider.openAI.allowsFileBatch(model: "gpt-4o", list: nil))
  }

  @Test("a listed row decides every field, including false and no thinking, over the heuristics")
  func listedRowOverridesHeuristics() throws {
    // Each row says the opposite of what the compiled fallback would say for its id.
    let list = try CloudModelList.validated(
      from: Data(
        #"{"schema":1,"updated":"2026-11-04","models":[{"provider":"openAI","id":"gpt-6-new","recommended":false,"hidden":false,"request":{"openAIEffort":"omit","temperature":"include"},"supportsChatCompletions":false,"allowsFileBatch":false},{"provider":"openAI","id":"gpt-4o-mini","recommended":false,"hidden":false,"request":{"openAIEffort":"minimal","temperature":"omit"},"supportsChatCompletions":true,"allowsFileBatch":true},{"provider":"gemini","id":"gemini-9-flash","recommended":false,"hidden":false,"request":{"geminiThinking":{"budget":0}},"supportsChatCompletions":false,"allowsFileBatch":false},{"provider":"claude","id":"claude-new","recommended":false,"hidden":false,"request":{"claudeShape":"effortLow"},"supportsChatCompletions":false,"allowsFileBatch":true},{"provider":"claude","id":"claude-new-20260101","recommended":false,"hidden":false,"request":{"claudeShape":"thinkingBetweenTools"},"supportsChatCompletions":false,"allowsFileBatch":false}]}"#
          .utf8)
    ).get()
    let gpt6 = LLMProvider.openAI.modelCapabilities(model: "gpt-6-new", list: list)
    #expect(gpt6.thinkingControl == .unsupported, "listed omit beats the gpt-6 family rule")
    #expect(gpt6.temperaturePolicy == .include)
    #expect(gpt6.supportsChatCompletions == false, "a listed false never becomes the heuristic true")
    #expect(LLMProvider.openAI.allowsFileBatch(model: "gpt-6-new", list: list) == false)
    let mini = LLMProvider.openAI.modelCapabilities(model: "gpt-4o-mini-2024-07-18", list: list)
    #expect(mini.thinkingControl == .effort("minimal"), "a dated id inherits its listed base")
    #expect(LLMProvider.openAI.allowsFileBatch(model: "gpt-4o-mini-2024-07-18", list: list))
    #expect(
      LLMProvider.gemini.modelCapabilities(model: "gemini-9-flash", list: list).thinkingControl
        == .budget(0))
    #expect(LLMProvider.gemini.allowsFileBatch(model: "gemini-9-flash", list: list) == false)
    #expect(
      LLMProvider.claude.modelCapabilities(model: "claude-new-20260101", list: list)
        .claudeRequestShape == .thinkingBetweenTools, "an exact dated row beats its base")
    #expect(LLMProvider.claude.allowsFileBatch(model: "claude-new-20260101", list: list) == false)
    #expect(
      LLMProvider.claude.modelCapabilities(model: "claude-new-2026-02-02", list: list)
        .claudeRequestShape == .effortLow)
    #expect(
      LLMProvider.openAI.modelCapabilities(model: "claude-new", list: list).thinkingControl
        == .unsupported, "a row for another provider never applies")
  }

  /// Frozen copies of the compiled sets #4353 D6 deleted, taken from `9ad123ad`: the telemetry
  /// allowlist (`SettingsProjection.geminiModelIDs` plus `cloudModelAllowlist`) and the named
  /// fast tier (`AIPolishModelClassifier.namedFastTierIDs`). They are the oracle the list must
  /// reproduce, so the list is never checked against itself.
  private static let deletedTelemetryAllowlist: [String] = [
    "chatgpt-4o-latest", "claude-fable-5", "claude-fable-5-1", "claude-haiku-4-5",
    "claude-opus-4-1", "claude-opus-4-5", "claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8",
    "claude-opus-5", "claude-opus-5-5", "claude-sonnet-4-5", "claude-sonnet-4-6", "claude-sonnet-5",
    "claude-sonnet-5-5", "gemini-1.5-flash", "gemini-1.5-flash-8b", "gemini-1.5-pro",
    "gemini-2.0-flash", "gemini-2.0-flash-lite", "gemini-2.5-flash", "gemini-2.5-flash-lite",
    "gemini-2.5-pro", "gemini-3-flash-preview", "gemini-3.1-flash-lite",
    "gemini-3.1-flash-lite-preview", "gemini-3.1-pro-preview", "gemini-3.1-pro-preview-customtools",
    "gemini-3.5-flash", "gemini-3.5-flash-lite", "gemini-3.6-flash", "gemini-3.7-flash",
    "gemini-3.8-flash", "gpt-4", "gpt-4-turbo", "gpt-4.1", "gpt-4.1-mini", "gpt-4.1-nano", "gpt-4o",
    "gpt-4o-mini", "gpt-5", "gpt-5-mini", "gpt-5-nano", "gpt-5-pro", "gpt-5.1", "gpt-5.2",
    "gpt-5.2-pro", "gpt-5.4", "gpt-5.4-mini", "gpt-5.4-nano", "gpt-5.4-pro", "gpt-5.5",
    "gpt-5.5-pro", "gpt-5.6-luna", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-6-astra", "gpt-6-luna",
    "gpt-6-sol", "gpt-6.1-sol", "o1", "o1-mini", "o1-preview", "o3", "o3-mini", "o4-mini",
  ]
  private static let deletedNamedFastTier: Set<String> = ["gpt-5.6-luna"]

  private static func provider(of id: String) -> LLMProvider {
    id.hasPrefix("gemini") ? .gemini : id.hasPrefix("claude") ? .claude : .openAI
  }

  @Test("the seed reproduces the deleted telemetry allowlist and recommendation rule")
  @MainActor
  func seedMatchesDeletedPresentationSets() throws {
    let seed = try Self.seed()
    // Rows the weekly routine added (#4353 PR 5) are not part of the deleted sets.
    let rows = seed.models.filter { Self.deletedTelemetryAllowlist.contains($0.id) }
    // #2905: GPT-4o mini and Haiku 4.5 keep ordinary requests.
    let ordinaryOnly = Set(rows.filter { !$0.allowsFileBatch }.map(\.id))
    #expect(ordinaryOnly == ["gpt-4o-mini", "claude-haiku-4-5"])
    // Every id the deleted allowlist recognised is still recognised, for its own provider, and
    // each one is still a row in the list.
    #expect(Self.deletedTelemetryAllowlist.count == 66)
    for id in Self.deletedTelemetryAllowlist {
      #expect(
        SettingsProjection.model(provider: Self.provider(of: id), id: id, list: seed) == id,
        "\(id) is recognised by telemetry")
    }
    #expect(Set(rows.map(\.id)) == Set(Self.deletedTelemetryAllowlist))
    // The deleted recommendation rule: tier words and disqualifiers, plus the named fast tier.
    for row in rows {
      let old =
        AIPolishModelClassifier.isRecommendedForCleanup(row.id)
        || Self.deletedNamedFastTier.contains(row.id)
      #expect(row.recommended == old, "\(row.id) recommended")
    }
  }
}
