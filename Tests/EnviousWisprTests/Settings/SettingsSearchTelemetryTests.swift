import EnviousWisprServices
import Foundation
import Observation
import Testing

@testable import EnviousWisprAppKit

/// The failed-search signal (#3482 plan §8.1). When this fails, Envious Labs either learns
/// nothing about what people cannot find in Settings, or receives text it must never receive: an
/// email, a web address, a number, a key, or any query from someone who switched usage metrics off.
@MainActor
@Suite("Settings search telemetry (#3482)", .tags(.productOutcome))
struct SettingsSearchTelemetryTests {
  // MARK: - The privacy filter

  @Test("ordinary failed searches are kept, trimmed and lowercased")
  func keepsOrdinaryQueries() {
    #expect(SettingsSearchQueryFilter.reportable("  Dark Mode ") == "dark mode")
    #expect(SettingsSearchQueryFilter.reportable("API key") == "api key")
    #expect(SettingsSearchQueryFilter.reportable("Tastenkürzel ändern") == "tastenkürzel ändern")
    #expect(SettingsSearchQueryFilter.reportable("windows 11") == "windows 11")
    // Near misses for the credential check: real words, a long German compound, a key's name.
    #expect(SettingsSearchQueryFilter.reportable("skip silence") == "skip silence")
    #expect(SettingsSearchQueryFilter.reportable("hfp headset") == "hfp headset")
    #expect(SettingsSearchQueryFilter.reportable("asian languages") == "asian languages")
    #expect(
      SettingsSearchQueryFilter.reportable("Spracherkennungseinstellungen")
        == "spracherkennungseinstellungen")
    #expect(SettingsSearchQueryFilter.reportable("openai key: where?") == "openai key: where?")
    #expect(SettingsSearchQueryFilter.reportable("pause after 10:30") == "pause after 10:30")
    #expect(SettingsSearchQueryFilter.reportable("talk at home") == "talk at home")
    // A Japanese vocabulary phrase longer than 32 characters, written without spaces.
    let japanese = "文章整形に使うClaudeモデルの選び方や表示されない理由を知りたい"
    #expect(SettingsSearchQueryFilter.reportable(japanese) == japanese.lowercased())
  }

  @Test("the whole query is dropped when it could identify someone or hold a secret")
  func dropsSensitiveQueries() {
    for text in [
      "me@example.com", "https://example.com/x", "www.example.com", "visit example.com",
      "example.cloud", "my.site.xyz",
      "call 555 123 4567", "1234567", "sk-proj-abc123", "AIzaSyD-whatever",
      "ghp_0123456789abcdef", "a8F3k2L9q0Z7x1C4v6B5n", "ab", String(repeating: "x", count: 81),
      // A key glued to a label or wrapped in punctuation (cloud review, PR #3513); built from
      // parts so no secret-shaped literal sits in the source.
      "token:ghp_" + String(repeating: "a", count: 36), "key=sk-ant-api03-abc", "(AIzaSyabc)",
      "\"xoxb-abc-def\"", "github_pat_abcdefghij", "AKIA" + String(repeating: "B", count: 16),
      "hf_abcdefgh", "glpat-abcdefghij", "my key is " + String(repeating: "q", count: 32),
      // Found by a local enumeration of the class (PR #3513): an invisible character inside a
      // key, a base64 key, an email spelled out, network and hardware addresses, a home-folder
      // path, an IBAN with letters in its account part.
      "g\u{200B}hp_" + String(repeating: "a", count: 18) + "\u{200B}" + String(repeating: "b", count: 18),
      "sA9vwtMpIDApkvvl82t+Rpf/OtIxebKjstdK=", "jane at example dot com", "10.0.0.1",
      "fe80::abcd", "aa:bb:cc:dd:ee:ff", "/Users/Jane/Documents", "LU46 001A BCDE FGHI JKLM",
    ] {
      #expect(SettingsSearchQueryFilter.reportable(text) == nil, "kept \(text)")
    }
  }

  @Test("the query rides only on zero_results and sidebar_bypass")
  func queryOnlyOnGaps() {
    func query(_ outcome: SettingsSearchFinished.Outcome) -> String? {
      SettingsSearchFinished(
        outcome: outcome, endedBy: .escape, resultCount: 0, appLanguage: "en",
        typedQuery: "dark mode"
      ).query
    }
    #expect(query(.zeroResults) == "dark mode")
    #expect(query(.sidebarBypass) == "dark mode")
    #expect(query(.resultChosen) == nil)
    #expect(query(.abandoned) == nil)
    let leak = SettingsSearchFinished(
      outcome: .zeroResults, endedBy: .clear, resultCount: 0, appLanguage: "en",
      typedQuery: "me@example.com")
    #expect(leak.query == nil, "an email reached the row")
  }

  // MARK: - Outcomes

  typealias Attempt = SettingsSearchModel.Attempt

  static func snapshot(results: Int, pending: Bool = false) -> Attempt {
    var attempt = Attempt(eligible: true)
    attempt.query = "x"
    attempt.resultCount = results
    attempt.meaningPending = pending
    return attempt
  }

  @Test("each way a search ends maps to the plan's outcome")
  func outcomes() {
    let outcome = SettingsSearchModel.outcome
    #expect(outcome(.searchResult, Self.snapshot(results: 3)) == .resultChosen)
    #expect(outcome(.sidebar, Self.snapshot(results: 3)) == .sidebarBypass)
    #expect(outcome(.sidebar, Self.snapshot(results: 0)) == .zeroResults)
    #expect(outcome(.sidebar, Self.snapshot(results: 0, pending: true)) == .abandoned)
    for ended: SettingsSearchFinished.EndedBy in [
      .externalDestination, .escape, .clear, .queryEmpty, .windowClose,
    ] {
      #expect(outcome(ended, Self.snapshot(results: 0)) == .zeroResults, "\(ended)")
      #expect(outcome(ended, Self.snapshot(results: 2)) == .abandoned, "\(ended)")
      #expect(outcome(ended, Self.snapshot(results: 0, pending: true)) == .abandoned, "\(ended)")
    }
  }

  // MARK: - Attempts through the model

  @MainActor @Observable final class Sent { var rows: [SettingsSearchFinished] = [] }

  static func model(usageOn: Bool = true, sent: Sent) throws -> SettingsSearchModel {
    let index = try SettingsSearchModelTests.index.get()
    let model = SettingsSearchModel(
      loadIndex: { index }, usageMetricsOn: { usageOn }, emitFinished: { sent.rows.append($0) },
      announce: { _ in }, announcementDelay: .seconds(60))
    return model
  }

  @Test("one row per attempt: typing and editing do not send; Escape finishes it once")
  func oneRowPerAttempt() async throws {
    let sent = Sent()
    let model = try Self.model(sent: sent)
    model.setQuery("zz")
    #expect(await SettingsSearchModelTests.ready(model))
    model.setQuery("zzq")
    model.setQuery("zzqx")
    #expect(sent.rows.isEmpty, "an edit sent a row")
    model.reset(endedBy: .escape)
    model.reset(endedBy: .escape)
    #expect(sent.rows.count == 1, "\(sent.rows)")
    let row = try #require(sent.rows.first)
    #expect(row.outcome == .zeroResults)
    #expect(row.endedBy == .escape)
    #expect(row.query == "zzqx", "the last presented query, not a prefix")
    #expect(row.appLanguage == "en")
  }

  @Test("deleting to empty finishes with the last non-empty search")
  func deletionToEmpty() async throws {
    let sent = Sent()
    let model = try Self.model(sent: sent)
    model.setQuery("dock")
    #expect(await SettingsSearchModelTests.ready(model))
    model.setQuery("")
    let row = try #require(sent.rows.first)
    #expect(row.endedBy == .queryEmpty)
    #expect(row.outcome == .abandoned, "it had results")
    #expect(row.query == nil)
    #expect(row.resultCount > 0)
  }

  @Test("with usage metrics off nothing is sent; switching off mid-search cancels that attempt")
  func usageSwitch() async throws {
    let sent = Sent()
    let off = try Self.model(usageOn: false, sent: sent)
    off.setQuery("zzqx")
    #expect(await SettingsSearchModelTests.ready(off))
    off.reset(endedBy: .escape)
    #expect(sent.rows.isEmpty)
    let on = try Self.model(sent: sent)
    on.setQuery("zzqx")
    #expect(await SettingsSearchModelTests.ready(on))
    on.usageMetricsChanged(isOn: false)
    on.usageMetricsChanged(isOn: true)
    on.reset(endedBy: .escape)
    #expect(sent.rows.isEmpty, "an attempt switched off midway was reported")
  }

  @Test("a closed panel keeps the snapshot it last showed")
  func frozenSnapshot() async throws {
    let sent = Sent()
    let model = try Self.model(sent: sent)
    model.setQuery("zzqx")
    #expect(await SettingsSearchModelTests.ready(model))
    model.dismissPanel()
    model.finish(endedBy: .sidebar, sidebarPage: "keybinds", sidebarTab: nil)
    let row = try #require(sent.rows.first)
    #expect(row.outcome == .zeroResults)
    #expect(row.query == "zzqx")
    #expect(row.sidebarPage == "keybinds")
  }

  @Test("a chosen result is result_chosen with no query")
  func resultChosen() async throws {
    let sent = Sent()
    let model = try Self.model(sent: sent)
    model.setQuery("dock")
    #expect(await SettingsSearchModelTests.ready(model))
    model.finish(endedBy: .searchResult)
    model.reset()
    #expect(sent.rows.map(\.outcome) == [.resultChosen])
    #expect(sent.rows.first?.query == nil)
  }
}
