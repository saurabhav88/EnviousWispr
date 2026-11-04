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

  // MARK: - Absence history

  static func listA() throws -> CloudModelList {
    try list([("claude", "claude-a", false), ("claude", "claude-b", false)])
  }

  static func observe(
    _ history: Policy.AbsenceHistory, _ ids: [String], on day: String, list: CloudModelList
  ) throws -> (Policy.AbsenceHistory, Policy.ObservationResult) {
    let catalog = try claudeCatalog(ids, list: list)
    let result = Policy.observeAbsence(
      history: history, provider: .claude, outcome: .complete(catalog), observedAt: date(day),
      list: list)
    return (result.history, result.result)
  }

  @Test("ISO week in UTC: Monday starts the week; the year boundary follows ISO rules")
  func isoWeeks() {
    #expect(Policy.isoWeek(of: Self.date("2026-11-02")) == "2026-W45")  // Monday
    #expect(Policy.isoWeek(of: Self.date("2026-11-08")) == "2026-W45")  // Sunday
    #expect(Policy.isoWeek(of: Self.date("2026-11-09")) == "2026-W46")
    #expect(Policy.isoWeek(of: Self.date("2027-01-01")) == "2026-W53")
  }

  @Test("first absence is pending; a second distinct week proposes hiding with the first date")
  func twoWeeksPropose() throws {
    let list = try Self.listA()
    let (h1, r1) = try Self.observe(.init(), ["claude-a"], on: "2026-11-02", list: list)
    #expect(
      r1
        == .observed([
          "claude-a": .present,
          "claude-b": .missingForRoutineKey(firstMissingDay: "2026-11-02", weeks: 1),
        ]))
    let (_, r2) = try Self.observe(h1, ["claude-a"], on: "2026-11-09", list: list)
    #expect(
      r2
        == .observed([
          "claude-a": .present,
          "claude-b": .hide(
            .init(
              provider: .claude, id: "claude-b", hidden: true,
              hiddenReason: "Not in the provider's model list since 2026-11-02")),
        ]))
  }

  @Test("reruns in the same week never supply the second observation")
  func sameWeekRerun() throws {
    let list = try Self.listA()
    var (history, _) = try Self.observe(.init(), ["claude-a"], on: "2026-11-02", list: list)
    for day in ["2026-11-02", "2026-11-04", "2026-11-08"] {
      let (next, result) = try Self.observe(history, ["claude-a"], on: day, list: list)
      #expect(
        result
          == .observed([
            "claude-a": .present,
            "claude-b": .missingForRoutineKey(firstMissingDay: "2026-11-02", weeks: 1),
          ]), "\(day)")
      history = next
    }
    #expect(history.entries.map(\.weeks) == [["2026-W45"]])
  }

  @Test("a failed catalog neither advances nor clears history")
  func failedCatalog() throws {
    let list = try Self.listA()
    let (h1, _) = try Self.observe(.init(), ["claude-a"], on: "2026-11-02", list: list)
    let failed = Policy.observeAbsence(
      history: h1, provider: .claude, outcome: .failed, observedAt: Self.date("2026-11-09"),
      list: list)
    #expect(failed.result == .discoveryFailed)
    #expect(failed.history == h1)
    // The next successful week is the second observation: the failed week did not reset it.
    let (_, r3) = try Self.observe(failed.history, ["claude-a"], on: "2026-11-16", list: list)
    if case .observed(let rows) = r3, case .hide = rows["claude-b"] {
    } else {
      Issue.record("expected a hide proposal, got \(r3)")
    }
  }

  @Test("a successful empty catalog is an observation: every listed row is missing")
  func emptyCatalogIsAnObservation() throws {
    let list = try Self.listA()
    let (_, result) = try Self.observe(.init(), [], on: "2026-11-02", list: list)
    #expect(
      result
        == .observed([
          "claude-a": .missingForRoutineKey(firstMissingDay: "2026-11-02", weeks: 1),
          "claude-b": .missingForRoutineKey(firstMissingDay: "2026-11-02", weeks: 1),
        ]))
  }

  @Test("an excluded exact id still counts as present")
  func presenceUsesWholePopulation() throws {
    let list = try Self.list([("claude", "claude-latest", false)])
    let catalog = try Self.claudeCatalog(["claude-latest"], list: list)
    #expect(catalog.eligible.isEmpty)  // `latest` is excluded from the picker
    let result = Policy.observeAbsence(
      history: .init(), provider: .claude, outcome: .complete(catalog),
      observedAt: Self.date("2026-11-02"), list: list)
    #expect(result.result == .observed(["claude-latest": .present]))
    #expect(result.history.entries.isEmpty)
  }

  @Test("reappearance clears pending history and is reported")
  func reappearance() throws {
    let list = try Self.listA()
    let (h1, _) = try Self.observe(.init(), ["claude-a"], on: "2026-11-02", list: list)
    let (h2, r2) = try Self.observe(h1, ["claude-a", "claude-b"], on: "2026-11-09", list: list)
    #expect(r2 == .observed(["claude-a": .present, "claude-b": .reappeared]))
    #expect(h2.entries.isEmpty)
    // A later absence starts over from one week, with a new first date.
    let (_, r3) = try Self.observe(h2, ["claude-a"], on: "2026-11-16", list: list)
    #expect(
      r3
        == .observed([
          "claude-a": .present,
          "claude-b": .missingForRoutineKey(firstMissingDay: "2026-11-16", weeks: 1),
        ]))
  }

  @Test("a row the list already hides is reported, never proposed, never unhidden")
  func alreadyHidden() throws {
    let list = try Self.list([("claude", "claude-a", false), ("claude", "claude-gone", true)])
    let (h1, r1) = try Self.observe(.init(), ["claude-a"], on: "2026-11-02", list: list)
    #expect(r1 == .observed(["claude-a": .present, "claude-gone": .alreadyHidden(present: false)]))
    let (_, r2) = try Self.observe(h1, ["claude-a", "claude-gone"], on: "2026-11-09", list: list)
    #expect(r2 == .observed(["claude-a": .present, "claude-gone": .alreadyHidden(present: true)]))
    #expect(h1.entries.isEmpty)
  }

  @Test("an older observation is stale and changes nothing")
  func staleObservation() throws {
    let list = try Self.listA()
    let (h1, _) = try Self.observe(.init(), ["claude-a"], on: "2026-11-09", list: list)
    let (h2, r2) = try Self.observe(h1, ["claude-a"], on: "2026-11-02", list: list)
    #expect(r2 == .stale(observedWeek: "2026-W45", latestWeek: "2026-W46"))
    #expect(h2 == h1)
  }

  @Test("an older same-week absence cannot undo a newer reappearance")
  func sameWeekReplayCannotUndoReappearance() throws {
    let list = try Self.listA()
    let (h1, _) = try Self.observe(.init(), ["claude-a"], on: "2026-11-02", list: list)
    let (h2, _) = try Self.observe(h1, ["claude-a", "claude-b"], on: "2026-11-04", list: list)
    let (h3, replay) = try Self.observe(h2, ["claude-a"], on: "2026-11-02", list: list)
    #expect(replay == .stale(observedWeek: "2026-W45", latestWeek: "2026-W45"))
    let (_, r4) = try Self.observe(h3, ["claude-a"], on: "2026-11-09", list: list)
    #expect(r4 == .observed([
      "claude-a": .present,
      "claude-b": .missingForRoutineKey(firstMissingDay: "2026-11-09", weeks: 1),
    ]))
  }

  @Test("an older same-week presence cannot clear newer absence evidence")
  func sameWeekReplayCannotClearAbsence() throws {
    let list = try Self.listA()
    let (h1, _) = try Self.observe(.init(), ["claude-a", "claude-b"], on: "2026-11-02", list: list)
    let (h2, _) = try Self.observe(h1, ["claude-a"], on: "2026-11-04", list: list)
    let (h3, replay) = try Self.observe(h2, ["claude-a", "claude-b"], on: "2026-11-02", list: list)
    #expect(replay == .stale(observedWeek: "2026-W45", latestWeek: "2026-W45"))
    #expect(h3 == h2)
    let (_, r4) = try Self.observe(h3, ["claude-a"], on: "2026-11-09", list: list)
    if case .observed(let rows) = r4, case .hide = rows["claude-b"] {} else {
      Issue.record("expected a hide proposal, got \(r4)")
    }
  }

  @Test("a dated copy alone does not keep its missing undated row present")
  func datedCopyIsNotPresenceOfBase() throws {
    let list = try Self.list([("claude", "claude-c", false)])
    let (_, result) = try Self.observe(.init(), ["claude-c-20261001"], on: "2026-11-02", list: list)
    #expect(result == .observed([
      "claude-c": .missingForRoutineKey(firstMissingDay: "2026-11-02", weeks: 1),
    ]))
  }

  @Test("providers keep separate history")
  func historyProviderIsolation() throws {
    let list = try Self.list([("claude", "claude-a", false), ("openAI", "gpt-a", false)])
    let (h1, _) = try Self.observe(.init(), [], on: "2026-11-02", list: list)
    let openAI = try Self.openAICatalog([("gpt-a", nil)], list: list)
    let r2 = Policy.observeAbsence(
      history: h1, provider: .openAI, outcome: .complete(openAI),
      observedAt: Self.date("2026-11-09"), list: list)
    #expect(r2.result == .observed(["gpt-a": .present]))
    #expect(r2.history.entries.map(\.id) == ["claude-a"])
    #expect(
      r2.history.latestObservedAt == [
        "claude": Self.date("2026-11-02"), "openAI": Self.date("2026-11-09"),
      ])
  }

  @Test("an entry for a row the list no longer has is dropped")
  func removedRowDropsEntry() throws {
    let (h1, _) = try Self.observe(.init(), ["claude-a"], on: "2026-11-02", list: try Self.listA())
    let smaller = try Self.list([("claude", "claude-a", false)])
    let (h2, r2) = try Self.observe(h1, ["claude-a"], on: "2026-11-09", list: smaller)
    #expect(r2 == .observed(["claude-a": .present]))
    #expect(h2.entries.isEmpty)
  }

  // MARK: - Serialization

  @Test("history round-trips through its versioned encoding")
  func roundTrip() throws {
    let (h1, _) = try Self.observe(.init(), ["claude-a"], on: "2026-11-02", list: try Self.listA())
    let decoded = try Policy.AbsenceHistory.decode(try h1.encoded())
    #expect(decoded == h1)
    #expect(decoded.entries.map(\.weeks) == [["2026-W45"]])
  }

  /// A valid history document: one Claude observation and the given entries.
  static func state(
    version: Int = 1, observed: [String: String] = ["claude": "2026-11-16T00:00:00Z"],
    entries: [String]
  ) -> String {
    let latest = observed.map { #""\#($0.key)":"\#($0.value)""# }.joined(separator: ",")
    return #"{"version":\#(version),"latestObservedAt":{\#(latest)},"entries":[\#(entries.joined(separator: ","))]}"#
  }

  static func entry(day: String = "2026-11-02", weeks: [String] = ["2026-W45"]) -> String {
    let list = weeks.map { #""\#($0)""# }.joined(separator: ",")
    return #"{"provider":"claude","id":"x","firstMissingDay":"\#(day)","weeks":[\#(list)]}"#
  }

  @Test("a valid history document decodes")
  func validStateDecodes() throws {
    let history = try Policy.AbsenceHistory.decode(
      Data(Self.state(entries: [Self.entry(weeks: ["2026-W45", "2026-W46"])]).utf8))
    #expect(history.entries.map(\.weeks) == [["2026-W45", "2026-W46"]])
    #expect(history.latestObservedAt == ["claude": Self.date("2026-11-16")])
  }

  enum BadState: String, CaseIterable {
    case futureVersion, unknownProvider, malformedWeek, unsortedWeeks, duplicateEntry
    case malformedDay, emptyWeeks, notJSON, impossibleDay, nonexistentWeek
    case entryWithoutObservation, firstWeekNotFirstDay, weekAfterLatest, dayAfterLatest

    var json: String {
      typealias S = CloudModelRoutinePolicyTests
      switch self {
      case .futureVersion: return S.state(version: 2, entries: [])
      case .unknownProvider: return S.state(observed: ["ollama": "2026-11-16T00:00:00Z"], entries: [])
      case .malformedWeek: return S.state(entries: [S.entry(weeks: ["2026-45"])])
      case .unsortedWeeks: return S.state(entries: [S.entry(weeks: ["2026-W46", "2026-W45"])])
      case .duplicateEntry: return S.state(entries: [S.entry(), S.entry()])
      case .malformedDay: return S.state(entries: [S.entry(day: "11/02/2026")])
      case .emptyWeeks: return S.state(entries: [S.entry(weeks: [])])
      case .notJSON: return "not json"
      case .impossibleDay: return S.state(entries: [S.entry(day: "2026-99-99")])
      // 2025 has 52 ISO weeks.
      case .nonexistentWeek:
        return S.state(
          observed: ["claude": "2026-01-10T00:00:00Z"],
          entries: [S.entry(day: "2025-12-29", weeks: ["2025-W53"])])
      case .entryWithoutObservation: return S.state(observed: [:], entries: [S.entry()])
      case .firstWeekNotFirstDay: return S.state(entries: [S.entry(day: "2026-11-09")])
      case .weekAfterLatest: return S.state(entries: [S.entry(weeks: ["2026-W45", "2026-W48"])])
      case .dayAfterLatest:
        return S.state(entries: [S.entry(day: "2026-11-20", weeks: ["2026-W47"])])
      }
    }
  }

  @Test(
    "malformed or unsupported history is refused, never read as empty", arguments: BadState.allCases
  )
  func refusesBadState(_ state: BadState) {
    #expect(throws: (any Error).self, "\(state)") {
      _ = try Policy.AbsenceHistory.decode(Data(state.json.utf8))
    }
  }
}
