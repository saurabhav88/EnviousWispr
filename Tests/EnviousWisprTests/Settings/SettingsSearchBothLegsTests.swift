import Foundation
import Testing

@testable import EnviousWisprAppKit

/// Settings search with both legs, words and the meaning pass, through the same model the window
/// uses (#3482 plan §3.7a, §18). When this fails, a search the measured winner answers (or a plain
/// name the word leg already answers) shows the wrong setting first in the shipped search box.
@MainActor
@Suite("Settings search with the meaning pass (#3482)", .tags(.productOutcome))
struct SettingsSearchBothLegsTests {
  /// The committed assets, with a load budget wide enough for a Debug test process (the shipped
  /// budget is measured in Release; SettingsSearchMeaningWorkerTests owns that rule).
  static func worker() -> SettingsSearchMeaningWorker {
    SettingsSearchMeaningWorker.bundled(
      assets: SettingsSearchMeaningAssets(
        directory: RepoRoot.sourceURL("Sources/EnviousWispr/Resources/SettingsSearchMeaning")),
      loadBudgetMilliseconds: 60_000)
  }

  static func model(_ language: String) throws -> SettingsSearchModel {
    let index =
      try language == "de"
      ? SettingsSearchMatchingTests.german.get() : SettingsSearchMatchingTests.english.get()
    return SettingsSearchModel(
      loadIndex: { index }, meaningWorker: worker(), announce: { _ in },
      announcementDelay: .seconds(60))
  }

  /// Types `query` and waits for the meaning pass to finish (or be skipped).
  static func search(_ model: SettingsSearchModel, _ query: String) async -> [String] {
    model.setQuery(query)
    _ = await SettingsSearchModelTests.waitUntil(seconds: 60) {
      guard case .ready = model.indexState else { return false }
      return model.meaningPass != .pending
    }
    return model.results.map(\.entryID)
  }

  @Test("the meaning pass loads from the committed assets and is not skipped")
  func meaningPassRuns() async throws {
    let model = try Self.model("en")
    _ = await Self.search(model, "mic")
    #expect(model.meaningPass == .completed, "the meaning pass was skipped")
  }

  /// The plan's §18 acceptance (first place, and the listed others in the top five) is binding:
  /// no row here is waived. The expected answers are the measured winner's, adopted by the
  /// founder on 2026-10-07 (#3482 §18, option 1a); a failing row is a ranking change.
  func check(_ row: SettingsSearchMatchingTests.Row, _ ids: [String]) {
    guard let first = row.first else {
      #expect(ids.isEmpty, "\(row.testDescription) answered \(Array(ids.prefix(5)))")
      return
    }
    #expect(ids.first == first, "\(row.testDescription): \(Array(ids.prefix(5)))")
    for id in row.alsoInTopFive {
      #expect(
        ids.prefix(5).contains(id), "\(row.testDescription): \(id) not in \(Array(ids.prefix(5)))")
    }
  }

  @Test("each both-legs row shows its setting first, and its others in the top five")
  func bothLegsTable() async throws {
    let english = try Self.model("en")
    let german = try Self.model("de")
    for row in SettingsSearchMatchingTests.bothLegsTable {
      check(row, await Self.search(row.language == "de" ? german : english, row.query))
    }
  }

  @Test("the word-leg rows keep their answers with the meaning pass on")
  func wordRowsHold() async throws {
    let english = try Self.model("en")
    let german = try Self.model("de")
    let overrides = SettingsSearchMatchingTests.bothLegsOverrides
    for wordRow in SettingsSearchMatchingTests.queryTable + SettingsSearchMatchingTests.sentenceTable {
      let row =
        overrides.first { $0.language == wordRow.language && $0.query == wordRow.query } ?? wordRow
      check(row, await Self.search(row.language == "de" ? german : english, row.query))
    }
    // Every override replaces a real word-leg row, so none silently stops being checked.
    for row in overrides {
      #expect(
        (SettingsSearchMatchingTests.queryTable + SettingsSearchMatchingTests.sentenceTable)
          .contains { $0.language == row.language && $0.query == row.query },
        "\(row.testDescription) overrides no word-leg row")
    }
  }

  @Test("meaning_elapsed_ms counts encoding and scoring, never the model load")
  func elapsedExcludesLoad() async throws {
    let assets = SettingsSearchMeaningAssets(
      directory: RepoRoot.sourceURL("Sources/EnviousWispr/Resources/SettingsSearchMeaning"))
    // The load is held back three seconds on purpose; the first search pays for it.
    let worker = SettingsSearchMeaningWorker(loadBudgetMilliseconds: 60_000) {
      try await Task.sleep(for: .seconds(3))  // test-fixture-timer: the delayed load is the control
      return try await SettingsSearchMeaningWorker.loadProduction(assets: assets)
    }
    let index = try SettingsSearchMatchingTests.english.get()
    let model = SettingsSearchModel(
      loadIndex: { index }, meaningWorker: worker, announce: { _ in },
      announcementDelay: .seconds(60))
    _ = await Self.search(model, "mic")
    let elapsed = try #require(model.meaningElapsedMilliseconds, "no meaning time recorded")
    guard case .ready(let loadMilliseconds) = await worker.ensureLoaded() else {
      Issue.record("the meaning pass did not load")
      return
    }
    #expect(loadMilliseconds >= 3_000, "the control delay did not happen: \(loadMilliseconds) ms")
    #expect(elapsed < 3_000, "\(elapsed) ms includes the three-second load")
  }

  @Test("a place only the meaning model found carries no match hint")
  func meaningOnlyHasNoHint() async throws {
    let model = try Self.model("en")
    let words = try SettingsSearchMatchingTests.english.get().results(
      for: "use a different microphone")
    _ = await Self.search(model, "use a different microphone")
    let wordIDs = Set(words.map(\.entryID))
    for result in model.results where !wordIDs.contains(result.entryID) {
      #expect(result.hint == nil, "\(result.entryID) invented a hint")
    }
  }
}
