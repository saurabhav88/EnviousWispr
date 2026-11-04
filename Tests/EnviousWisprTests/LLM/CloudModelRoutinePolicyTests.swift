import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprLLM

/// #4353 PR 5 (D7 detail, harness items 3 and 6): which new models the weekly routine tests,
/// and when a listed model missing from the provider's catalog is proposed for hiding. Every
/// expectation is a literal; time is injected.
@Suite("Cloud model routine policy (#4353 PR 5)", .tags(.harnessContract))
struct CloudModelRoutinePolicyTests {

  typealias Policy = CloudModelRoutinePolicy

  // MARK: - Fixtures

  /// A minimal valid list. Rows are `(provider, id, hidden)`.
  static func list(_ rows: [(String, String, Bool)]) throws -> CloudModelList {
    let models = rows.map { provider, id, hidden -> String in
      let request: String
      switch provider {
      case "openAI": request = #"{"openAIEffort":"omit","temperature":"include"}"#
      case "gemini": request = #"{"geminiThinking":"none"}"#
      default: request = #"{"claudeShape":"thinkingDisabled"}"#
      }
      let reason = hidden ? #","hiddenReason":"gone""# : ""
      return """
        {"provider":"\(provider)","id":"\(id)","recommended":false,"hidden":\(hidden)\(reason),\
        "request":\(request),"supportsChatCompletions":\(provider == "openAI"),"allowsFileBatch":true}
        """
    }
    let json = #"{"schema":1,"updated":"2026-11-01","models":[\#(models.joined(separator: ","))]}"#
    return try CloudModelList.validated(from: Data(json.utf8)).get()
  }

  static func date(_ day: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.date(from: day)!
  }

  /// Rows for `LLMModelDiscovery.catalog`: `created` dates for OpenAI, none otherwise.
  static func openAICatalog(_ ids: [(String, String?)], list: CloudModelList?) throws
    -> LLMModelDiscovery.CloudCatalog
  {
    let rows: [[String: Any]] = ids.map { id, day in
      var row: [String: Any] = ["id": id]
      if let day { row["created"] = date(day).timeIntervalSince1970 }
      return row
    }
    return try LLMModelDiscovery.catalog(provider: .openAI, rows: rows, list: list)
  }

  static func claudeCatalog(_ ids: [String], list: CloudModelList?) throws
    -> LLMModelDiscovery.CloudCatalog
  {
    try LLMModelDiscovery.catalog(
      provider: .claude, rows: ids.map { ["id": $0, "display_name": $0] }, list: list)
  }

  // MARK: - Candidate selection

  @Test("listed ids, their dated copies and hidden rows are never candidates")
  func listedIdsAreExcluded() throws {
    let list = try Self.list([
      ("openAI", "gpt-9", false), ("openAI", "gpt-9-old", true), ("claude", "gpt-9-new", false),
    ])
    let catalog = try Self.openAICatalog(
      [("gpt-9", nil), ("gpt-9-2026-10-01", nil), ("gpt-9-old", nil), ("gpt-9-new", nil)],
      list: list)
    let selection = Policy.selectCandidates(catalog: catalog, list: list)
    #expect(
      selection.dispositions == [
        "gpt-9": .listed, "gpt-9-2026-10-01": .listed, "gpt-9-old": .listed,
        "gpt-9-new": .selected,
      ])
    // A Claude row with the same id does not decide an OpenAI model.
    #expect(selection.selected.map(\.id) == ["gpt-9-new"])
  }

  @Test("a dated copy yields to its eligible base, including when both are new")
  func datedCopyYieldsToEligibleBase() throws {
    let list = try Self.list([])
    let catalog = try Self.claudeCatalog(
      ["claude-zeta-9", "claude-zeta-9-20261001", "claude-solo-9-20261002"], list: list)
    let selection = Policy.selectCandidates(catalog: catalog, list: list)
    #expect(
      selection.dispositions == [
        "claude-zeta-9": .selected, "claude-zeta-9-20261001": .suppressedDatedCopy,
        "claude-solo-9-20261002": .selected,
      ])
  }

  @Test("an ineligible base does not suppress an eligible dated copy")
  func ineligibleBaseDoesNotSuppress() throws {
    let list = try Self.list([])
    // `gpt-9-001` is a versioned duplicate (excluded); its dated copy does not end in `-001`.
    let catalog = try Self.openAICatalog(
      [("gpt-9-001", nil), ("gpt-9-001-2026-10-01", nil), ("gpt-10", nil),
       ("gpt-10-2026-10-01", nil)],
      list: list)
    #expect(catalog.eligible.map(\.id).contains("gpt-9-001") == false)
    let selection = Policy.selectCandidates(catalog: catalog, list: list)
    #expect(
      selection.dispositions == [
        "gpt-9-001-2026-10-01": .selected, "gpt-10": .selected,
        "gpt-10-2026-10-01": .suppressedDatedCopy,
      ])
  }

  @Test("a dated-only id is kept; a four-digit suffix is not treated as a date")
  func datedOnlyAndVersionSuffix() throws {
    let list = try Self.list([("openAI", "gpt-9-mini", false)])
    let catalog = try Self.openAICatalog(
      [("gpt-11-2026-10-03", nil), ("gpt-9-mini-0125", nil)], list: list)
    let selection = Policy.selectCandidates(catalog: catalog, list: list)
    #expect(
      selection.dispositions == [
        "gpt-11-2026-10-03": .selected, "gpt-9-mini-0125": .selected,
      ])
  }

  @Test("provider-dated candidates come newest first, then undated, ties by id descending")
  func testOrder() throws {
    let list = try Self.list([])
    let catalog = try Self.openAICatalog(
      [
        ("gpt-a", nil), ("gpt-b", "2026-09-01"), ("gpt-c", "2026-10-01"), ("gpt-d", "2026-10-01"),
        ("gpt-e", nil),
      ],
      list: list)
    let selection = Policy.selectCandidates(catalog: catalog, list: list)
    #expect(selection.selected.map(\.id) == ["gpt-d", "gpt-c", "gpt-b", "gpt-e", "gpt-a"])
  }

  @Test("at most five per provider; the rest are over the limit", arguments: [4, 5, 6, 9])
  func fivePerProvider(_ count: Int) throws {
    let list = try Self.list([])
    let ids = (1...count).map { (String(format: "gpt-n%02d", $0), String?.none) }
    let selection = Policy.selectCandidates(
      catalog: try Self.openAICatalog(ids, list: list), list: list)
    #expect(selection.selected.count == min(count, 5))
    #expect(selection.dispositions.values.filter { $0 == .overLimit }.count == max(0, count - 5))
    if count == 6 {
      #expect(
        selection.selected.map(\.id) == ["gpt-n06", "gpt-n05", "gpt-n04", "gpt-n03", "gpt-n02"])
      #expect(selection.dispositions["gpt-n01"] == .overLimit)
    }
  }

  @Test("each provider is limited on its own")
  func providerIsolation() throws {
    let list = try Self.list([])
    let openAI = try Self.openAICatalog((1...6).map { ("gpt-n\($0)", nil) }, list: list)
    let claude = try Self.claudeCatalog((1...3).map { "claude-n\($0)" }, list: list)
    #expect(Policy.selectCandidates(catalog: openAI, list: list).selected.count == 5)
    #expect(Policy.selectCandidates(catalog: claude, list: list).selected.count == 3)
  }
}
